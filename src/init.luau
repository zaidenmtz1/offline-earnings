--!strict
--[[
	OfflineEarnings
	Pure calculation of what a player earned while they were away.
	No DataStore, no Roblox services: you pass numbers in, you get numbers out.

	https://github.com/zaidenmtz1/offline-earnings
]]

local OfflineEarnings = {}

-- Offline time counted when `maxSeconds` is not provided (8 hours).
OfflineEarnings.DEFAULT_MAX_SECONDS = 8 * 60 * 60

export type Modifier = {
	-- Multiplier applied to the earn rate while the modifier is active (2 = double).
	multiplier: number,
	-- Unix time the modifier became active. Omit if it was already active.
	startsAt: number?,
	-- Unix time the modifier ends. Omit if it never ends.
	expiresAt: number?,
}

export type Config = {
	-- Unix time (os.time()) saved when the player left. nil for brand-new players.
	lastSeen: number?,
	-- Current unix time. Use os.time() on the SERVER, never the client.
	now: number,
	-- Amount earned per second while online (before modifiers and efficiency).
	ratePerSecond: number,
	-- Maximum offline seconds that count. Default 8 hours. math.huge = no cap.
	maxSeconds: number?,
	-- Fraction of the online rate earned while away. Default 1. Use 0.5 for 50%.
	efficiency: number?,
	-- Absences shorter than this earn nothing. Default 0.
	minSeconds: number?,
	-- Boosts that were active around the time the player left.
	modifiers: { Modifier }?,
}

export type Reason = "ok" | "no_last_seen" | "clock_skew" | "below_minimum"

export type Result = {
	-- Total earned. Not rounded: use math.floor / math.round as your game needs.
	earned: number,
	-- Real time the player was away, in seconds (0 if it could not be determined).
	secondsAway: number,
	-- Seconds that actually counted after the cap was applied.
	secondsCounted: number,
	-- True if the absence was longer than maxSeconds.
	wasCapped: boolean,
	-- Why the result is what it is. "ok" means earnings were calculated normally.
	reason: Reason,
}

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function emptyResult(reason: Reason, secondsAway: number): Result
	return {
		earned = 0,
		secondsAway = secondsAway,
		secondsCounted = 0,
		wasCapped = false,
		reason = reason,
	}
end

local function validateConfig(config: Config)
	assert(type(config) == "table", "OfflineEarnings.calculate expects a config table")
	assert(isFinite(config.now), "config.now must be a finite number (use os.time())")
	assert(isFinite(config.ratePerSecond) and config.ratePerSecond >= 0, "config.ratePerSecond must be a number >= 0")

	local maxSeconds = config.maxSeconds
	assert(
		maxSeconds == nil or (type(maxSeconds) == "number" and maxSeconds == maxSeconds and maxSeconds >= 0),
		"config.maxSeconds must be a number >= 0 (math.huge for no cap)"
	)

	local efficiency = config.efficiency
	assert(efficiency == nil or (isFinite(efficiency) and efficiency >= 0), "config.efficiency must be a number >= 0")

	local minSeconds = config.minSeconds
	assert(minSeconds == nil or (isFinite(minSeconds) and minSeconds >= 0), "config.minSeconds must be a number >= 0")

	for index, modifier in config.modifiers or {} do
		assert(
			type(modifier) == "table" and isFinite(modifier.multiplier) and modifier.multiplier >= 0,
			`config.modifiers[{index}].multiplier must be a number >= 0`
		)
		assert(
			modifier.startsAt == nil or isFinite(modifier.startsAt),
			`config.modifiers[{index}].startsAt must be a number or nil`
		)
		assert(
			modifier.expiresAt == nil or isFinite(modifier.expiresAt),
			`config.modifiers[{index}].expiresAt must be a number or nil`
		)
	end
end

-- Total "rate-weighted seconds" between windowStart and windowEnd. Without modifiers this is
-- just the window length; with them, each stretch is weighted by the boosts active during it.
local function weightedSeconds(windowStart: number, windowEnd: number, modifiers: { Modifier }): number
	if #modifiers == 0 then
		return windowEnd - windowStart
	end

	-- Split the window wherever a modifier starts or ends inside it.
	local points = { windowStart, windowEnd }
	for _, modifier in modifiers do
		local startsAt, expiresAt = modifier.startsAt, modifier.expiresAt
		if startsAt and startsAt > windowStart and startsAt < windowEnd then
			table.insert(points, startsAt)
		end
		if expiresAt and expiresAt > windowStart and expiresAt < windowEnd then
			table.insert(points, expiresAt)
		end
	end
	table.sort(points)

	local total = 0
	for i = 1, #points - 1 do
		local from, to = points[i], points[i + 1]
		if to > from then
			local middle = (from + to) / 2
			local multiplier = 1
			for _, modifier in modifiers do
				local startsAt, expiresAt = modifier.startsAt, modifier.expiresAt
				local started = startsAt == nil or startsAt <= middle
				local notEnded = expiresAt == nil or expiresAt > middle
				if started and notEnded then
					multiplier *= modifier.multiplier
				end
			end
			total += (to - from) * multiplier
		end
	end

	return total
end

--[[
	Calculates offline earnings. Bad *data* (missing or future lastSeen) returns a zero result with
	a `reason`; bad *arguments* (non-numeric rate, negative cap, ...) raise an error so bugs show up.
]]
function OfflineEarnings.calculate(config: Config): Result
	validateConfig(config)

	local lastSeen = config.lastSeen
	if not isFinite(lastSeen) then
		return emptyResult("no_last_seen", 0)
	end
	local lastSeenTime = lastSeen :: number

	local secondsAway = config.now - lastSeenTime
	if secondsAway < 0 then
		return emptyResult("clock_skew", 0)
	end

	if secondsAway < (config.minSeconds or 0) then
		return emptyResult("below_minimum", secondsAway)
	end

	local maxSeconds = config.maxSeconds or OfflineEarnings.DEFAULT_MAX_SECONDS
	local secondsCounted = math.min(secondsAway, maxSeconds)

	-- Boosts are measured from the moment the player left, so the cap trims the END of the absence.
	local weighted = weightedSeconds(lastSeenTime, lastSeenTime + secondsCounted, config.modifiers or {})
	local earned = weighted * config.ratePerSecond * (config.efficiency or 1)

	return {
		earned = earned,
		secondsAway = secondsAway,
		secondsCounted = secondsCounted,
		wasCapped = secondsAway > maxSeconds,
		reason = "ok",
	}
end

--[[
	Formats seconds for a "Welcome back" message, e.g. 9900 -> "2h 45m".
	Shows the largest non-zero units, up to `maxParts` of them (default 2).
]]
function OfflineEarnings.formatDuration(seconds: number, maxParts: number?): string
	if not isFinite(seconds) or seconds < 1 then
		return "0s"
	end

	local remaining = math.floor(seconds)
	local units = {
		{ 86400, "d" },
		{ 3600, "h" },
		{ 60, "m" },
		{ 1, "s" },
	}

	local limit = math.max(1, math.floor(maxParts or 2))
	local parts = {}
	for _, unit in units do
		local size, suffix = unit[1] :: number, unit[2] :: string
		local count = remaining // size
		remaining -= count * size
		if count > 0 then
			table.insert(parts, `{count}{suffix}`)
			if #parts >= limit then
				break
			end
		end
	end

	return table.concat(parts, " ")
end

return OfflineEarnings
