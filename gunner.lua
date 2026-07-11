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
--   * commands the cannon and fires automatically once it settles on aim.
--
-- Aiming/firing backend is auto-detected:
--   * CC:CBC  "cannon_mount" peripheral (setComputerControl/setTargetAngles/
--     fire/assemble) — the direct Create: Big Cannons route; preferred.
--   * fallback: Create: Radars Auto Pitch/Yaw + Fire controllers
--     (setAngle/getAngle + fireOn/fireOff/setPowered), so it also works if
--     that's how the cannon is wired.
--
-- Wiring guide:  run  gunner wiring
-- Re-run setup: run  gunner setup

local RAW     = "https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/gunner.lua"
local CFGFILE = "gunner.cfg"

-- CBC shell ballistics defaults (tunable per cannon in setup / gunner.cfg).
-- gravity 0.05 b/t, drag 1%/t, and 2 b/t of muzzle speed per propellant charge
-- match the community CBC ballistic calculator (initialSpeed = charges * 2).
local GRAV_DEFAULT, DRAG_DEFAULT, VPC_DEFAULT = 0.05, 0.01, 2.0

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
-- Peripheral backend (aiming + firing), auto-detected.
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
    kind = "cbc", name = name,
    aim = function(yaw, pitch)
      pcall(function() p.setComputerControl(true) end)
      if not pcall(function() p.setTargetAngles(yaw, pitch) end) then
        pcall(function() p.setTargetYaw(yaw) end)
        pcall(function() p.setTargetPitch(pitch) end)
      end
    end,
    readAngles = function()
      local ok, info = pcall(function() return p.getInfo() end)
      if ok and type(info) == "table" then
        return info.yaw or info.currentYaw or info.cannonYaw,
               info.pitch or info.currentPitch or info.cannonPitch
      end
    end,
    fire = function(on) pcall(function() p.fire(on) end) end,
    assemble = function(on) return pcall(function() p.assemble(on) end) end,
    info = function() local ok, i = pcall(function() return p.getInfo() end); if ok then return i end end,
  }
end

-- Create: Radars Auto Pitch/Yaw controllers + Fire controller (the same
-- peripherals cannon.lua/master.lua drive), for when a CBC cannon_mount isn't
-- present. Pitch/yaw share a method set, so we tell them apart by type name.
local function makeRadarBackend(pn, yn, fn)
  return {
    kind = "radar", name = (yn or pn),
    aim = function(yaw, pitch)
      if yn then pcall(peripheral.call, yn, "setAngle", yaw) end
      if pn then pcall(peripheral.call, pn, "setAngle", pitch) end
    end,
    readAngles = function()
      local y, p
      if yn then local ok, v = pcall(peripheral.call, yn, "getAngle"); if ok then y = v end end
      if pn then local ok, v = pcall(peripheral.call, pn, "getAngle"); if ok then p = v end end
      return y, p
    end,
    fire = function(on)
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

-- World point the shell actually leaves from: the mount, offset by barrel
-- length along the barrel facing (NOT the pivot). Uses Minecraft's yaw
-- convention: 0=+Z (south), 90=-X (west), so forward = (-sin, +cos) in (x,z).
local function muzzlePos(mount, barrel, yawDeg, pitchDeg)
  local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
  local dx = -math.sin(yaw) * math.cos(pitch)
  local dz =  math.cos(yaw) * math.cos(pitch)
  local dy =  math.sin(pitch)
  return { x = mount.x + dx * barrel, y = mount.y + dy * barrel, z = mount.z + dz * barrel }
end

-- Height a shell reaches once it has travelled `dist` blocks horizontally, or
-- nil if it never gets there (falls short / stalls in the air first).
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

-- Scan the cannon's usable pitch range, refining every sign change of
-- (height - dh) by bisection. Returns viable pitches ascending, typically
-- {shallow, steep}, or {} if the target is out of range at this speed.
local function solvePitches(speed, dist, dh)
  local sols, prevErr, prevDeg = {}, nil, nil
  local lo, hi = cfg.pitchMin, cfg.pitchMax
  for deg = lo, hi, 1 do
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

-- Solve yaw + pitch options to hit `target` from `mount`. Iterates a few times
-- because the muzzle point itself depends on the yaw/pitch being solved for.
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
-- Cannon mount position: gps + stored offset (works when moving); if GPS is
-- unavailable, fall back to the static mount coords captured in setup.
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
-- Setup wizard
-- ===========================================================================
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

  print("\n-- Ballistics constants (press Enter to keep CBC defaults) --")
  c.gravity = askNum("  Gravity blocks/tick^2 (default 0.05): ", c.gravity or GRAV_DEFAULT)
  c.drag    = askNum("  Drag fraction/tick (default 0.01): ", c.drag or DRAG_DEFAULT)

  print("\n-- Calibration offsets (leave 0; adjust only if shots aim off) --")
  c.yawOffset   = askNum("  Yaw offset deg (default 0): ", c.yawOffset or 0)
  c.pitchOffset = askNum("  Pitch offset deg (default 0): ", c.pitchOffset or 0)
  c.settleTol   = c.settleTol or 1.5
  c.settleTimeout = c.settleTimeout or 8
  c.firePulse   = c.firePulse or 0.5
  c.prefArc     = c.prefArc or "low"

  saveCfg(c)
  print("\nSaved gunner.cfg.")
  return c
end

-- ===========================================================================
-- Aim & fire
-- ===========================================================================
local backend

local function pickPitch(sols)
  local inRange = {}
  for _, p in ipairs(sols) do
    if p >= cfg.pitchMin - 0.01 and p <= cfg.pitchMax + 0.01 then inRange[#inRange + 1] = p end
  end
  if #inRange == 0 then return nil, sols end
  if cfg.prefArc == "high" then return inRange[#inRange], inRange end
  return inRange[1], inRange
end

-- Wait until the cannon settles on the commanded angles, or timeout. If the
-- backend gives no angle telemetry, wait out a fixed estimate instead.
local function waitSettle(tyaw, tpitch)
  local deadline = os.clock() + cfg.settleTimeout
  while os.clock() < deadline do
    local y, p = backend.readAngles()
    if y and p then
      local dy = math.abs(((y - tyaw + 540) % 360) - 180)
      local dp = math.abs(p - tpitch)
      if dy <= cfg.settleTol and dp <= cfg.settleTol then return true end
    else
      sleep(cfg.settleTimeout); return false
    end
    sleep(0.2)
  end
  return false
end

-- Automatic fire with a short abort window so a bad solution can be stopped.
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
  if not backend then print("No cannon peripheral wired — run: gunner wiring"); return end
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
  if waitSettle(aimYaw, aimPitch) then print("On target.") else print("Aim not fully settled (timeout) — proceeding.") end

  if confirmFire(3) then
    backend.fire(true); sleep(cfg.firePulse); backend.fire(false)
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
  print("1. COMPUTER (Advanced or normal) with a WIRED MODEM on one side,")
  print("   connected by networking cable to the cannon's control peripheral.")
  print("")
  print("2. CANNON control — either route works, gunner auto-detects:")
  print("   a) CC:CBC 'Cannon Mount' peripheral on the Create: Big Cannons")
  print("      cannon mount (preferred). gunner calls setComputerControl(true)")
  print("      so the mount takes computer aim instead of a control shaft.")
  print("   b) Create: Radars Auto Pitch Controller + Auto Yaw Controller +")
  print("      Fire Controller, one each, all on the wired network.")
  print("")
  print("3. GPS: at least one CC GPS host cluster in range so gps.locate()")
  print("   returns this computer's coords. (Or enter coords manually in setup.)")
  print("")
  print("4. RADAR (optional): a Create: Radars peripheral exposing getTracks()")
  print("   on the same wired network, to pick live targets with 'radar'.")
  print("")
  print("5. The cannon must be ASSEMBLED and LOADED (propellant + shell). Use")
  print("   'assemble' if using a CC:CBC mount; charges are set in setup.")
  print("")
  print("Setup once with:  gunner setup   (F3 gives the mount & computer coords)")
end

-- ===========================================================================
-- Main
-- ===========================================================================
if cmd == "wiring" then wiring(); return end

cfg = loadCfg()
if cmd == "setup" or not cfg then cfg = setup(cfg) end
-- Backfill any missing constants so an older cfg still runs.
cfg.gravity = cfg.gravity or GRAV_DEFAULT
cfg.drag = cfg.drag or DRAG_DEFAULT
cfg.velPerCharge = cfg.velPerCharge or VPC_DEFAULT
cfg.muzzleSpeed = cfg.muzzleSpeed or (cfg.charges or 1) * cfg.velPerCharge
cfg.pitchMin = cfg.pitchMin or 0
cfg.pitchMax = cfg.pitchMax or 60
cfg.yawOffset = cfg.yawOffset or 0
cfg.pitchOffset = cfg.pitchOffset or 0
cfg.settleTol = cfg.settleTol or 1.5
cfg.settleTimeout = cfg.settleTimeout or 8
cfg.firePulse = cfg.firePulse or 0.5
cfg.prefArc = cfg.prefArc or "low"

backend = findBackend()
print("")
print("=== GUNNER — Create: Big Cannons targeting ===")
if backend then print("Cannon backend: " .. backend.kind .. " (" .. tostring(backend.name) .. ")")
else print("WARNING: no cannon peripheral found. Run 'gunner wiring'. (Math still works.)") end
print(("Mount = gps + offset (%d,%d,%d) | %d charges -> %.1f b/t | pitch %d..%d")
  :format(cfg.offX or 0, cfg.offY or 0, cfg.offZ or 0, cfg.charges or 0,
          cfg.muzzleSpeed, cfg.pitchMin, cfg.pitchMax))
print("Commands: aim | radar | arc | angles | fire | hold | assemble | disassemble | info | setup | wiring | quit")

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
    if backend then backend.fire(true); sleep(cfg.firePulse); backend.fire(false); print("FIRED.")
    else print("No cannon peripheral.") end

  elseif c == "hold" then
    if backend then backend.fire(false); print("Fire signal off.") end

  elseif c == "assemble" then
    if backend then local ok = backend.assemble(true); print(ok and "Assembled." or "Assemble not supported by this backend.") end

  elseif c == "disassemble" then
    if backend then backend.assemble(false); print("Disassembled.") end

  elseif c == "info" then
    local m, live = currentMount()
    if m then print(("Mount %d %d %d (%s)"):format(math.floor(m.x + .5), math.floor(m.y + .5),
      math.floor(m.z + .5), live and "live GPS" or "static")) end
    if backend then
      local y, p = backend.readAngles()
      print(("Cannon angles: yaw %s pitch %s"):format(y and ("%.1f"):format(y) or "?", p and ("%.1f"):format(p) or "?"))
      local i = backend.info(); if i then print("getInfo: " .. textutils.serialise(i)) end
    end

  elseif c == "setup" then
    cfg = setup(cfg); backend = findBackend()

  elseif c == "wiring" then
    wiring()

  elseif c == "quit" or c == "exit" then
    if backend then backend.fire(false) end
    print("Bye."); return

  elseif c == "" then
    -- ignore

  else
    print("Unknown command. Try: aim / radar / arc / angles / fire / assemble / info / setup / wiring / quit")
  end
end
