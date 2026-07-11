-- ship.lua  (CC:Tweaked + CC:Sable) — run ONE per manually-aimed gun ship,
-- on a computer physically placed ON that ship (required for CC:Sable's
-- `sublevel` global API to work at all — it only functions for a computer
-- that is itself on a Sub-Level). Reports position, pitch/roll, and cannon
-- ready state to fleetboard.lua on the master ship.
--
-- This program NEVER touches the cannon — aiming/firing stay fully manual
-- (binoculars). It's read-only telemetry, separate from the master.lua /
-- cannon.lua / radar.lua auto-aim system built for stationary cannons.
--
-- ============================================================================
-- VERIFY BEFORE TRUSTING THE NUMBERS: CC:Sable's exact `sublevel` (and the
-- bundled quaternion module's) method names could not be confirmed from
-- public docs — the docs site blocks automated fetches and GitHub code
-- search needs a login. On a ship computer, run:
--   for k in pairs(sublevel) do print(k) end
-- and fix shipPosition()/shipPitchRoll() below to match what you actually
-- see. Until then this degrades safely: if a call fails, that field just
-- reports nil and shows "?" on the board instead of crashing.
-- ============================================================================

local PROTO, CFGFILE, REFRESH = "shipnet", "ship.cfg", 2
local SIDES = { top=true, bottom=true, left=true, right=true, front=true, back=true }

local function shipPosition()
  if not sublevel then return nil end
  local ok, pos = pcall(sublevel.getPosition)
  if ok and type(pos) == "table" then return pos end
end

local function quaternionLib()
  if type(require) == "function" then
    local ok, lib = pcall(require, "quaternion")
    if ok and lib then return lib end
  end
  return _G.quaternion
end

local function shipPitchRoll()
  if not sublevel then return nil, nil end
  local ok, q = pcall(sublevel.getRotation)
  if not ok or not q then return nil, nil end
  local quat = quaternionLib()
  if not quat then return nil, nil end
  local ok2, euler = pcall(quat.toEuler, q)
  if not ok2 or type(euler) ~= "table" then return nil, nil end
  return euler.pitch, euler.roll
end

local function loadCfg()
  if not fs.exists(CFGFILE) then return nil end
  local f = fs.open(CFGFILE, "r"); local d = f.readAll(); f.close()
  return textutils.unserialise(d)
end
local function saveCfg(c)
  local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(c)); f.close()
end

-- Setup: a short Ship ID (shown as the row label on the fleet board) and
-- which redstone side carries the Big Cannons "Cannon Ready Lamp" signal
-- (lit = loaded, aimed, and ready to fire). Plain redstone.getInput(), no
-- peripheral or bridge mod needed for that part.
local function setup()
  print("=== Ship Node setup ===")
  local cfg = {}
  write("Ship ID (short label shown on the fleet board): ")
  cfg.id = read()
  repeat
    write("Redstone side wired to the Cannon Ready Lamp (top/bottom/left/right/front/back): ")
    cfg.side = read():lower()
  until SIDES[cfg.side]
  saveCfg(cfg)
  return cfg
end

local function wirelessModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then
      return n
    end
  end
end

local arg = ...
local cfg = loadCfg()
if arg == "setup" or not cfg then cfg = setup() end

local mside = wirelessModem()
assert(mside, "No wireless/ender modem found for rednet")
rednet.open(mside)
print(("Ship node \"%s\" running. Ctrl+T to stop."):format(cfg.id))

local function broadcast()
  local pos = shipPosition()
  local pitch, roll = shipPitchRoll()
  local ok, loaded = pcall(redstone.getInput, cfg.side)
  rednet.broadcast({ type="status", id=cfg.id, position=pos, pitch=pitch, roll=roll,
                      loaded = ok and loaded or false }, PROTO)
end

local timer = os.startTimer(0)
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == timer then
    broadcast(); timer = os.startTimer(REFRESH)
  end
end
