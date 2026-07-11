-- ship.lua  (CC:Tweaked) — run ONE per gun ship (e.g. "Bolt I"), wired to
-- that ship's cannon(s): each cannon's Auto Pitch Controller, Auto Yaw
-- Controller, and Fire Controller (Create: Radars' CC:Tweaked compat).
-- Uses gps.locate() for the ship's own live position (works on a moving
-- ship as long as your GPS hosts are up — no CC:Sable dependency for this).
-- Receives a target point from fleetboard.lua, computes a firing solution
-- per cannon (muzzle-offset aware, same brute-force ballistics as
-- master.lua), aims, and FIRES AUTOMATICALLY once settled on target.
--
-- Run "ship commission" (terminal only) to hand this ship's cannons from
-- the radar mod's own auto-aim network to computer control — same one-time
-- typed "YES" gate as master.lua's commission, since stopAuto() is
-- irreversible without physically re-linking in-game.
--
-- ============================================================================
-- CALIBRATION NOTES (same caveats as master.lua — nothing here has been
-- fired in-game yet):
-- - GRAVITY/DRAG are unverified placeholders (see master.lua's comment).
-- - Yaw convention / muzzle forward vector is a best guess.
-- - AIM_TOLERANCE_DEG / AIM_TIMEOUT below control when "aimed" flips to
--   "fire": tune AIM_TOLERANCE_DEG tighter once you've seen how precisely
--   the Auto Pitch/Yaw Controllers actually settle in-game, and AIM_TIMEOUT
--   is a safety valve so a cannon that can't quite settle still fires
--   instead of waiting forever.
-- - Ship pitch/roll (shipPitchRoll below) is a best-effort CC:Sable
--   `sublevel` read, kept only as optional extra telemetry for
--   fleetboard.lua — see the same unverified-API note as before. It is NOT
--   used in the aiming math, so a wrong/missing reading there doesn't
--   affect firing accuracy, only what fleetboard.lua displays.
-- ============================================================================

local PROTO, CFGFILE, REFRESH = "shipnet", "ship.cfg", 1
local MPS_PER_CHARGE, TICKS_PER_SEC = 40, 20     -- muzzle speed: 40 m/s per charge
local GRAVITY, DRAG = -0.04, 0.01                -- UNVERIFIED, see above
local AIM_TOLERANCE_DEG, AIM_TIMEOUT = 1.5, 8     -- degrees, seconds
local GPS_TIMEOUT = 2

-- ---------------------------------------------------------------------------
-- Ballistics (same approach as master.lua — see that file for the fuller
-- writeup of why this is brute-force rather than a closed-form formula).
-- ---------------------------------------------------------------------------

local function muzzlePos(mount, barrel, yawDeg, pitchDeg)
  local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
  local dx = -math.sin(yaw) * math.cos(pitch)
  local dz =  math.cos(yaw) * math.cos(pitch)
  local dy =  math.sin(pitch)
  return { x = mount.x + dx*barrel, y = mount.y + dy*barrel, z = mount.z + dz*barrel }
end

local function heightAtDistance(speed, pitchDeg, dist)
  local rad = math.rad(pitchDeg)
  local vh, vy = speed*math.cos(rad), speed*math.sin(rad)
  local x, y = 0, 0
  for _ = 1, 2400 do
    vy = vy + GRAVITY
    vh, vy = vh*(1-DRAG), vy*(1-DRAG)
    x, y = x + vh, y + vy
    if x >= dist then return y end
    if vh < 0.001 then return nil end
  end
  return nil
end

local function solvePitches(speed, dist, dh)
  local solutions = {}
  local prevErr, prevDeg
  for deg = 1, 89 do
    local h = heightAtDistance(speed, deg, dist)
    local err = h and (h - dh) or nil
    if err and prevErr and ((prevErr < 0 and err >= 0) or (prevErr > 0 and err <= 0)) then
      local lo, hi = prevDeg, deg
      for _ = 1, 25 do
        local mid = (lo+hi)/2
        local hm = heightAtDistance(speed, mid, dist)
        local errm = hm and (hm - dh) or -math.huge
        if (prevErr < 0 and errm < 0) or (prevErr > 0 and errm > 0) then lo = mid else hi = mid end
      end
      solutions[#solutions+1] = (lo+hi)/2
    end
    prevErr, prevDeg = err, deg
  end
  return solutions
end

local function solveAim(mount, barrel, muzzleSpeed, target)
  local yaw = math.deg(math.atan2(target.x - mount.x, target.z - mount.z))
  if yaw < 0 then yaw = yaw + 360 end
  local pitch = 20
  for _ = 1, 3 do
    local muzzle = muzzlePos(mount, barrel or 0, yaw, pitch)
    local dx, dz = target.x - muzzle.x, target.z - muzzle.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local dh = target.y - muzzle.y
    yaw = math.deg(math.atan2(dx, dz)); if yaw < 0 then yaw = yaw + 360 end
    local sols = solvePitches(muzzleSpeed, dist, dh)
    if #sols == 0 then return nil end
    pitch = sols[1]
  end
  return yaw, pitch
end

local function angleDiff(a, b)
  local d = (a - b) % 360
  if d > 180 then d = 360 - d end
  return d
end

-- pcall's failure branch returns the error string as its 2nd value, which
-- must never leak into angleDiff's arithmetic — this collapses any failure
-- (missing peripheral, disconnected wire, etc.) to a clean nil instead.
local function safeCall(peripheralName, method, ...)
  if not peripheralName then return nil end
  local ok, result = pcall(peripheral.call, peripheralName, method, ...)
  if ok then return result end
  return nil
end

-- ---------------------------------------------------------------------------
-- Position / attitude
-- ---------------------------------------------------------------------------

local function shipPosition()
  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
  if ok and x then return { x = x, y = y, z = z } end
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

-- ---------------------------------------------------------------------------
-- Peripherals / config
-- ---------------------------------------------------------------------------

local function hasM(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do if x == m then return true end end
  return false
end
local function kindOf(name)
  if hasM(name, "setAngle") and hasM(name, "getAngle") and hasM(name, "stopAuto") then
    local ty = (peripheral.getType(name) or ""):lower()
    if ty:find("yaw") then return "yaw"
    elseif ty:find("pitch") then return "pitch"
    else return "angle" end
  elseif hasM(name, "isPowered") and hasM(name, "fireOn") and hasM(name, "fireOff") and hasM(name, "setPowered") then
    return "fire"
  end
end

local function loadCfg()
  if not fs.exists(CFGFILE) then return nil end
  local f = fs.open(CFGFILE, "r"); local d = f.readAll(); f.close()
  return textutils.unserialise(d)
end
local function saveCfg(c)
  local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(c)); f.close()
end

local function countCannons(cfg)
  local n = 0; for _ in pairs(cfg.cannons) do n = n + 1 end; return n
end

-- Setup: ship name, then group each detected pitch/yaw/fire controller
-- under a Cannon ID (blank reuses the last ID — a cannon's three
-- controllers are usually placed together), then barrel length + charges
-- per cannon. No mount position is asked here: it's read live via GPS.
local function setup()
  print("=== Bolt (ship cannon) setup ===")
  local cfg = { cannons = {} }
  write("Ship ID (e.g. \"Bolt I\"): ")
  cfg.id = read()

  local lastId
  for _, name in ipairs(peripheral.getNames()) do
    local role = kindOf(name)
    if role == "angle" then
      print(("\nFound %s  [pitch/yaw controller, type=%s]"):format(name, peripheral.getType(name) or "?"))
      write("  Pitch or yaw? (p/y, blank = skip): ")
      local ans = read():lower()
      role = (ans == "p" and "pitch") or (ans == "y" and "yaw") or nil
    elseif role then
      print(("\nFound %s  [%s controller]"):format(name, role))
    end
    if role then
      local prompt = lastId and ("  Cannon ID (blank = \""..lastId.."\"): ") or "  Cannon ID (blank = skip): "
      write(prompt)
      local id = read()
      if id == "" then id = lastId end
      if id and id ~= "" then
        cfg.cannons[id] = cfg.cannons[id] or { id = id }
        cfg.cannons[id][role] = name
        lastId = id
        print(("  assigned to cannon \"%s\"."):format(id))
      else
        print("  skipped.")
      end
    end
  end

  for id, cn in pairs(cfg.cannons) do
    print(("\n-- Ballistics for cannon \"%s\" --"):format(id))
    write("  Barrel length in blocks (mount to muzzle exit): "); cn.barrel = tonumber(read()) or 0
    write("  Propellant charges loaded: "); cn.charges = tonumber(read()) or 1
    cn.muzzleSpeed = cn.charges * MPS_PER_CHARGE / TICKS_PER_SEC
    cn.commissioned = false
  end

  saveCfg(cfg)
  print(("\nSaved ship \"%s\" with %d cannon(s)."):format(cfg.id, countCannons(cfg)))
  return cfg
end

local function wirelessModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then
      return n
    end
  end
end

-- ---------------------------------------------------------------------------
-- ship commission — same one-time typed "YES" gate as master.lua, scoped to
-- just this ship's own cannons.
-- ---------------------------------------------------------------------------

local function commission(cfg)
  local pending = {}
  for id, cn in pairs(cfg.cannons) do if not cn.commissioned then pending[#pending+1] = id end end
  table.sort(pending)
  if #pending == 0 then
    print("All cannons on this ship are already commissioned.")
    return
  end
  print(("Cannon(s) NOT yet under computer control: %s"):format(table.concat(pending, ", ")))
  print("This calls stopAuto() on each one's pitch + yaw controllers,")
  print("permanently handing control from the radar mod's auto-aim network")
  print("to this computer. Undoing it requires physically re-linking in-game.")
  write("Type YES to commission all of the above: ")
  if read() == "YES" then
    for _, id in ipairs(pending) do
      local cn = cfg.cannons[id]
      if cn.pitch then pcall(peripheral.call, cn.pitch, "stopAuto") end
      if cn.yaw then pcall(peripheral.call, cn.yaw, "stopAuto") end
      cn.commissioned = true
    end
    saveCfg(cfg)
    print("Commissioned.")
  else
    print("Cancelled — nothing changed.")
  end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local arg = ...
local cfg = loadCfg()
if not cfg then cfg = setup() end
if arg == "setup" then cfg = setup() end

local mside = wirelessModem()
assert(mside, "No wireless/ender modem found for rednet")
rednet.open(mside)

if arg == "commission" then
  commission(cfg)
  return
end

print(("Ship \"%s\" running with %d cannon(s). Ctrl+T to stop."):format(cfg.id, countCannons(cfg)))

-- Runtime-only state per cannon (not persisted): aiming/fired state machine.
local runtime = {}
for id in pairs(cfg.cannons) do runtime[id] = { state = "idle" } end

local function aimAllAt(target)
  local pos = shipPosition()
  if not pos then
    print("GPS lock failed — can't aim without a position.")
    return
  end
  for id, cn in pairs(cfg.cannons) do
    if cn.commissioned then
      local yaw, pitch = solveAim(pos, cn.barrel, cn.muzzleSpeed, target)
      if yaw then
        if cn.yaw then pcall(peripheral.call, cn.yaw, "setAngle", yaw) end
        if cn.pitch then pcall(peripheral.call, cn.pitch, "setAngle", pitch) end
        runtime[id] = { state = "aiming", targetYaw = yaw, targetPitch = pitch, startedAt = os.clock() }
      else
        print(("Cannon \"%s\": target out of range."):format(id))
        runtime[id] = { state = "idle" }
      end
    end
  end
end

-- Check each aiming cannon; fire once its actual angle has settled near the
-- commanded angle (or after AIM_TIMEOUT, so a cannon that can't quite
-- settle still fires instead of waiting forever).
local function checkAndFire()
  for id, cn in pairs(cfg.cannons) do
    local rt = runtime[id]
    if cn.commissioned and rt.state == "aiming" then
      local curYaw   = safeCall(cn.yaw,   "getAngle")
      local curPitch = safeCall(cn.pitch, "getAngle")
      local settled = curYaw and curPitch
        and angleDiff(curYaw, rt.targetYaw) <= AIM_TOLERANCE_DEG
        and angleDiff(curPitch, rt.targetPitch) <= AIM_TOLERANCE_DEG
      local timedOut = (os.clock() - rt.startedAt) > AIM_TIMEOUT
      if settled or timedOut then
        if cn.fire then pcall(peripheral.call, cn.fire, "keepFiring") end
        runtime[id] = { state = "fired" }
      end
    end
  end
end

local function broadcast()
  local pos = shipPosition()
  local shipPitch, shipRoll = shipPitchRoll()
  local cannons = {}
  for id, cn in pairs(cfg.cannons) do
    local rt = runtime[id]
    cannons[#cannons+1] = {
      id = id, commissioned = cn.commissioned, state = rt.state,
      yaw   = safeCall(cn.yaw,   "getAngle"),
      pitch = safeCall(cn.pitch, "getAngle"),
    }
  end
  rednet.broadcast({ type="status", id=cfg.id, position=pos, pitch=shipPitch, roll=shipRoll,
                      cannons=cannons }, PROTO)
end

local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == timer then
    checkAndFire()
    broadcast()
    timer = os.startTimer(REFRESH)
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "aim" then
    aimAllAt(b.target)
  end
end
