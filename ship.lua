-- ship.lua  (CC:Tweaked) — run ONE per ship in the armada (e.g. "Bolt I").
-- Read-only telemetry only — no cannon control. Uses gps.locate() for live
-- position (works on a moving ship, no CC:Sable dependency for that part)
-- and broadcasts it, plus best-effort pitch/roll, to fleetboard.lua on the
-- master ship every REFRESH seconds.

local PROTO, CFGFILE, REFRESH = "shipnet", "ship.cfg", 5
local GPS_TIMEOUT = 2

local function shipPosition()
  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
  if ok and x then return { x = x, y = y, z = z } end
end

-- Best-effort pitch/roll ("gimbal" reading) via CC:Sable's `sublevel` API —
-- see CLAUDE.md Part 3 for the unverified-API caveat. Fails safe to nil/nil
-- if unavailable so the rest of the program still works either way.
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

local function setup()
  print("=== Ship Node setup ===")
  local cfg = {}
  write("Ship ID (e.g. \"Bolt I\"): ")
  cfg.id = read()
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

-- Diagnostic: dump whatever CC:Sable (or any other mod) actually exposes as
-- global tables, so figuring out the real sublevel/aero method names doesn't
-- require typing a snippet at the Lua prompt — run "ship probe" and paste
-- the output back. Doesn't need setup or rednet; purely local.
local function probe()
  local function dump(name, t)
    if type(t) ~= "table" then print(name..": not available"); return end
    print(name..":")
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do print("  "..k) end
  end
  dump("sublevel", _G.sublevel)
  dump("aero", _G.aero)
  dump("aerodynamics", _G.aerodynamics)
  dump("quaternion", _G.quaternion)
  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
  print(("gps.locate(): %s"):format(ok and x and ("%s, %s, %s"):format(x, y, z) or "failed"))
end

local arg = ...
if arg == "probe" then probe(); return end

local cfg = loadCfg()
if arg == "setup" or not cfg then cfg = setup() end

local mside = wirelessModem()
assert(mside, "No wireless/ender modem found for rednet")
rednet.open(mside)
print(("Ship \"%s\" running. Ctrl+T to stop."):format(cfg.id))

local function broadcast()
  local pos = shipPosition()
  local pitch, roll = shipPitchRoll()
  rednet.broadcast({ type="status", id=cfg.id, position=pos, pitch=pitch, roll=roll }, PROTO)
end

local timer = os.startTimer(0)
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == timer then
    broadcast(); timer = os.startTimer(REFRESH)
  end
end
