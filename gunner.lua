-- gunner.lua  (CC:Tweaked) — standalone single-cannon operator console for
-- Create: Big Cannons. Aim at a world coordinate and fire, all from ONE
-- computer. Unlike the distributed radar/master/cannon subsystem, this program
-- is self-contained: no rednet, no second computer.
--
-- What it does:
--   * finds its own position with gps.locate() every shot (so it works even
--     on a moving contraption/ship),
--   * derives the cannon MOUNT position as  gps + offset  where offset =
--     MOUNT - COMPUTER is captured once in setup (read off F3),
--   * asks the cannon's un-reportable facts (barrel length, propellant
--     charges, pitch limits) once in setup,
--   * on a target coordinate, brute-force-solves yaw + pitch (gravity + drag,
--     no closed form exists for CBC shells — same approach as master.lua),
--   * commands the cannon and fires automatically once it has slewed to aim.
--
-- Aiming backend is auto-detected:
--   * Create: Radars Auto Pitch + Auto Yaw Controllers (setAngle/getAngle/
--     stopAuto). IMPORTANT: setAngle alone is overridden by the radar mod's
--     own auto-aim (WFC); this program calls stopAuto() first so the computer
--     actually holds control — that is what makes yaw move. (setAngle re-arms
--     the controller, so stopAuto does not stop the axis from tracking.)
--   * or the CC:CBC "cannon_mount" peripheral (setComputerControl/
--     setTargetAngles/fire) if that mod is present instead.
--
-- Firing is separate from aiming and is auto/explicitly configured:
--   * REDSTONE (default): this computer pulses a redstone side wired to the
--     cannon's firing (e.g. through a redstone relay / igniter). No Fire
--     Controller peripheral needed.
--   * or a Create: Radars Fire Controller peripheral (fireOn/setPowered).
--
-- Wiring guide:  run  gunner wiring
-- Re-run setup:  run  gunner setup

local RAW     = "https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/gunner.lua"
local CFGFILE = "gunner.cfg"

-- CBC shell ballistics defaults (tunable per cannon in setup / gunner.cfg).
-- gravity 0.05 b/t, drag 1%/t, and 2 b/t of muzzle speed per propellant charge
-- match the community CBC ballistic calculator (initialSpeed = charges * 2).
local GRAV_DEFAULT, DRAG_DEFAULT, VPC_DEFAULT = 0.05, 0.01, 2.0
local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- ===========================================================================
-- Self-update: pull the latest gunner.lua from GitHub, then relaunch. The
-- "noupdate" sentinel arg on the relaunch prevents an infinite update loop.
-- ===========================================================================
local args = { ... }

local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local d = f.readAll(); f.close(); return d
end

local function selfUpdate()
  if not http then return false end
  local tmp = ".gunner.new"
  if fs.exists(tmp) then fs.delete(tmp) end
  local ok = shell.run("wget", RAW, tmp)
  if not ok or not fs.exists(tmp) then
    if fs.exists(tmp) then fs.delete(tmp) end
    return false
  end
  local new, cur = readFile(tmp), readFile("gunner.lua")
  fs.delete(tmp)
  if new and #new > 0 and new ~= cur then
    local f = fs.open("gunner.lua", "w"); f.write(new); f.close()
    return true
  end
  return false
end

if args[1] ~= "noupdate" then
  print("Checking for a newer gunner.lua ...")
  if selfUpdate() then
    print("Updated to the latest version. Relaunching...")
    local pass = { "noupdate" }
    for i = 1, #args do pass[#pass + 1] = args[i] end
    shell.run("gunner.lua", table.unpack(pass))
    return
  end
end
if args[1] == "noupdate" then table.remove(args, 1) end
local cmd = args[1]

-- ===========================================================================
-- Config
-- ===========================================================================
local function loadCfg()
  local d = readFile(CFGFILE)
  if not d then return nil end
  return textutils.unserialise(d)
end
local function saveCfg(c)
  local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(c)); f.close()
end

local function ask(prompt, default)
  if default ~= nil then write(prompt .. "[" .. tostring(default) .. "] ") else write(prompt) end
  local s = read()
  if s == "" then return default end
  return s
end
local function askNum(prompt, default)
  return tonumber(ask(prompt, default)) or default
end
local function fmt(n) return n and tostring(math.floor(n + 0.5)) or "?" end

-- ===========================================================================
-- Peripheral backend (aiming only — firing is handled separately below).
-- ===========================================================================
local function hasM(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do if x == m then return true end end
  return false
end

-- CC:CBC cannon_mount: setComputerControl / setTargetAngles / fire / assemble.
local function makeCbcBackend(name)
  local p = peripheral.wrap(name)
  pcall(function() p.setComputerControl(true) end)
  return {
    kind = "cbc", name = name, pitchName = nil, yawName = nil, realAngles = true,
    commission = function() pcall(function() p.setComputerControl(true) end) end,
    aim = function(yaw, pitch)
      pcall(function() p.setComputerControl(true) end)
      if not pcall(function() p.setTargetAngles(yaw, pitch) end) then
        pcall(function() p.setTargetYaw(yaw) end)
        pcall(function() p.setTargetPitch(pitch) end)
      end
    end,
    -- cannon_mount getInfo may expose the ACTUAL angle; try common field names.
    readAngles = function()
      local ok, info = pcall(function() return p.getInfo() end)
      if ok and type(info) == "table" then
        return info.yaw or info.currentYaw or info.cannonYaw,
               info.pitch or info.currentPitch or info.cannonPitch
      end
    end,
    hasFirePeripheral = true,
    firePeripheral = function(on) pcall(function() p.fire(on) end) end,
    assemble = function(on) return pcall(function() p.assemble(on) end) end,
    info = function() local ok, i = pcall(function() return p.getInfo() end); if ok then return i end end,
  }
end

-- Create: Radars Auto Pitch/Yaw Controllers (+ optional Fire Controller).
-- setAngle sets a TARGET; the radar mod's auto-aim (WeaponFiringControl) will
-- override it every tick UNLESS stopAuto() has been called — so commission()
-- calls stopAuto() on both axes, and we (re)call it before every aim. getAngle
-- returns the TARGET we set, not the live barrel angle, so readAngles() returns
-- nil: there is no true angle telemetry here, so settling is time-based.
local function makeRadarBackend(pn, yn, fn)
  local function commission()
    if pn then pcall(peripheral.call, pn, "stopAuto") end
    if yn then pcall(peripheral.call, yn, "stopAuto") end
  end
  return {
    kind = "radar", name = (yn or pn), pitchName = pn, yawName = yn, fireName = fn,
    realAngles = false,
    commission = commission,
    aim = function(yaw, pitch)
      commission()  -- take both axes off the mod's auto-aim first (fixes yaw)
      if yn then pcall(peripheral.call, yn, "setAngle", yaw) end
      if pn then pcall(peripheral.call, pn, "setAngle", pitch) end
    end,
    readAngles = function() return nil, nil end,       -- no live barrel telemetry
    targetAngles = function()                          -- for display only
      local y, p
      if yn then local ok, v = pcall(peripheral.call, yn, "getAngle"); if ok then y = v end end
      if pn then local ok, v = pcall(peripheral.call, pn, "getAngle"); if ok then p = v end end
      return y, p
    end,
    hasFirePeripheral = fn ~= nil,
    firePeripheral = function(on)
      if not fn then return end
      if on then pcall(peripheral.call, fn, "fireOn"); pcall(peripheral.call, fn, "setPowered", true)
      else       pcall(peripheral.call, fn, "fireOff"); pcall(peripheral.call, fn, "setPowered", false) end
    end,
    assemble = function() return false end,
    info = function() end,
  }
end

local function findBackend()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "cannon_mount" or hasM(name, "setTargetAngles") then
      return makeCbcBackend(name)
    end
  end
  local pn, yn, fn
  for _, name in ipairs(peripheral.getNames()) do
    if hasM(name, "setAngle") and hasM(name, "stopAuto") then
      local ty = (peripheral.getType(name) or ""):lower()
      if ty:find("yaw") then yn = name
      elseif ty:find("pitch") then pn = name
      elseif not pn then pn = name else yn = name end
    elseif hasM(name, "fireOn") or (hasM(name, "setPowered") and hasM(name, "isPowered")) then
      fn = name
    end
  end
  if pn or yn then return makeRadarBackend(pn, yn, fn) end
  return nil
end

local function findRadar()
  for _, name in ipairs(peripheral.getNames()) do
    if hasM(name, "getTracks") then return name end
  end
end

-- ===========================================================================
-- Ballistics — brute-force trajectory search (mirrors master.lua). No closed
-- form exists for a drag-affected CBC shell, so we scan pitch angles, simulate
-- each tick-by-tick, and bisect around sign changes of (height - target height).
-- ===========================================================================
local cfg  -- populated after setup/load; ballistics read constants off it.

local function muzzlePos(mount, barrel, yawDeg, pitchDeg)
  local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
  local dx = -math.sin(yaw) * math.cos(pitch)
  local dz =  math.cos(yaw) * math.cos(pitch)
  local dy =  math.sin(pitch)
  return { x = mount.x + dx * barrel, y = mount.y + dy * barrel, z = mount.z + dz * barrel }
end

local function heightAtDistance(speed, pitchDeg, dist)
  local rad = math.rad(pitchDeg)
  local vh, vy = speed * math.cos(rad), speed * math.sin(rad)
  local x, y = 0, 0
  for _ = 1, 3000 do
    vy = vy - cfg.gravity
    vh, vy = vh * (1 - cfg.drag), vy * (1 - cfg.drag)
    x, y = x + vh, y + vy
    if x >= dist then return y end
    if vh < 0.001 then return nil end
  end
  return nil
end

local function solvePitches(speed, dist, dh)
  local sols, prevErr, prevDeg = {}, nil, nil
  for deg = cfg.pitchMin, cfg.pitchMax, 1 do
    local h = heightAtDistance(speed, deg, dist)
    local err = h and (h - dh) or nil
    if err and prevErr and ((prevErr < 0 and err >= 0) or (prevErr > 0 and err <= 0)) then
      local a, b = prevDeg, deg
      for _ = 1, 25 do
        local mid = (a + b) / 2
        local hm = heightAtDistance(speed, mid, dist)
        local errm = hm and (hm - dh) or -math.huge
        if (prevErr < 0 and errm < 0) or (prevErr > 0 and errm > 0) then a = mid else b = mid end
      end
      sols[#sols + 1] = (a + b) / 2
    end
    prevErr, prevDeg = err, deg
  end
  return sols
end

local function solveAim(mount, target)
  local yaw = math.deg(atan2(-(target.x - mount.x), target.z - mount.z))
  if yaw < 0 then yaw = yaw + 360 end
  local sols = {}
  local pitch = 20
  for _ = 1, 4 do
    local m = muzzlePos(mount, cfg.barrel or 0, yaw, pitch)
    local dx, dz = target.x - m.x, target.z - m.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local dh = target.y - m.y
    yaw = math.deg(atan2(-dx, dz)); if yaw < 0 then yaw = yaw + 360 end
    sols = solvePitches(cfg.muzzleSpeed, dist, dh)
    if #sols == 0 then return yaw, {} end
    pitch = sols[1]
  end
  return yaw, sols
end

-- ===========================================================================
-- Position
-- ===========================================================================
local function currentMount()
  local cx, cy, cz = gps.locate(2)
  if cx then
    return { x = cx + cfg.offX, y = cy + cfg.offY, z = cz + cfg.offZ }, true
  end
  if cfg.mountX then
    return { x = cfg.mountX, y = cfg.mountY, z = cfg.mountZ }, false
  end
  return nil, false
end

-- ===========================================================================
-- Firing (separate from aiming). Redstone by default; Fire Controller optional.
-- ===========================================================================
local backend

local function fireSet(on)
  if cfg.fireMode == "peripheral" and backend and backend.hasFirePeripheral then
    backend.firePeripheral(on)
  else
    redstone.setOutput(cfg.fireSide or "back", on)
  end
end

local function firePulse()
  fireSet(true); sleep(cfg.firePulse or 0.5); fireSet(false)
end

-- ===========================================================================
-- Setup wizard
-- ===========================================================================
local function firingSetup(c)
  print("\n-- Firing method --")
  local peri = findBackend()
  local hasFC = peri and peri.hasFirePeripheral
  print("  1) Redstone pulse from THIS computer (into a redstone relay/igniter) [default]")
  print("  2) Create: Radars Fire Controller peripheral" .. (hasFC and " (detected)" or " (not detected)"))
  local choice = ask("  Choose 1 or 2: ", (c.fireMode == "peripheral") and "2" or "1")
  if choice == "2" then
    c.fireMode = "peripheral"
    print("  Firing via the Fire Controller peripheral.")
  else
    c.fireMode = "redstone"
    print("  Which SIDE of the computer outputs the firing redstone?")
    print("  (top / bottom / left / right / front / back — the side wired to the relay)")
    local s = ask("  Side: ", c.fireSide or "back"):lower()
    c.fireSide = SIDES[s] and s or "back"
  end
  c.firePulse = askNum("  Fire pulse length in seconds (default 0.5): ", c.firePulse or 0.5)
end

local function setup(existing)
  local c = existing or {}
  print("=== Gunner setup (Create: Big Cannons) ===")

  print("\nLocating this computer via GPS...")
  local cx, cy, cz = gps.locate(3)
  if cx then
    print(("  Computer is at %d %d %d"):format(cx, cy, cz))
  else
    print("  GPS unavailable — no GPS host cluster in range.")
    print("  Enter the COMPUTER's own block coords (F3) instead:")
    cx = askNum("    Computer X: ", 0)
    cy = askNum("    Computer Y: ", 0)
    cz = askNum("    Computer Z: ", 0)
  end

  print("\nEnter the cannon MOUNT (pivot) block coords — read off F3.")
  print("This is the yaw/pitch pivot block, NOT the muzzle.")
  local mx = askNum("  Mount X: ", c.mountX)
  local my = askNum("  Mount Y: ", c.mountY)
  local mz = askNum("  Mount Z: ", c.mountZ)
  c.mountX, c.mountY, c.mountZ = mx, my, mz
  c.offX, c.offY, c.offZ = mx - cx, my - cy, mz - cz
  print(("  Offset MOUNT-COMPUTER = %d %d %d (mount tracked live via gps+offset)")
    :format(c.offX, c.offY, c.offZ))

  print("\n-- Cannon facts no peripheral reports --")
  c.barrel  = askNum("  Barrel length in blocks (mount to muzzle exit): ", c.barrel or 0)
  c.charges = askNum("  Propellant charges loaded: ", c.charges or 1)
  c.velPerCharge = askNum("  Muzzle blocks/tick per charge (default 2): ", c.velPerCharge or VPC_DEFAULT)
  c.muzzleSpeed = c.charges * c.velPerCharge
  print(("  -> muzzle speed = %.2f blocks/tick"):format(c.muzzleSpeed))

  print("\n-- Elevation limits (how far the barrel can tilt) --")
  print("  Max pitch = highest upward angle; Min pitch = lowest (negative if it")
  print("  can depress below horizontal, 0 if it can only aim level-or-up).")
  c.pitchMax = askNum("  Max pitch degrees up (e.g. 60): ", c.pitchMax or 60)
  c.pitchMin = askNum("  Min pitch degrees (e.g. -30, or 0): ", c.pitchMin or 0)

  firingSetup(c)

  print("\n-- Slew wait --")
  print("  These controllers report no live barrel angle, so gunner waits a")
  print("  fixed time for the cannon to rotate to aim before firing. Set it long")
  print("  enough that the barrel always reaches the angle first.")
  c.slewSeconds = askNum("  Seconds to wait before firing (default 4): ", c.slewSeconds or 4)

  print("\n-- Ballistics constants (press Enter to keep CBC defaults) --")
  c.gravity = askNum("  Gravity blocks/tick^2 (default 0.05): ", c.gravity or GRAV_DEFAULT)
  c.drag    = askNum("  Drag fraction/tick (default 0.01): ", c.drag or DRAG_DEFAULT)

  print("\n-- Calibration offsets (leave 0; adjust only if shots aim off) --")
  c.yawOffset   = askNum("  Yaw offset deg (default 0): ", c.yawOffset or 0)
  c.pitchOffset = askNum("  Pitch offset deg (default 0): ", c.pitchOffset or 0)
  c.prefArc     = c.prefArc or "low"

  saveCfg(c)
  print("\nSaved gunner.cfg.")
  return c
end

-- ===========================================================================
-- Aim & fire
-- ===========================================================================
local function pickPitch(sols)
  local inRange = {}
  for _, p in ipairs(sols) do
    if p >= cfg.pitchMin - 0.01 and p <= cfg.pitchMax + 0.01 then inRange[#inRange + 1] = p end
  end
  if #inRange == 0 then return nil, sols end
  if cfg.prefArc == "high" then return inRange[#inRange], inRange end
  return inRange[1], inRange
end

-- Wait for the cannon to reach the commanded angles. With real telemetry
-- (cannon_mount) settle early when close; otherwise wait the fixed slew time.
local function slewWait(tyaw, tpitch)
  local wait = cfg.slewSeconds or 4
  if backend and backend.realAngles then
    local deadline = os.clock() + wait
    while os.clock() < deadline do
      local y, p = backend.readAngles()
      if y and p then
        local dy = math.abs(((y - tyaw + 540) % 360) - 180)
        if dy <= 1.5 and math.abs(p - tpitch) <= 1.5 then return true end
      end
      sleep(0.2)
    end
    return false
  end
  sleep(wait)
  return false
end

local function confirmFire(secs)
  print(("Firing in %ds — press any key to ABORT."):format(secs))
  local t = os.startTimer(secs)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == t then return true end
    if ev == "key" or ev == "char" then print("Aborted."); return false end
  end
end

local function engage(tx, ty, tz)
  if not backend then print("No cannon aiming peripheral wired — run: gunner wiring"); return end
  local mount, live = currentMount()
  if not mount then print("No GPS fix and no saved mount — run: gunner setup"); return end
  if not live then print("(GPS unavailable — using static mount from setup)") end

  local target = { x = tx, y = ty, z = tz }
  local yaw, sols = solveAim(mount, target)
  local pitch, inRange = pickPitch(sols)

  local dx, dz = tx - mount.x, tz - mount.z
  local dist = math.sqrt(dx * dx + dz * dz)
  print(("\nTarget %d %d %d  | ground dist %d  | dY %d")
    :format(tx, ty, tz, math.floor(dist + .5), ty - mount.y))

  if #sols == 0 then print("OUT OF RANGE — no trajectory reaches it (add charges / move closer)."); return end
  if not pitch then
    local s = {}; for _, p in ipairs(sols) do s[#s + 1] = ("%.1f"):format(p) end
    print("Solution exists at pitch " .. table.concat(s, " / ") .. "deg but that's")
    print(("outside this cannon's limits (%d..%d). Adjust in setup if the mount can reach it.")
      :format(cfg.pitchMin, cfg.pitchMax))
    return
  end

  local arcs = {}; for _, p in ipairs(inRange) do arcs[#arcs + 1] = ("%.1f"):format(p) end
  print(("Firing solution: yaw %.1fdeg, pitch %.1fdeg  (%s arc%s: %s)")
    :format(yaw, pitch, cfg.prefArc, #inRange > 1 and "s" or "", table.concat(arcs, " / ")))

  local aimYaw, aimPitch = yaw + cfg.yawOffset, pitch + cfg.pitchOffset
  backend.aim(aimYaw, aimPitch)
  print("Slewing to aim...")
  if slewWait(aimYaw, aimPitch) then print("On target.") else print("Slew wait elapsed — proceeding.") end

  if confirmFire(3) then
    firePulse()
    print("FIRED.")
  end
end

-- ===========================================================================
-- Radar target picker (optional — Create: Radars getTracks)
-- ===========================================================================
local function radarPick()
  local r = findRadar()
  if not r then print("No radar peripheral (getTracks) on this computer."); return end
  local ok, tracks = pcall(peripheral.call, r, "getTracks")
  if not ok or type(tracks) ~= "table" or #tracks == 0 then print("No radar tracks right now."); return end
  print("Radar tracks:")
  for i, t in ipairs(tracks) do
    local p = t.position or {}
    print(("  %d) %-10s @ %s %s %s"):format(i, tostring(t.entityType or t.category or "?"),
      fmt(p.x), fmt(p.y), fmt(p.z)))
  end
  local i = askNum("Pick track # (blank cancels): ", nil)
  local t = i and tracks[i]
  if not t or not t.position then print("Cancelled."); return end
  engage(t.position.x, t.position.y, t.position.z)
end

-- ===========================================================================
-- Wiring / hookup guide
-- ===========================================================================
local function wiring()
  print("=== Gunner — what to hook up ===")
  print("")
  print("1. COMPUTER with a WIRED MODEM, connected by networking cable to the")
  print("   cannon's Auto Pitch Controller and Auto Yaw Controller (right-click")
  print("   each with the modem, or place a full-block wired modem on them).")
  print("")
  print("2. AIMING — either route, auto-detected:")
  print("   a) Create: Radars Auto Pitch Controller + Auto Yaw Controller,")
  print("      Data-Linked to the cannon mount as usual. gunner calls stopAuto()")
  print("      so the mod's auto-aim stops fighting the computer (this is what")
  print("      makes YAW move), then setAngle() on each axis.")
  print("   b) CC:CBC 'Cannon Mount' peripheral, if you have that mod instead.")
  print("")
  print("   The cannon MOUNT still needs rotational (kinetic) power so the")
  print("   controllers can physically turn it — the same drive the mod needs.")
  print("")
  print("3. FIRING — no Fire Controller needed:")
  print("   Wire a redstone line from ONE SIDE of this computer to the cannon's")
  print("   firing (through your redstone relay / igniter). gunner pulses that")
  print("   side to fire. Pick the side in setup. (Or use a Fire Controller")
  print("   peripheral and choose option 2 in setup.)")
  print("")
  print("4. GPS: a CC GPS host cluster in range so gps.locate() returns coords")
  print("   (or type them manually in setup).")
  print("")
  print("5. RADAR (optional): a Create: Radars getTracks() peripheral to pick")
  print("   live targets with the 'radar' command.")
  print("")
  print("Then: gunner setup  (F3 gives the mount & computer coords).")
end

-- ===========================================================================
-- Main
-- ===========================================================================
if cmd == "wiring" then wiring(); return end

cfg = loadCfg()
if cmd == "setup" or not cfg then cfg = setup(cfg) end
-- Backfill any missing fields so an older cfg still runs.
cfg.gravity = cfg.gravity or GRAV_DEFAULT
cfg.drag = cfg.drag or DRAG_DEFAULT
cfg.velPerCharge = cfg.velPerCharge or VPC_DEFAULT
cfg.muzzleSpeed = cfg.muzzleSpeed or (cfg.charges or 1) * cfg.velPerCharge
cfg.pitchMin = cfg.pitchMin or 0
cfg.pitchMax = cfg.pitchMax or 60
cfg.yawOffset = cfg.yawOffset or 0
cfg.pitchOffset = cfg.pitchOffset or 0
cfg.prefArc = cfg.prefArc or "low"
cfg.fireMode = cfg.fireMode or "redstone"
cfg.fireSide = cfg.fireSide or "back"
cfg.firePulse = cfg.firePulse or 0.5
cfg.slewSeconds = cfg.slewSeconds or 4

backend = findBackend()
-- Ensure the firing line starts LOW (safety); controllers are taken off the
-- mod's auto-aim lazily, on the first aim/test, not merely by launching.
if cfg.fireMode == "redstone" then pcall(function() redstone.setOutput(cfg.fireSide, false) end) end

print("")
print("=== GUNNER — Create: Big Cannons targeting ===")
if backend then
  print("Aiming backend: " .. backend.kind)
  if backend.kind == "radar" then
    print("  pitch controller: " .. tostring(backend.pitchName or "NOT FOUND"))
    print("  yaw controller:   " .. tostring(backend.yawName or "NOT FOUND"))
    if not backend.pitchName or not backend.yawName then
      print("  ! A controller is missing — check the wired-modem hookup for that axis.")
    end
  end
else
  print("WARNING: no cannon peripheral found. Run 'gunner wiring'. (Math still works.)")
end
if cfg.fireMode == "peripheral" then print("Firing: Fire Controller peripheral")
else print("Firing: redstone pulse on '" .. cfg.fireSide .. "' side (" .. cfg.firePulse .. "s)") end
print(("Mount = gps + offset (%d,%d,%d) | %d charges -> %.1f b/t | pitch %d..%d | slew %ss")
  :format(cfg.offX or 0, cfg.offY or 0, cfg.offZ or 0, cfg.charges or 0,
          cfg.muzzleSpeed, cfg.pitchMin, cfg.pitchMax, cfg.slewSeconds))
print("Commands: aim | radar | test | arc | angles | fire | hold | info | setup | wiring | quit")

while true do
  write("\ngunner> ")
  local line = read()
  local w = {}
  for tok in line:gmatch("%S+") do w[#w + 1] = tok end
  local c = (w[1] or ""):lower()

  if c == "aim" then
    local tx = tonumber(w[2]) or askNum("Target X: ", nil)
    local ty = tonumber(w[3]) or askNum("Target Y: ", nil)
    local tz = tonumber(w[4]) or askNum("Target Z: ", nil)
    if tx and ty and tz then engage(tx, ty, tz) else print("Need X Y Z.") end

  elseif c == "radar" then
    radarPick()

  elseif c == "test" then
    -- Directly command a single raw angle to prove each axis physically moves
    -- (takes it off auto-aim first). Usage: test yaw <deg> | test pitch <deg>
    if not backend then print("No cannon peripheral.")
    else
      local axis, a = (w[2] or ""):lower(), tonumber(w[3])
      backend.commission()
      if axis == "yaw" and a and backend.yawName then
        pcall(peripheral.call, backend.yawName, "setAngle", a)
        print(("Commanded YAW -> %.1f. Watch the cannon; it should rotate."):format(a))
      elseif axis == "pitch" and a and backend.pitchName then
        pcall(peripheral.call, backend.pitchName, "setAngle", a)
        print(("Commanded PITCH -> %.1f. Watch the cannon; it should tilt."):format(a))
      else
        print("Usage: test yaw <deg> | test pitch <deg>")
        if backend.kind == "cbc" then print("(cbc backend aims both axes together; use 'angles <yaw> <pitch>')") end
      end
    end

  elseif c == "arc" then
    cfg.prefArc = (cfg.prefArc == "low") and "high" or "low"
    saveCfg(cfg); print("Preferred arc: " .. cfg.prefArc)

  elseif c == "angles" then
    if backend then
      local y = tonumber(w[2]) or askNum("Yaw: ", nil)
      local p = tonumber(w[3]) or askNum("Pitch: ", nil)
      if y and p then backend.aim(y, p); print(("Commanded yaw %.1f pitch %.1f"):format(y, p)) end
    else print("No cannon peripheral.") end

  elseif c == "fire" then
    firePulse(); print("FIRED.")

  elseif c == "hold" then
    fireSet(false); print("Fire signal off.")

  elseif c == "assemble" then
    if backend and backend.assemble then local ok = backend.assemble(true); print(ok and "Assembled." or "Assemble not supported by this backend.") end

  elseif c == "disassemble" then
    if backend and backend.assemble then backend.assemble(false); print("Disassembled.") end

  elseif c == "info" then
    local m, live = currentMount()
    if m then print(("Mount %d %d %d (%s)"):format(math.floor(m.x + .5), math.floor(m.y + .5),
      math.floor(m.z + .5), live and "live GPS" or "static")) end
    if backend then
      local y, p
      if backend.targetAngles then y, p = backend.targetAngles() else y, p = backend.readAngles() end
      print(("Commanded angles: yaw %s pitch %s"):format(y and ("%.1f"):format(y) or "?", p and ("%.1f"):format(p) or "?"))
      local i = backend.info(); if i then print("getInfo: " .. textutils.serialise(i)) end
    end
    print(("Firing: %s%s"):format(cfg.fireMode, cfg.fireMode == "redstone" and (" on " .. cfg.fireSide) or ""))

  elseif c == "setup" then
    if backend and cfg.fireMode == "redstone" then pcall(function() redstone.setOutput(cfg.fireSide, false) end) end
    cfg = setup(cfg); backend = findBackend()

  elseif c == "wiring" then
    wiring()

  elseif c == "quit" or c == "exit" then
    fireSet(false)
    print("Bye."); return

  elseif c == "" then
    -- ignore
  else
    print("Unknown command. Try: aim / radar / test / arc / angles / fire / info / setup / wiring / quit")
  end
end
