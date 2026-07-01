# CLAUDE.md — Storage Monitor (ComputerCraft: Tweaked)

A two-program storage-fill monitor for a Create-based modded Minecraft SMP
(NeoForge 1.21.1). Written in Lua for **CC: Tweaked**. Do not assume any other
peripheral mod is present — see Constraints.

## Architecture (distributed, over rednet)

Storage is spread across the base, so this is NOT a single-computer system.
Wireless modems in CC only carry **messages between computers** — they cannot
`peripheral.wrap` a remote inventory. Only **wired** modems expose peripherals.

- **collector.lua** — one per storage cluster. Reads nearby silos/vaults/tanks
  over a **wired** modem network, and broadcasts fill data over a
  **wireless/ender** modem using rednet protocol `"storagemon"`. Also answers
  `detail_req` messages with a per-item breakdown. Includes a setup wizard
  (`collector setup`) that auto-detects item/fluid peripherals by method and
  saves labels/groups/capacities to `storage.cfg`.
- **display.lua** — runs on the computer wired to an **Advanced** monitor.
  Listens to all collectors, merges entries by group, draws fill bars, and on
  touch shows an item breakdown for that group.

Each collector needs BOTH a wired modem (peripherals) and a wireless/ender
modem (rednet). The code deliberately picks the wireless one via `isWireless()`.

## Data model

- **Group** = merge key AND bar title. Same group = one combined bar
  (e.g. all 14 main silos share group `Main`).
- **Label** = per-unit name. Captured in setup; not currently shown anywhere.
- Fluid **capacity** is stored in **mB** (buckets x 1000).

## Constraints (important)

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

## Deploying via wget (no pastebin)

On a fresh computer, paste one of these single lines (adjust the branch/path
if you deploy from a fork or a non-`main` branch):

```
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua collector
```
```
wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua display
```

`install.lua` downloads the matching program (`collector.lua` / `display.lua`)
into the computer's root and writes a `startup.lua` that runs it, so the
program auto-starts on reboot. Re-running the same line re-fetches the latest
version and overwrites the local copy (config in `storage.cfg` is untouched).

## Behavior conventions

- Item bars: full = red (bad), empty = green (good).
- Fluid bars: inverted — full = green (good), empty = red (bad).
- Item stat: `NN% | <free slots> free`. Fluid stat: `NN% | <total>B` (buckets).
- `ORDER` in display.lua controls top-to-bottom order; unlisted groups fall
  below, alphabetically. Items section first, then a `----- Fluids -----`
  separator, then fluids.

## Possible next features (not yet built)

- Discord webhook alert via `http.post` when Main crosses ~90%.
- Fill-rate / time-to-full estimate per group (delta between scans).
- Buffer-mode inversion for the intermediate Resource Vault (low = bad).
- Paging if groups exceed one screen.
