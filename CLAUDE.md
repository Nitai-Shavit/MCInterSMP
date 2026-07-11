# CLAUDE.md — Storage Monitor + Cannon Command (ComputerCraft: Tweaked)

Two independent ComputerCraft subsystems for a Create-based modded Minecraft
SMP (NeoForge 1.21.1), written in Lua for **CC: Tweaked**: a storage-fill
monitor (collector.lua/display.lua) and a Create: Radars + Create: Big Cannons
targeting system (radar.lua/cannon.lua/master.lua). Do not assume any other
peripheral mod is present — see each section's Constraints.

## Part 1 — Storage Monitor

### Architecture (distributed, over rednet)

Storage is spread across the base, so this is NOT a single-computer system.
Wireless modems in CC only carry **messages between computers** — they cannot
`peripheral.wrap` a remote inventory. Only **wired** modems expose peripherals.

- **collector.lua** — one per storage cluster. Reads nearby silos/vaults/tanks
  over a **wired** modem network, and broadcasts fill data over a
  **wireless/ender** modem using rednet protocol `"storagemon"`. Also answers
  `detail_req` messages with a per-item breakdown. Includes a setup wizard
  (`collector setup`) that auto-detects item/fluid peripherals by method and
  saves groups/capacities to `storage.cfg`. Leaving Group blank once a group
  has been typed for that kind reuses it (and capacity, for fluids) for that
  peripheral and all remaining ones of the same kind — most clusters are one
  group across many silos/tanks, so you only type it once per cluster.
- **display.lua** — runs on the computer wired to an **Advanced** monitor.
  Listens to all collectors, merges entries by group, draws fill bars, and on
  touch shows an item breakdown for that group.

Each collector needs BOTH a wired modem (peripherals) and a wireless/ender
modem (rednet). The code deliberately picks the wireless one via `isWireless()`.

### Data model

- **Group** = merge key AND bar title. Same group = one combined bar
  (e.g. all 14 main silos share group `Main`). There is no separate per-unit
  label — it was never surfaced anywhere, so setup only asks for Group.
- Fluid **capacity** is stored in **mB** (buckets x 1000).

### Constraints (important)

- Available CC mods: CC: Tweaked, Create: CC Better Recipes, CC: Sable,
  CC: Create Redstone Link, CC: Redstone Link Bridge. **No Advanced Peripherals
  or NeoPeripherals**, so the generic fluid peripheral reports current amount
  via `tanks()` but **not** capacity — capacity is configured manually in setup.
- **Advanced monitor required**: only Advanced monitors render color and fire
  `monitor_touch`. Normal monitors show grayscale and ignore touch, so the
  drill-down won't work on them.
- **Deployment**: CC's in-game clipboard paste is single-line only. Programs are
  fetched straight from this repo's raw GitHub URLs via `wget run`, using the
  `install.lua` bootstrapper (see below) — no pastebin required. `http.enabled`
  must be true and `raw.githubusercontent.com` must be reachable per the
  server's CC:Tweaked HTTP allowlist (`computercraft-server.toml` /
  `http.rules`); that's a server-admin config change, not something this repo
  controls.

### Behavior conventions

- Item bars: full = red (bad), empty = green (good).
- Fluid bars: inverted — full = green (good), empty = red (bad).
- Item stat: `NN% | <free slots> free`. Fluid stat: `NN% | <total>B` (buckets).
- `ORDER` in display.lua controls top-to-bottom order; unlisted groups fall
  below, alphabetically. Items section first, then a `----- Fluids -----`
  separator, then fluids.
- Detail (item breakdown) view paginates when the item list is taller than
  the screen. The bottom row becomes touch zones: left half = back to main,
  right half = next page (wraps). With only one page, the whole bottom row
  is just "touch to go back".

## Part 2 — Cannon Command (Create: Radars + Create: Big Cannons)

**Status: nothing physical is built yet.** This was written from mod
documentation research, not tested against a live server — see "Unverified
assumptions" below before relying on any of it. Build the physical setup,
test in stages (radar.lua alone, then cannon.lua with `master commission`
on ONE cannon, then the full aim loop), and expect to tune constants.

### Architecture (three programs, one new rednet protocol `"cbcnet"`)

- **radar.lua** — wired to any Create: Radars peripheral exposing
  `getTracks()` (Radar Bearing / Plane Radar / Monitor — they share the same
  track-table shape, so no setup wizard is needed). Broadcasts tracks
  (`{position, velocity, category, id, scannedTime, entityType}` per track).
- **cannon.lua** — one per cluster of cannons. Wired to each cannon's **Auto
  Pitch Controller**, **Auto Yaw Controller**, and **Fire Controller**
  (Create: Radars' own CC:Tweaked peripherals — no separate bridge mod
  needed). `cannon setup` groups detected controllers under a Cannon ID
  (blank reuses the last ID, same convenience as collector.lua's Group
  prompt), then asks for the data no peripheral reports: mount position (read
  off F3), barrel length in blocks (mount to muzzle — the offset the shell
  actually leaves from, per the barrel-exit requirement), and propellant
  charges loaded. **cannon.lua never calls `stopAuto()` on its own** — a
  cannon stays under the radar mod's own auto-aim network until it receives
  an explicit `commission` message from master.
- **master.lua** — the central computer, wired to an Advanced monitor.
  Merges radar tracks and cannon statuses over rednet, lets you touch a
  cannon then touch a target to assign it, and every `AIM_PERIOD` recomputes
  and sends a firing solution for each assigned, commissioned cannon
  (lead-adjusted for target velocity). `master commission` is a **separate,
  terminal-only** (keyboard, not touch) command: it listens for cannon
  statuses, lists every not-yet-commissioned cannon across ALL nodes, and
  requires typing `YES` **once** for the whole batch before broadcasting
  `stopAuto()` to them — never asked per cannon, per node, or during normal
  monitor use, since `stopAuto()` is irreversible without physically
  re-linking in-game.

### Muzzle-offset + ballistics approach

- Mount position is NOT the muzzle. `muzzlePos()` in master.lua computes the
  actual shell-exit point as `mount + barrelLength * direction(yaw, pitch)`,
  and the firing-solution solver iterates a few times against that muzzle
  point (since it depends on the yaw/pitch being solved for).
- There is no published closed-form angle formula for CBC shells — even the
  one community ballistic calculator for this mod pair says so and solves by
  brute-force simulation instead. `solvePitches()` mirrors that: it scans
  candidate pitches, simulates each tick-by-tick (gravity + drag), and
  bisects around any sign change to find shallow/steep firing angles.
- Muzzle speed = `charges * 40 / 20` blocks/tick (40 m/s per propellant
  charge, linear, from in-game measurement in cannon.lua's setup).

### Unverified assumptions (fix these first when testing in-game)

- `GRAVITY`/`DRAG` in master.lua (-0.04 blocks/tick², 1%/tick) are borrowed
  from a **different** Create-family subsystem (rocket launchpads) — there's
  no confirmed source for cannon-shell-specific constants. If a commissioned
  cannon's shells land short/long of the solved point, tune these constants
  until a known-range test shot lands where solved.
- Yaw convention (0..360, zero direction) and the forward-vector math in
  `muzzlePos()` are a best guess at Minecraft's usual convention — if a
  commissioned cannon aims 90°/180° off, verify by manually `setAngle`-ing a
  known direction and comparing to F3, then fix the sign/offset there.
- Peripheral-type detection in cannon.lua (`kindOf()`) distinguishes pitch
  vs. yaw controllers via a `peripheral.getType()` substring match, since
  their method sets are otherwise identical — setup falls back to asking
  p/y if that string doesn't contain either word. Radar-side peripherals are
  detected by method signature (`getTracks`), which is more reliable.
- No collision/obstacle checking — a solved trajectory that clips terrain or
  a build in the way is not detected.

## Part 3 — Fleet Status Board (CC:Sable, manually-aimed ships)

**Separate from Part 2.** Part 2 auto-aims stationary cannons. This part is
for ships whose cannons are aimed manually (binoculars) — it's read-only
telemetry, `ship.lua`/`fleetboard.lua` never send an aim or fire command, on
its own rednet protocol (`"shipnet"`) so it can't cross-talk with Part 2.

- **ship.lua** — one per gun ship, on a computer physically placed **on**
  the ship (CC:Sable's `sublevel` global API only works for a computer that
  is itself on a Sub-Level — wiring in remotely doesn't get you this data).
  `ship setup` asks for a short Ship ID and which redstone side carries Big
  Cannons' **Cannon Ready Lamp** signal (lit = loaded, aimed, ready to
  fire — plain `redstone.getInput()`, no bridge mod needed for that part).
  Broadcasts `{id, position, pitch, roll, loaded}`.
- **fleetboard.lua** — runs on the master ship's own computer (also needs to
  be on a Sub-Level, for its own position). Read-only board: distance to
  each ship, ready state, and pitch/roll so you can see if a ship is too
  unstable to safely fire on before giving the order. Smart-for-small-
  screens: one compact line per ship, auto-paginates on a timer if more
  ships don't fit than the monitor has rows for (works on a plain, non-
  Advanced monitor too, since paging doesn't depend on touch — touch just
  skips to the next page sooner if you do have one). `SAFE_TILT` (10°)
  flags a ship's pitch/roll red when it exceeds that threshold.

### Unverified: CC:Sable's exact API

CC:Sable's `sublevel` global API (and its bundled quaternion module) is
confirmed to exist and to be the right tool here, but the **exact method
names could not be confirmed from public docs** in the session that wrote
this — the mod's docs site 403s automated fetches and GitHub code search
needs a login. `shipPosition()`/`shipPitchRoll()` in ship.lua (and
`myPosition()` in fleetboard.lua) are isolated, best-effort guesses
(`sublevel.getPosition()`, `sublevel.getRotation()` + a `quaternion.toEuler()`
conversion). They fail safe — a wrong name just makes that field show `?`
instead of crashing — but **before trusting the numbers**, run on a ship
computer:
```
for k in pairs(sublevel) do print(k) end
```
and fix those two functions to match what's actually there. Cannon-ready
detection (redstone) needs no such verification — it's base CC:Tweaked.

## Deploying via wget (no pastebin)

On a fresh computer, paste one of these single lines (adjust the branch/path
if you deploy from a fork or a non-`main` branch):

```
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua collector
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua display
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua radar
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua cannon
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua master
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua ship
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua fleetboard
```

`install.lua` downloads the matching program into the computer's root and
writes a `startup.lua` that re-pulls it from GitHub on every boot before
running it (falls back to the local copy if offline), so a reboot picks up
future repo updates. Config files (`storage.cfg`, `cannon.cfg`, `ship.cfg`)
are untouched by re-installs.

## Possible next features (not yet built)

- Discord webhook alert via `http.post` when Main crosses ~90%.
- Fill-rate / time-to-full estimate per group (delta between scans).
- Buffer-mode inversion for the intermediate Resource Vault (low = bad).
- Paging if groups (bars) exceed one screen (detail-view item paging is done).
- Cannon Command: obstacle/collision-aware trajectory checking.
- Cannon Command: a calibration flow that fires test shots and back-solves
  muzzle speed / drag instead of relying on hand-tuned constants.
- Fleet Board: once CC:Sable's real API is confirmed in-game, consider
  wiring the same `sublevel` position into Part 2's cannon.lua too, so
  ship-mounted stationary-style cannons don't need a manually re-entered
  static mount position.
