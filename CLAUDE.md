# CLAUDE.md — Storage Monitor + Cannon Command (ComputerCraft: Tweaked)

Four independent ComputerCraft subsystems for a Create-based modded
Minecraft SMP (NeoForge 1.21.1), written in Lua for **CC: Tweaked**: a
storage-fill monitor (collector.lua/display.lua), a Create: Radars + Create:
Big Cannons targeting system (radar.lua/cannon.lua/master.lua), a read-only
GPS-based armada viewer (ship.lua/fleetboard.lua), a standalone one-computer
cannon console (gunner.lua), and a BlueMap-based player radar
(playerradar.lua). Do not assume any other peripheral mod is present — see
each section's Constraints.

**Naming note:** `radar.lua` (Part 2, Create: Radars cannon targeting) and
`playerradar.lua` (Part 4, BlueMap player tracking) are unrelated programs
that happen to share "radar" in the name — different peripherals, different
rednet protocols (`cbcnet` vs. none), different purposes. Don't confuse them.

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

## Part 3 — Armada Viewer (read-only, GPS-based)

**Separate from Part 2, and no cannon control.** An earlier version of this
part actively aimed/fired ship-mounted cannons, but that's been dropped
after running into a CC:Tweaked problem in testing — this is back to being
a pure read-only viewer, on its own rednet protocol (`"shipnet"`) so it
can't cross-talk with Part 2.

- **ship.lua** — one per ship (e.g. "Bolt I"). No peripherals, no setup
  beyond a Ship ID. Every `REFRESH` (5s) it reads its own live position via
  `gps.locate()` (works on a moving ship — requires your GPS hosts to be up)
  and broadcasts it, plus best-effort pitch/roll, to fleetboard.lua.
- **fleetboard.lua** — runs on the master ship's (Lightning's) own computer,
  wired to its monitor. Pure read-only board: one compact line per ship
  (distance, an 8-point compass direction, and pitch/roll), auto-paginating
  on a timer for a small screen — works on a plain, non-Advanced monitor
  too, since paging is timer-driven, not touch-driven. No terminal
  commands, no `parallel`, no `read()` in the run loop at all — the only
  `read()` call in either program is the one-time Ship ID prompt in
  `ship setup`.
  - **Distance and direction** are both plain geometry from Lightning's own
    `gps.locate()` vs each ship's reported position — no ship-orientation
    API needed for either. `bearing()`/`compassLabel()` use the standard
    real-world compass convention (0°=N, 90°=E, 180°=S, 270°=W, Minecraft's
    north = -Z), independent of the yaw convention used for aiming
    elsewhere in this repo.

### Unverified / to tune once tested in-game

- Pitch/roll ("gimbal" reading) is attempted via CC:Sable's `sublevel` API
  as best-effort bonus telemetry — isolated in `shipPitchRoll()`, fails
  safe to `nil`/shown as `?` if unavailable, so a wrong guess there can't
  break the rest of the board. CC:Sable's other global, `aero`/
  `aerodynamics`, was checked and is NOT a fit for this — per its own docs
  it's dimension-wide atmospheric pressure data, not per-object orientation,
  so it isn't wired in here. Run **`ship probe`** on a ship computer (no
  setup or rednet required) to dump whatever `sublevel`/`aero`/
  `aerodynamics`/`quaternion` actually expose plus a `gps.locate()` test —
  paste that output back to get `shipPitchRoll()` fixed to the real method
  names instead of the current guess. If you have an actual Gimbal Sensor
  peripheral (Create: Avionics/Simulated) instead, swap `shipPitchRoll()`
  for a direct `peripheral.call(name, "getAngles")` — that method signature
  is confirmed from source, unlike the `sublevel` guess.

## Part 5 — Gunner (standalone single-cannon console, CC:CBC cannon_mount)

**Separate from Parts 2 and 3.** `gunner.lua` is a self-contained, ONE-computer
aim-and-fire console for a single Create: Big Cannons cannon — no rednet, no
master, no second computer. Where Part 2 auto-aims a cluster of cannons at
radar tracks and Part 3 is a read-only viewer with no cannon control at all,
Part 5 is the simple "type a coordinate, it aims and shoots" operator tool
the SMP originally asked for.

- **Position:** `gps.locate()` every shot, so it works on a moving contraption.
  The cannon MOUNT is derived as `gps + offset`, where the offset
  (`MOUNT - COMPUTER`, read off F3) is captured once in `gunner setup`. If GPS
  is unavailable it falls back to the static mount coords from setup.
- **Aiming backend auto-detect (two routes):** primary is Create: Radars'
  **Auto Pitch + Auto Yaw Controllers** (`setAngle`/`getAngle`/`stopAuto`).
  Critical detail confirmed from the mod source
  (`Arsenalists-of-Create/Create-Radar`): `setAngle` only sets a *target*, and
  the mod's own auto-aim (WeaponFiringControl) **overrides the commanded angle
  every tick unless `stopAuto()` was called** — that was why a naive
  `setAngle`-only version moved pitch but **not yaw**. gunner calls `stopAuto()`
  on both axes before each aim (`setTargetAngle` re-arms `isRunning`, so this
  does not stop the axis from tracking). Also, `getAngle()` returns the *target*
  we set, **not** the live barrel angle, so there is no true settle telemetry
  on this route — see slew wait below. The alternative route is the **CC:CBC
  `cannon_mount`** peripheral (`setComputerControl`/`setTargetAngles`/`fire`/
  `assemble`/`getInfo`) if that mod is present instead.
- **Firing is separate from aiming.** Default is a **redstone pulse** from a
  chosen side of the computer (wired to the cannon's firing through a redstone
  relay / igniter) — no Fire Controller peripheral required, since the SMP's
  cannon fires off redstone. A Create: Radars **Fire Controller** peripheral
  (`fireOn`/`setPowered`) is a selectable alternative in setup.
- **Slew wait (no live angle):** because the radar controllers report only the
  commanded target, gunner can't detect when the barrel physically arrives, so
  it waits a fixed, configurable `slewSeconds` (default 4) for rotation to
  finish before firing. On the CC:CBC route it settles early if `getInfo`
  exposes a real angle. The mount still needs rotational (kinetic) power for
  the controllers to physically turn it.
- **`test` command** commands a single raw axis angle (`test yaw <deg>` /
  `test pitch <deg>`, after `stopAuto`) to verify each axis physically moves —
  the first thing to run when diagnosing a non-moving axis.
- **Ballistics:** same brute-force solver as master.lua (`solvePitches` scans
  the configured pitch range, simulates each candidate tick-by-tick with
  gravity + drag, bisects around sign changes), constants in `gunner.cfg`
  default to the community CBC calculator's values — **gravity 0.05 b/t², drag
  1%/t, muzzle speed = charges x 2 b/t**. **Yaw is emitted in the Create: Radars
  controller's own frame — `atan2(dz, dx) + 90`** (verified from the mod source
  `computeYawToTargetDeg`; +X=90, +Z=180, -X=270, -Z=0), which is what
  `setTargetAngle` consumes, so the computer and the mod agree. The muzzle
  offset is computed straight from the horizontal unit vector, independent of
  that frame; `yawOffset`/`pitchOffset` in the cfg are residual calibration.
- **Setup is deliberately lean** — it asks only the cannon-specific,
  un-reportable facts (mount coords, barrel length, charges, firing side) and
  records which peripheral is the pitch vs. yaw controller (`pitchPeri`/
  `yawPeri`) so aiming can't silently miss an axis. Everything else (per-charge
  velocity, gravity, drag, `pitchMin -30`/`pitchMax 60`, slew, calibration
  offsets) defaults to CBC values in `gunner.cfg` and is edited there directly.
  A runtime `swap` command flips the pitch/yaw assignment if it aims the wrong
  axis.
- **Firing** is automatic once the cannon settles on the commanded angles
  (`waitSettle` polls the backend's angle telemetry, or waits a fixed estimate
  if the backend reports none), with a 3-second **press-any-key-to-abort**
  window before the shot so a bad solution can be stopped.
- **Self-update:** on launch it `wget`s the latest `gunner.lua` from this repo
  and relaunches if it changed (guarded by a `noupdate` sentinel arg), on top
  of install.lua's boot-time re-pull — so a deployed gunner always runs current.
- **Commands:** `aim <x y z>`, `radar` (pick a live Create: Radars track),
  `test yaw|pitch <deg>` (prove an axis moves), `swap` (flip pitch/yaw
  assignment), `angles <y p>` (manual), `arc` (toggle shallow/steep arc),
  `fire`/`hold`, `assemble`/`disassemble`, `info`, `setup`, `wiring`, `quit`.
  `gunner wiring` prints the full hookup guide.

### Unverified / to tune once tested in-game

- Same caveat as Parts 2/3: the ballistics constants and yaw convention are
  best-effort. If a shot lands short/long, tune `gravity`/`drag` in
  `gunner.cfg`; if it aims a fixed amount off in bearing/elevation, set
  `yawOffset`/`pitchOffset`. No obstacle/terrain-collision checking.
- Radar controllers give no live barrel angle, so firing timing rests on
  `slewSeconds`; if the barrel hasn't finished rotating when it fires, raise it.
  On the CC:CBC route the `getInfo()` field names read for real-angle settle
  (`yaw`/`currentYaw`/`cannonYaw`, likewise pitch) are a best guess — verify
  with the `info` command and adjust `readAngles` if early-settle never trips.

## Part 4 — Player Radar (BlueMap)

**Separate from Parts 1-3.** `playerradar.lua` is a standalone, single-
computer program: no modem, no op access, no rednet. Runs on a computer
wired to an Advanced monitor with HTTP access, and polls BlueMap's live
player API (`GET <url>/maps/<map>/live/players`) instead of using any CC
peripheral — BlueMap has no outbound-webhook feature, so this is polling on
a timer, not a push. Plots player positions as a top-down radar, color-coded
by an ally/enemy roster: ally = green, enemy = red, neutral (unlisted) =
yellow. Includes a setup wizard (`playerradar setup`) that saves the
BlueMap URL, map id, poll interval, view center/radius, and roster to
`playerradar.cfg`. Touching a dot shows that player's name and coordinates
for a few seconds.

The roster currently only affects dot **color** — every player BlueMap
reports is plotted regardless of classification (see Possible next
features). Entries with `foreign = true` (player on a different BlueMap
map) are skipped since their coordinates don't apply to the polled map.

### Constraints

- **BlueMap dependency**: BlueMap must already be running, its live player
  markers enabled, and its host:port added to the server's CC:Tweaked
  `http.rules` allowlist — same kind of server-admin config as
  `raw.githubusercontent.com` for wget, no in-game op required.
- Same Advanced-monitor requirement as Part 1 (color + `monitor_touch`).

## Deploying via wget (no pastebin)

On a fresh computer, paste one of these single lines (adjust the branch/path
if you deploy from a fork or a non-`main` branch):

```
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua collector
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua display
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua radar
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua cannon
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua gunner
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua master
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua ship
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua fleetboard
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua playerradar
```

`install.lua` downloads the matching program into the computer's root and
writes a `startup.lua` that re-pulls it from GitHub on every boot before
running it (falls back to the local copy if offline), so a reboot picks up
future repo updates. Config files (`storage.cfg`, `cannon.cfg`, `ship.cfg`,
`playerradar.cfg`) are untouched by re-installs.

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
- Player Radar: filter to enemies-only (or hide allies) instead of always
  showing everyone tracked by BlueMap.
