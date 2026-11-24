--!nocheck
-- Run with the Luau CLI:  luau tests/OfflineEarnings.spec.luau
-- (also works in Lune). No test framework needed.

local OfflineEarnings = require("../src")

local HOUR = 3600
local passed, failed = 0, 0

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}\n       {err}`)
	end
end

local function expectNear(actual: number, expected: number, label: string?)
	assert(near(actual, expected), `{label or "value"}: expected {expected}, got {actual}`)
end

local function expectEqual(actual: any, expected: any, label: string?)
	assert(actual == expected, `{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`)
end

local function expectError(fn: () -> ())
	local ok = pcall(fn)
	assert(not ok, "expected an error but none was raised")
end

local T0 = 1_700_000_000 -- arbitrary "left the game" time

print("calculate: basics")

test("earns rate * seconds", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 100, ratePerSecond = 2 })
	expectNear(r.earned, 200)
	expectNear(r.secondsAway, 100)
	expectNear(r.secondsCounted, 100)
	expectEqual(r.wasCapped, false)
	expectEqual(r.reason, "ok")
end)

test("efficiency scales earnings", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 100, ratePerSecond = 2, efficiency = 0.5 })
	expectNear(r.earned, 100)
end)

test("zero efficiency earns nothing but still reports time", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 100, ratePerSecond = 2, efficiency = 0 })
	expectNear(r.earned, 0)
	expectNear(r.secondsAway, 100)
end)

test("default cap is 8 hours", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 20 * HOUR, ratePerSecond = 1 })
	expectNear(r.secondsCounted, 8 * HOUR)
	expectNear(r.secondsAway, 20 * HOUR)
	expectNear(r.earned, 8 * HOUR)
	expectEqual(r.wasCapped, true)
end)

test("custom cap", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 5 * HOUR, ratePerSecond = 1, maxSeconds = 2 * HOUR })
	expectNear(r.earned, 2 * HOUR)
	expectEqual(r.wasCapped, true)
end)

test("absence exactly at the cap is not 'capped'", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 2 * HOUR, ratePerSecond = 1, maxSeconds = 2 * HOUR })
	expectEqual(r.wasCapped, false)
end)

test("math.huge means no cap", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 100 * HOUR, ratePerSecond = 1, maxSeconds = math.huge })
	expectNear(r.earned, 100 * HOUR)
	expectEqual(r.wasCapped, false)
end)

test("zero cap earns nothing", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1, maxSeconds = 0 })
	expectNear(r.earned, 0)
	expectEqual(r.wasCapped, true)
end)

print("calculate: bad data returns a zero result")

test("nil lastSeen (new player)", function()
	local r = OfflineEarnings.calculate({ lastSeen = nil, now = T0, ratePerSecond = 5 })
	expectNear(r.earned, 0)
	expectEqual(r.reason, "no_last_seen")
end)

test("NaN / infinite lastSeen", function()
	expectEqual(OfflineEarnings.calculate({ lastSeen = 0 / 0, now = T0, ratePerSecond = 5 }).reason, "no_last_seen")
	expectEqual(OfflineEarnings.calculate({ lastSeen = math.huge, now = T0, ratePerSecond = 5 }).reason, "no_last_seen")
end)

test("lastSeen in the future (clock skew)", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0 + 500, now = T0, ratePerSecond = 5 })
	expectNear(r.earned, 0)
	expectNear(r.secondsAway, 0)
	expectEqual(r.reason, "clock_skew")
end)

test("below minimum threshold", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 30, ratePerSecond = 5, minSeconds = 60 })
	expectNear(r.earned, 0)
	expectNear(r.secondsAway, 30)
	expectEqual(r.reason, "below_minimum")
end)

test("exactly at minimum threshold earns", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 60, ratePerSecond = 1, minSeconds = 60 })
	expectNear(r.earned, 60)
	expectEqual(r.reason, "ok")
end)

test("rejoining instantly", function()
	local r = OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 5 })
	expectNear(r.earned, 0)
	expectEqual(r.reason, "ok")
end)

print("calculate: modifiers")

test("boost active the whole time", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 2, expiresAt = T0 + 10 * HOUR } },
	})
	expectNear(r.earned, 2 * HOUR)
end)

test("boost that expires mid-absence only counts until it expires", function()
	-- 5h away, 2x boost ends 1h after leaving: 1h * 2 + 4h * 1
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 5 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 2, expiresAt = T0 + HOUR } },
	})
	expectNear(r.earned, 2 * HOUR + 4 * HOUR)
end)

test("boost that starts mid-absence only counts after it starts", function()
	-- 4h away, 3x boost starts 3h after leaving: 3h * 1 + 1h * 3
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 4 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 3, startsAt = T0 + 3 * HOUR } },
	})
	expectNear(r.earned, 3 * HOUR + 3 * HOUR)
end)

test("boost that already expired before leaving has no effect", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 5, expiresAt = T0 - 10 } },
	})
	expectNear(r.earned, HOUR)
end)

test("boost that starts after the player is back has no effect", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 5, startsAt = T0 + 2 * HOUR } },
	})
	expectNear(r.earned, HOUR)
end)

test("overlapping boosts multiply", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 2 }, { multiplier = 3 } },
	})
	expectNear(r.earned, 6 * HOUR)
end)

test("partially overlapping boosts", function()
	-- 4h away. A: 2x for the first 2h. B: 3x from hour 1 onward.
	-- h0-1: 2x, h1-2: 6x, h2-4: 3x  =>  2 + 6 + 6 = 14 hours-equivalent
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 4 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 2, expiresAt = T0 + 2 * HOUR }, { multiplier = 3, startsAt = T0 + HOUR } },
	})
	expectNear(r.earned, 14 * HOUR)
end)

test("cap trims the end of the absence, boost expiring after the cap still counts fully", function()
	-- 12h away, capped to 8h. 2x boost lasts 10h, so all 8 counted hours are boosted.
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 12 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 2, expiresAt = T0 + 10 * HOUR } },
	})
	expectNear(r.earned, 16 * HOUR)
	expectEqual(r.wasCapped, true)
end)

test("boost that would only apply after the cap is ignored", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 12 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 10, startsAt = T0 + 9 * HOUR } },
	})
	expectNear(r.earned, 8 * HOUR)
end)

test("efficiency applies on top of boosts", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + HOUR, ratePerSecond = 1, efficiency = 0.5,
		modifiers = { { multiplier = 2 } },
	})
	expectNear(r.earned, HOUR)
end)

test("a 0x modifier pauses earnings while active", function()
	local r = OfflineEarnings.calculate({
		lastSeen = T0, now = T0 + 4 * HOUR, ratePerSecond = 1,
		modifiers = { { multiplier = 0, expiresAt = T0 + HOUR } },
	})
	expectNear(r.earned, 3 * HOUR)
end)

test("does not modify the modifiers table it was given", function()
	local mods = { { multiplier = 2, expiresAt = T0 + HOUR } }
	OfflineEarnings.calculate({ lastSeen = T0, now = T0 + 2 * HOUR, ratePerSecond = 1, modifiers = mods })
	expectEqual(#mods, 1)
	expectEqual(mods[1].multiplier, 2)
	expectEqual(mods[1].expiresAt, T0 + HOUR)
end)

print("calculate: bad arguments raise errors")

test("missing or invalid now", function()
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, ratePerSecond = 1 } :: any) end)
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = "x", ratePerSecond = 1 } :: any) end)
end)

test("negative or invalid rate", function()
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = -1 }) end)
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 0 / 0 }) end)
end)

test("negative cap, efficiency or minimum", function()
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 1, maxSeconds = -1 }) end)
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 1, efficiency = -0.5 }) end)
	expectError(function() OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 1, minSeconds = -5 }) end)
end)

test("malformed modifier", function()
	expectError(function()
		OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 1, modifiers = { { multiplier = "2" } } } :: any)
	end)
	expectError(function()
		OfflineEarnings.calculate({ lastSeen = T0, now = T0, ratePerSecond = 1, modifiers = { { multiplier = -1 } } })
	end)
end)

print("formatDuration")

test("formats common durations", function()
	expectEqual(OfflineEarnings.formatDuration(0), "0s")
	expectEqual(OfflineEarnings.formatDuration(45), "45s")
	expectEqual(OfflineEarnings.formatDuration(60), "1m")
	expectEqual(OfflineEarnings.formatDuration(125), "2m 5s")
	expectEqual(OfflineEarnings.formatDuration(3600), "1h")
	expectEqual(OfflineEarnings.formatDuration(9900), "2h 45m")
	expectEqual(OfflineEarnings.formatDuration(8 * HOUR), "8h")
	expectEqual(OfflineEarnings.formatDuration(90061), "1d 1h")
end)

test("maxParts controls detail", function()
	expectEqual(OfflineEarnings.formatDuration(90061, 3), "1d 1h 1m")
	expectEqual(OfflineEarnings.formatDuration(90061, 4), "1d 1h 1m 1s")
	expectEqual(OfflineEarnings.formatDuration(90061, 1), "1d")
end)

test("fractional, negative and invalid inputs", function()
	expectEqual(OfflineEarnings.formatDuration(59.9), "59s")
	expectEqual(OfflineEarnings.formatDuration(0.5), "0s")
	expectEqual(OfflineEarnings.formatDuration(-100), "0s")
	expectEqual(OfflineEarnings.formatDuration(0 / 0), "0s")
	expectEqual(OfflineEarnings.formatDuration(math.huge), "0s")
end)

print(`\n{passed} passed, {failed} failed`)
if failed > 0 then
	error("tests failed")
end
