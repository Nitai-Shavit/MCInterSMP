-- gunner.lua  (CC:Tweaked) — standalone single-cannon operator console for
-- Create: Big Cannons. Aim at a world coordinate and fire, all from ONE
-- computer. Self-contained: no rednet, no second computer.
--
--   * gps.locate() every shot -> works on a moving contraption. The cannon
--     MOUNT is  gps + offset  where offset = MOUNT - COMPUTER is captured once
--     in setup (read off F3). Falls back to static mount coords if no GPS.
--   * brute-force ballistics (gravity + drag, no closed form for CBC shells)
--     solves pitch; yaw is solved in the Create: Radars controller's own frame.
--   * commands the cannon, waits for it to slew, then fires.
--
-- AIMING backend (auto-detected):
--   * Create: Radars Auto Pitch + Auto Yaw Controllers (setAngle/stopAuto).
--     setAngle only sets a TARGET and the mod's auto-aim (WFC) overrides it
--     unless stopAuto() is called first — so we stopAuto() before every aim.
--     Yaw uses the mod's frame:  atan2(dz,dx)+90  (verified from mod source).
--   * or CC:CBC "cannon_mount" (setComputerControl/setTargetAngles/fire).
--
-- FIRING (separate from aiming):
--   * REDSTONE pulse from a chosen computer side (default) — for a cannon fired
--     through a redstone relay / igniter. No Fire Controller needed.
--   * or a Create: Radars Fire Controller peripheral (set fireMode in cfg).
--
-- Setup asks only the cannon-specific facts; everything else defaults to CBC
-- values and lives in gunner.cfg (edit it directly to change a default).
--   gunner wiring   hookup guide       gunner setup   re-run setup

local RAW     = "https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/gunner.lua"
local CFGFILE = "gunner.cfg"
local SIDES   = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local atan2   = math.atan2 or function(y, x) return math.atan(y, x) end

-- CBC ballistics defaults (edit gunner.cfg to change per cannon):
--   gravity 0.05 b/t, drag 1%/t, muzzle speed = charges * 2 b/t (community
--   CBC ballistic-calculator values). Elevation defaults let the barrel
--   depress to -30 and elevate to 60.
local DEFAULTS = {
  velPerCharge = 2.0, gravity = 0.05, drag = 0.01,
  pitchMin = -30, pitchMax = 60,
  yawOffset = 0, pitchOffset = 0, prefArc = "low",
  fireMode = "redstone", fireSide = "back", firePulse = 0.5, slewSeconds = 4,
}

-- ===========================================================================
-- Self-update: pull the latest gunner.lua, relaunch if it changed.
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
  if not ok or not fs.exists(tmp) then if fs.exists(tmp) then fs.delete(tmp) end return false end
  local new, cur = readFile(tmp), readFile("gunner.lua")
  fs.delete(tmp)
  if new and #new > 0 and new ~= cur then
    local f = fs.open("gunner.lua", "w"); f.write(new); f.close(); return true
  end
  return false
end
if args[1] ~= "noupdate" then
  print("Checking for a newer gunner.lua ...")
  if selfUpdate() then
    print("Updated. Relaunching...")
    local pass = { "noupdate" }; for i = 1, #args do pass[#pass + 1] = args[i] end
    shell.run("gunner.lua", table.unpack(pass)); return
  end
end
if args[1] == "noupdate" then table.remove(args, 1) end
local cmd = args[1]

-- ===========================================================================
-- Config
-- ===========================================================================
local cfg   -- module-wide; ballistics + backend detection read from it.

local function loadCfg()
  local d = readFile(CFGFILE); if not d then return nil end
  return textutils.unserialise(d)
end
local function saveCfg() local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(cfg)); f.close() end
local function applyDefaults(c)
  for k, v in pairs(DEFAULTS) do if c[k] == nil then c[k] = v end end
  c.velPerCharge = c.velPerCharge or DEFAULTS.velPerCharge
  c.muzzleSpeed = (c.charges or 1) * c.velPerCharge
  return c
end

local function ask(prompt, default)
  if default ~= nil then write(prompt .. "[" .. tostring(default) .. "] ") else write(prompt) end
  local s = read(); if s == "" then return default end; return s
end
local function askNum(prompt, default) return tonumber(ask(prompt, default)) or default end
local function fmt(n) return n and tostring(math.floor(n + 0.5)) or "?" end

-- ===========================================================================
-- Peripheral discovery + aiming backend
-- ===========================================================================
local function hasM(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do if x == m then return true end end
  return false
end

-- Find all Auto Pitch/Yaw Controllers (setAngle+stopAuto) and a Fire Controller.
local function detectControllers()
  local ctrls, fn = {}, nil
  for _, name in ipairs(peripheral.getNames()) do
    if hasM(name, "setAngle") and hasM(name, "stopAuto") then
      ctrls[#ctrls + 1] = name
    elseif hasM(name, "fireOn") or (hasM(name, "setPowered") and hasM(name, "isPowered")) then
      fn = name
    end
  end
  -- classify by type-name substring; fall back to discovery order.
  local pn, yn
  for _, name in ipairs(ctrls) do
    local ty = (peripheral.getType(name) or ""):lower()
    if ty:find("yaw") and not yn then yn = name
    elseif ty:find("pitch") and not pn then pn = name end
  end
  for _, name in ipairs(ctrls) do
    if name ~= pn and name ~= yn then
      if not pn then pn = name elseif not yn then yn = name end
    end
  end
  return pn, yn, fn
end

-- CC:CBC cannon_mount (alternative to the radar controllers).
local function makeCbcBackend(name)
  local p = peripheral.wrap(name)
  return {
    kind = "cbc", pitchName = nil, yawName = nil, fireName = nil, realAngles = true,
    commission = function() pcall(function() p.setComputerControl(true) end) end,
    aim = function(yaw, pitch)
      pcall(function() p.setComputerControl(true) end)
      if not pcall(function() p.setTargetAngles(yaw, pitch) end) then
        pcall(function() p.setTargetYaw(yaw) end); pcall(function() p.setTargetPitch(pitch) end)
      end
    end,
    readAngles = function()
      local ok, i = pcall(function() return p.getInfo() end)
      if ok and type(i) == "table" then
        return i.yaw or i.currentYaw or i.cannonYaw, i.pitch or i.currentPitch or i.cannonPitch
      end
    end,
    hasFirePeripheral = true,
    firePeripheral = function(on) pcall(function() p.fire(on) end) end,
    assemble = function(on) return pcall(function() p.assemble(on) end) end,
    info = function() local ok, i = pcall(function() return p.getInfo() end); if ok then return i end end,
  }
end

-- Create: Radars controllers. setAngle sets a target; stopAuto() first stops
-- the mod's auto-aim from overriding it (this is what makes yaw move). getAngle
-- returns the target we set, not the live barrel angle -> no true telemetry.
local function makeRadarBackend(pn, yn, fn)
  local function commission()
    if pn then pcall(peripheral.call, pn, "stopAuto") end
    if yn then pcall(peripheral.call, yn, "stopAuto") end
  end
  return {
    kind = "radar", pitchName = pn, yawName = yn, fireName = fn, realAngles = false,
    commission = commission,
    aim = function(yaw, pitch)
      commission()
      if yn then pcall(peripheral.call, yn, "setAngle", yaw) end
      if pn then pcall(peripheral.call, pn, "setAngle", pitch) end
    end,
    readAngles = function() return nil, nil end,
    targetAngles = function()
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
  -- CC:CBC cannon_mount takes priority if present.
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "cannon_mount" or hasM(name, "setTargetAngles") then
      return makeCbcBackend(name)
    end
  end
  local pn, yn, fn = detectControllers()
  -- explicit assignment from setup wins over auto-detect.
  if cfg and cfg.pitchPeri and peripheral.isPresent(cfg.pitchPeri) then pn = cfg.pitchPeri end
  if cfg and cfg.yawPeri  and peripheral.isPresent(cfg.yawPeri)  then yn = cfg.yawPeri end
  if pn or yn then return makeRadarBackend(pn, yn, fn) end
  return nil
end

local function findRadar()
  for _, name in ipairs(peripheral.getNames()) do
    if hasM(name, "getTracks") then return name end
  end
end

-- ===========================================================================
-- Ballistics — brute-force trajectory search (mirrors master.lua).
-- ===========================================================================
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

-- Returns (commandYaw, pitchSolutions). commandYaw is in the Create: Radars
-- controller frame: atan2(dz,dx)+90. The muzzle offset is computed directly
-- from the horizontal unit vector, so it's independent of that frame.
local function solveAim(mount, target)
  local dx0, dz0 = target.x - mount.x, target.z - mount.z
  local horiz = math.sqrt(dx0 * dx0 + dz0 * dz0)
  local ux, uz = 1, 0
  if horiz > 1e-6 then ux, uz = dx0 / horiz, dz0 / horiz end
  local sols, pitch = {}, 20
  for _ = 1, 4 do
    local cp, sp = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
    local mx = mount.x + cfg.barrel * ux * cp
    local mz = mount.z + cfg.barrel * uz * cp
    local my = mount.y + cfg.barrel * sp
    local ddx, ddz = target.x - mx, target.z - mz
    local dist = math.sqrt(ddx * ddx + ddz * ddz)
    sols = solvePitches(cfg.muzzleSpeed, dist, target.y - my)
    if #sols == 0 then break end
    pitch = sols[1]
  end
  local yaw = (math.deg(atan2(dz0, dx0)) + 90 + cfg.yawOffset) % 360
  if yaw < 0 then yaw = yaw + 360 end
  return yaw, sols
end

-- ===========================================================================
-- Position
-- ===========================================================================
local function currentMount()
  local cx, cy, cz = gps.locate(2)
  if cx then return { x = cx + cfg.offX, y = cy + cfg.offY, z = cz + cfg.offZ }, true end
  if cfg.mountX then return { x = cfg.mountX, y = cfg.mountY, z = cfg.mountZ }, false end
  return nil, false
end

-- ===========================================================================
-- Firing (redstone by default; Fire Controller peripheral if fireMode set)
-- ===========================================================================
local backend
local function fireSet(on)
  if cfg.fireMode == "peripheral" and backend and backend.hasFirePeripheral then
    backend.firePeripheral(on)
  else
    pcall(function() redstone.setOutput(cfg.fireSide or "back", on) end)
  end
end
local function firePulse() fireSet(true); sleep(cfg.firePulse or 0.5); fireSet(false) end

-- ===========================================================================
-- Setup — only the cannon-specific facts. Everything else defaults.
-- ===========================================================================
local function setup(existing)
  local c = existing or {}
  print("=== Gunner setup ===")

  print("\nLocating computer via GPS...")
  local cx, cy, cz = gps.locate(3)
  if cx then print(("  Computer at %d %d %d"):format(cx, cy, cz))
  else
    print("  No GPS — enter the COMPUTER's own coords (F3):")
    cx = askNum("    Computer X: ", 0); cy = askNum("    Computer Y: ", 0); cz = askNum("    Computer Z: ", 0)
  end

  print("\nCannon MOUNT (pivot) block coords, off F3 (the pivot, NOT the muzzle):")
  local mx = askNum("  Mount X: ", c.mountX)
  local my = askNum("  Mount Y: ", c.mountY)
  local mz = askNum("  Mount Z: ", c.mountZ)
  c.mountX, c.mountY, c.mountZ = mx, my, mz
  c.offX, c.offY, c.offZ = mx - cx, my - cy, mz - cz
  print(("  offset MOUNT-COMPUTER = %d %d %d"):format(c.offX, c.offY, c.offZ))

  c.barrel  = askNum("\n  Barrel length in blocks (mount to muzzle exit): ", c.barrel or 0)
  c.charges = askNum("  Propellant charges loaded: ", c.charges or 1)

  print("\nFiring: this computer pulses a redstone side into your relay/igniter.")
  local s = ask("  Which side outputs firing redstone? ", c.fireSide or "back"):lower()
  c.fireSide = SIDES[s] and s or "back"
  c.fireMode = "redstone"

  applyDefaults(c)

  -- Record which controllers are the pitch/yaw axes so aiming can't miss one.
  local pn, yn, fn = detectControllers()
  c.pitchPeri, c.yawPeri = pn, yn
  cfg = c; saveCfg()
  print("\nSaved gunner.cfg.")
  print(("  pitch controller: %s"):format(pn or "NOT FOUND"))
  print(("  yaw controller:   %s"):format(yn or "NOT FOUND"))
  if fn then print("  fire controller:  " .. fn .. " (using redstone anyway; set fireMode='peripheral' in cfg to use it)") end
  if not pn or not yn then
    print("  ! A controller is missing. Check the wired-modem link to that axis,")
    print("    then re-run: gunner setup")
  end
  print("Defaults: pitch " .. c.pitchMin .. ".." .. c.pitchMax ..
        ", muzzle " .. c.velPerCharge .. " b/t/charge, slew " .. c.slewSeconds .. "s (edit gunner.cfg).")
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
  sleep(wait); return false
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
  if not backend then print("No cannon aiming peripheral — run: gunner wiring"); return end
  local mount, live = currentMount()
  if not mount then print("No GPS fix and no saved mount — run: gunner setup"); return end
  if not live then print("(GPS unavailable — using static mount from setup)") end

  local yaw, sols = solveAim(mount, { x = tx, y = ty, z = tz })
  local pitch, inRange = pickPitch(sols)
  local dx, dz = tx - mount.x, tz - mount.z
  print(("\nTarget %d %d %d | dist %d | dY %d"):format(tx, ty, tz,
    math.floor(math.sqrt(dx * dx + dz * dz) + .5), ty - mount.y))

  if #sols == 0 then print("OUT OF RANGE (add charges / move closer)."); return end
  if not pitch then
    local s = {}; for _, p in ipairs(sols) do s[#s + 1] = ("%.1f"):format(p) end
    print(("Solution pitch %s outside limits %d..%d (edit pitchMin/pitchMax in gunner.cfg).")
      :format(table.concat(s, "/"), cfg.pitchMin, cfg.pitchMax))
    return
  end

  local arcs = {}; for _, p in ipairs(inRange) do arcs[#arcs + 1] = ("%.1f"):format(p) end
  print(("Solution: yaw %.1f, pitch %.1f  (%s arc: %s)"):format(yaw, pitch, cfg.prefArc, table.concat(arcs, "/")))

  backend.aim(yaw, pitch + cfg.pitchOffset)
  print("Slewing...")
  slewWait(yaw, pitch + cfg.pitchOffset)
  if confirmFire(3) then firePulse(); print("FIRED.") end
end

-- ===========================================================================
-- Radar target picker (optional)
-- ===========================================================================
local function radarPick()
  local r = findRadar()
  if not r then print("No radar (getTracks) peripheral."); return end
  local ok, tracks = pcall(peripheral.call, r, "getTracks")
  if not ok or type(tracks) ~= "table" or #tracks == 0 then print("No radar tracks."); return end
  for i, t in ipairs(tracks) do
    local p = t.position or {}
    print(("  %d) %-10s @ %s %s %s"):format(i, tostring(t.entityType or t.category or "?"), fmt(p.x), fmt(p.y), fmt(p.z)))
  end
  local i = askNum("Pick # (blank cancels): ", nil)
  local t = i and tracks[i]
  if t and t.position then engage(t.position.x, t.position.y, t.position.z) else print("Cancelled.") end
end

-- ===========================================================================
-- Wiring guide
-- ===========================================================================
local function wiring()
  print("=== Gunner — hookup ===\n")
  print("1. COMPUTER + WIRED MODEM, cabled to the cannon's Auto Pitch Controller")
  print("   and Auto Yaw Controller (right-click each with a modem).")
  print("2. Those controllers Data-Linked to the cannon mount as usual. gunner")
  print("   stopAuto()s them so the mod's auto-aim stops fighting the computer")
  print("   (that is what makes YAW move), then setAngle()s each axis.")
  print("   The mount still needs rotational (kinetic) power to physically turn.")
  print("3. FIRING: a redstone line from ONE computer side to the cannon firing")
  print("   (through your redstone relay/igniter). Pick the side in setup.")
  print("4. GPS host cluster in range (or type coords in setup).")
  print("5. Optional: a Create: Radars getTracks() peripheral for the 'radar' cmd.")
  print("\nThen: gunner setup")
end

-- ===========================================================================
-- Main
-- ===========================================================================
if cmd == "wiring" then wiring(); return end

cfg = loadCfg()
if cmd == "setup" or not cfg then cfg = setup(cfg) end
applyDefaults(cfg)

backend = findBackend()
fireSet(false)  -- firing line starts LOW (safety)

print("\n=== GUNNER — Create: Big Cannons ===")
if backend then
  print("Aiming: " .. backend.kind)
  if backend.kind == "radar" then
    print("  pitch: " .. tostring(backend.pitchName or "NOT FOUND") ..
          "   yaw: " .. tostring(backend.yawName or "NOT FOUND"))
    if not backend.pitchName or not backend.yawName then
      print("  ! Missing a controller — check its wired-modem link, or 'setup'.")
    end
  end
else
  print("WARNING: no cannon peripheral. Run 'gunner wiring'.")
end
print(("Firing: %s%s | mount gps+(%d,%d,%d) | %d charges -> %.0f b/t | pitch %d..%d")
  :format(cfg.fireMode, cfg.fireMode == "redstone" and (" on " .. cfg.fireSide) or "",
          cfg.offX or 0, cfg.offY or 0, cfg.offZ or 0, cfg.charges or 0,
          cfg.muzzleSpeed, cfg.pitchMin, cfg.pitchMax))
print("Cmds: aim | radar | test yaw|pitch <deg> | swap | angles | fire | info | setup | wiring | quit")

while true do
  write("\ngunner> ")
  local w = {}
  for tok in read():gmatch("%S+") do w[#w + 1] = tok end
  local c = (w[1] or ""):lower()

  if c == "aim" then
    local tx = tonumber(w[2]) or askNum("X: ", nil)
    local ty = tonumber(w[3]) or askNum("Y: ", nil)
    local tz = tonumber(w[4]) or askNum("Z: ", nil)
    if tx and ty and tz then engage(tx, ty, tz) else print("Need X Y Z.") end

  elseif c == "radar" then radarPick()

  elseif c == "test" then
    -- Prove a single axis physically moves (takes it off auto-aim first).
    if not backend then print("No cannon peripheral.")
    else
      local axis, a = (w[2] or ""):lower(), tonumber(w[3])
      backend.commission()
      if axis == "yaw" and a and backend.yawName then
        pcall(peripheral.call, backend.yawName, "setAngle", a)
        print(("YAW -> %.1f. Watch the cannon; it should rotate."):format(a))
      elseif axis == "pitch" and a and backend.pitchName then
        pcall(peripheral.call, backend.pitchName, "setAngle", a)
        print(("PITCH -> %.1f. Watch the cannon; it should tilt."):format(a))
      else print("Usage: test yaw <deg> | test pitch <deg>") end
    end

  elseif c == "swap" then
    -- Flip which detected controller is pitch vs yaw (if aiming the wrong axis).
    if backend and backend.pitchName and backend.yawName then
      cfg.pitchPeri, cfg.yawPeri = backend.yawName, backend.pitchName
      saveCfg(); backend = findBackend()
      print("Swapped. pitch=" .. tostring(backend.pitchName) .. " yaw=" .. tostring(backend.yawName))
    else print("Need two detected controllers to swap.") end

  elseif c == "angles" then
    if backend then
      local y = tonumber(w[2]) or askNum("Yaw: ", nil)
      local p = tonumber(w[3]) or askNum("Pitch: ", nil)
      if y and p then backend.aim(y, p); print(("Commanded yaw %.1f pitch %.1f"):format(y, p)) end
    else print("No cannon peripheral.") end

  elseif c == "fire" then firePulse(); print("FIRED.")
  elseif c == "hold" then fireSet(false); print("Fire off.")

  elseif c == "arc" then
    cfg.prefArc = (cfg.prefArc == "low") and "high" or "low"; saveCfg(); print("Arc: " .. cfg.prefArc)

  elseif c == "assemble" then if backend and backend.assemble then print(backend.assemble(true) and "Assembled." or "Not supported.") end
  elseif c == "disassemble" then if backend and backend.assemble then backend.assemble(false); print("Disassembled.") end

  elseif c == "info" then
    local m, live = currentMount()
    if m then print(("Mount %d %d %d (%s)"):format(fmt(m.x), fmt(m.y), fmt(m.z), live and "live GPS" or "static")) end
    if backend then
      local y, p
      if backend.targetAngles then y, p = backend.targetAngles() else y, p = backend.readAngles() end
      print(("Commanded: yaw %s pitch %s"):format(y and ("%.1f"):format(y) or "?", p and ("%.1f"):format(p) or "?"))
      local i = backend.info(); if i then print("getInfo: " .. textutils.serialise(i)) end
    end

  elseif c == "setup" then fireSet(false); cfg = setup(cfg); applyDefaults(cfg); backend = findBackend()
  elseif c == "wiring" then wiring()
  elseif c == "quit" or c == "exit" then fireSet(false); print("Bye."); return
  elseif c == "" then -- ignore
  else print("Cmds: aim | radar | test | swap | angles | fire | info | setup | wiring | quit") end
end
