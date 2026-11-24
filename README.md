# OfflineEarnings

Offline earnings for Roblox idle, tycoon, and simulator games.

Give it when the player left, how fast they earn, and a few rules. It tells you what they earned while away, plus a ready-to-show "2h 45m" string for your Welcome Back popup.

It's a **pure calculation module**: no DataStore code, no Roblox services, no UI. You keep using whatever saving system your game already has (ProfileService, raw DataStore, anything).

## Why use this instead of `os.time() - lastSeen`?

The basic snippet works until it doesn't. This module handles the parts that usually get rebuilt (or broken) game by game:

- **Cap**: limit offline time (default 8 hours).
- **Efficiency**: earn only a fraction of the online rate while away.
- **Boosts that expire mid-absence**: a 2x boost that ended 1 hour into a 5-hour absence only counts for that first hour.
- **Boosts that start mid-absence**, and overlapping boosts (they multiply).
- **Clock safety**: a missing, future, or corrupted `lastSeen` returns zero instead of free money or a crash.
- **Minimum threshold**: ignore tiny absences so quick rejoins don't trigger a popup.
- **Duration formatting** for your UI.

## Install

**Wally** (once published; replace `zaidenmtz1` with the real scope):

```toml
[dependencies]
OfflineEarnings = "zaidenmtz1/offline-earnings@0.1.0"
```

**Manual:** copy `src/init.luau` into a ModuleScript named `OfflineEarnings` in `ReplicatedStorage` or `ServerScriptService`.

## Quick start

```lua
local OfflineEarnings = require(path.to.OfflineEarnings)

local result = OfflineEarnings.calculate({
	lastSeen = data.LastSeen,          -- os.time() you saved when they left (nil for new players)
	now = os.time(),                   -- server time only
	ratePerSecond = data.CoinsPerSecond,
	maxSeconds = 8 * 3600,             -- count at most 8 hours away
	efficiency = 0.5,                  -- earn 50% of the online rate while away
	minSeconds = 60,                   -- ignore absences under a minute
	modifiers = {
		-- a 2x boost that was active when they left and ends at data.BoostEndsAt
		{ multiplier = 2, expiresAt = data.BoostEndsAt },
	},
})

if result.earned > 0 then
	local coins = math.floor(result.earned)
	data.Coins += coins
	print(`Welcome back! You were gone {OfflineEarnings.formatDuration(result.secondsAway)} and earned {coins} coins.`)
	if result.wasCapped then
		print("(Offline earnings are capped at 8 hours.)")
	end
end
```

### Where `lastSeen` comes from

Save `os.time()` into the player's data when they leave **and** whenever you autosave:

```lua
Players.PlayerRemoving:Connect(function(player)
	local data = getData(player)
	data.LastSeen = os.time()
	-- ...save as usual
end)
```

If a server crashes and `LastSeen` is stale, the player would be credited for time they were actually online. Updating `LastSeen` on every autosave keeps that gap small.

## API

### `OfflineEarnings.calculate(config): Result`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `lastSeen` | `number?` | none | Unix time saved when the player left. `nil` means a new player. |
| `now` | `number` | required | Current unix time. Use `os.time()` on the **server**. |
| `ratePerSecond` | `number` | required | Earnings per second while online, before boosts and efficiency. |
| `maxSeconds` | `number?` | `28800` (8h) | Maximum offline seconds that count. `math.huge` for no cap. |
| `efficiency` | `number?` | `1` | Fraction of the online rate earned while away. |
| `minSeconds` | `number?` | `0` | Absences shorter than this earn nothing. |
| `modifiers` | `{Modifier}?` | none | Boosts that were active around the time the player left. |

**Modifier:** `{ multiplier: number, startsAt: number?, expiresAt: number? }`. Omit `startsAt` if it was already active; omit `expiresAt` if it never ends. Overlapping modifiers multiply. A `multiplier` of `0` pauses earnings while it's active.

**Result:**

| Field | Meaning |
|---|---|
| `earned` | Total earned. **Not rounded**: use `math.floor` or `math.round` yourself. |
| `secondsAway` | Real time the player was away (0 if it couldn't be determined). |
| `secondsCounted` | Seconds that counted after the cap. |
| `wasCapped` | `true` if the absence was longer than `maxSeconds`. |
| `reason` | `"ok"`, `"no_last_seen"`, `"clock_skew"` (lastSeen in the future), or `"below_minimum"`. |

Bad **data** (missing or future `lastSeen`) returns a zero result with a `reason`. Bad **arguments** (negative rate, non-number `now`, ...) raise an error so bugs get caught in development.

### `OfflineEarnings.formatDuration(seconds, maxParts?): string`

```lua
OfflineEarnings.formatDuration(9900)        --> "2h 45m"
OfflineEarnings.formatDuration(90061)       --> "1d 1h"
OfflineEarnings.formatDuration(90061, 3)    --> "1d 1h 1m"
OfflineEarnings.formatDuration(45)          --> "45s"
```

## How boosts and the cap interact

Everything is measured from the moment the player left. The cap trims the **end** of the absence, and boosts are only counted inside the part that remains. Efficiency is applied last.

Example: away 12 hours, cap 8 hours, a 2x boost that ends 3 hours after they left → hours 0-3 earn at 2x, hours 3-8 at 1x, hours 8-12 earn nothing.

## What it doesn't do (yet)

- **Saving or loading data.** Bring your own DataStore or ProfileService setup.
- **Big-number support.** It uses regular Luau numbers. Games that exceed ~1e308 need a big-number library and their own conversion.
- **Changing rates over time.** It assumes `ratePerSecond` was constant while away (boosts aside).
- **Exploit protection.** It trusts the numbers you give it. Always pass `os.time()` from the server and never accept timestamps from the client.
- **UI.** It gives you the numbers and a formatted duration; the popup is yours.

## Tests

The test suite needs no framework, only the [Luau CLI](https://github.com/luau-lang/luau/releases) or [Lune](https://github.com/lune-org/lune):

```bash
luau tests/OfflineEarnings.spec.luau
```

## Contributing

Issues and PRs are welcome, especially edge cases you hit in a real game.

## License

MIT. See [LICENSE](LICENSE).
