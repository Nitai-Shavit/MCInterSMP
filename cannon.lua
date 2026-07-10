-- cannon.lua  (CC:Tweaked) — run one per cluster of Create: Big Cannons.
-- First launch runs setup; re-run setup anytime with: cannon setup
-- Wired to each cannon's Auto Pitch Controller, Auto Yaw Controller, and Fire
-- Controller (all from Create: Radars' CC:Tweaked compat). Broadcasts cannon
-- status over rednet and executes aim/fire commands from master.lua.
--
-- IMPORTANT: this node never calls stopAuto() on its own initiative. A cannon
-- stays under the radar mod's own auto-aim network until master.lua sends an
-- explicit {type="commission"} message (gated by a one-time typed "YES" on
-- master's own terminal — see master.lua). stopAuto() hands control to the
-- computer permanently; undoing it requires physically re-linking in-game.

local PROTO, CFGFILE, REFRESH = "cbcnet", "cannon.cfg", 2
-- Muzzle speed: measured 40 m/s per propellant charge (linear, per in-game
-- testing) -> convert to blocks/tick for the trajectory math in master.lua.
local MPS_PER_CHARGE, TICKS_PER_SEC = 40, 20

local function hasM(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do if x == m then return true end end
  return false
end
-- Pitch and yaw controllers share an IDENTICAL method set (setAngle/getAngle/
-- stopAuto), so method detection alone can't tell them apart — only
-- peripheral.getType() can, and we fall back to asking if that's unclear.
local function kindOf(name)
  if hasM(name, "setAngle") and hasM(name, "getAngle") and hasM(name, "stopAuto") then
    local ty = (peripheral.getType(name) or ""):lower()
    if ty:find("yaw") then return "yaw"
    elseif ty:find("pitch") then return "pitch"
    else return "angle" end  -- ambiguous, setup() will ask
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

-- Setup wizard: group each detected pitch/yaw/fire controller under a Cannon
-- ID (leave blank to reuse the last ID, same convenience as collector.lua's
-- Group prompt — a cannon's three controllers are usually placed together).
-- Then, per cannon, collect the data no peripheral reports: mount position
-- (read off the F3 debug screen), barrel length in blocks (mount to muzzle
-- — the offset the shell actually leaves from), and propellant charges
-- loaded (used to derive muzzle speed).
local function setup()
  print("=== Cannon Node setup ===")
  local cfg = { cannons = {} }
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
    print(("\n-- Ballistics for cannon \"%s\" (read mount coords off F3) --"):format(id))
    write("  Mount X: "); cn.x = tonumber(read()) or 0
    write("  Mount Y: "); cn.y = tonumber(read()) or 0
    write("  Mount Z: "); cn.z = tonumber(read()) or 0
    write("  Barrel length in blocks (mount to muzzle exit): "); cn.barrel = tonumber(read()) or 0
    write("  Propellant charges loaded: "); cn.charges = tonumber(read()) or 1
    cn.muzzleSpeed = cn.charges * MPS_PER_CHARGE / TICKS_PER_SEC  -- blocks/tick
    cn.commissioned = false
  end

  saveCfg(cfg)
  print(("\nSaved %d cannon(s)."):format(countCannons(cfg)))
  return cfg
end

-- Pick the WIRELESS/ender modem for rednet (a wired modem is also type "modem").
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
local myId = os.getComputerID()
print(("Cannon node %d running with %d cannon(s). Ctrl+T to stop."):format(myId, countCannons(cfg)))

local function broadcast()
  local list = {}
  for id, cn in pairs(cfg.cannons) do
    local entry = { id=id, commissioned=cn.commissioned,
                     x=cn.x, y=cn.y, z=cn.z, barrel=cn.barrel, muzzleSpeed=cn.muzzleSpeed }
    if cn.pitch and peripheral.isPresent(cn.pitch) then
      local ok, v = pcall(peripheral.call, cn.pitch, "getAngle"); if ok then entry.pitch = v end
    end
    if cn.yaw and peripheral.isPresent(cn.yaw) then
      local ok, v = pcall(peripheral.call, cn.yaw, "getAngle"); if ok then entry.yaw = v end
    end
    if cn.fire and peripheral.isPresent(cn.fire) then
      local ok, v = pcall(peripheral.call, cn.fire, "isPowered"); if ok then entry.armed = v end
    end
    list[#list+1] = entry
  end
  rednet.broadcast({ type="status", node=myId, cannons=list }, PROTO)
end

local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == timer then
    broadcast(); timer = os.startTimer(REFRESH)
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table" then
    local cn = cfg.cannons[b.cannon]
    if cn then
      if b.type == "commission" then
        if cn.pitch then pcall(peripheral.call, cn.pitch, "stopAuto") end
        if cn.yaw then pcall(peripheral.call, cn.yaw, "stopAuto") end
        cn.commissioned = true
        saveCfg(cfg)
        print(("Cannon \"%s\" commissioned: computer control engaged."):format(b.cannon))
      elseif b.type == "aim" and cn.commissioned then
        if cn.yaw then pcall(peripheral.call, cn.yaw, "setAngle", b.yaw) end
        if cn.pitch then pcall(peripheral.call, cn.pitch, "setAngle", b.pitch) end
      elseif b.type == "fire" and cn.commissioned then
        if cn.fire then pcall(peripheral.call, cn.fire, "setPowered", b.on) end
      end
    end
  end
end
