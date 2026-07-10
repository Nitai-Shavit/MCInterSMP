-- radar.lua  (CC:Tweaked) — run on a computer WIRED to Create: Radars
-- peripherals (Radar Bearing / Plane Radar / Monitor — anything exposing
-- getTracks()). Broadcasts detected tracks over rednet for master.lua.
-- No setup wizard needed: every getTracks()-capable peripheral on the wired
-- network is used automatically.

local PROTO, REFRESH = "cbcnet", 2

local function hasM(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do if x == m then return true end end
  return false
end

-- Radar Bearing, Plane Radar, and Monitor all expose getTracks() with the
-- same track-table shape, so we don't need to tell them apart.
local function radarPeripherals()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    if hasM(name, "getTracks") then list[#list+1] = name end
  end
  return list
end

-- Pick the WIRELESS/ender modem for rednet (a wired modem is also type "modem").
local function wirelessModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then
      return n
    end
  end
end

local mside = wirelessModem()
assert(mside, "No wireless/ender modem found for rednet")
rednet.open(mside)
local myId = os.getComputerID()

local radars = radarPeripherals()
assert(#radars > 0, "No radar peripheral (Radar Bearing / Plane Radar / Monitor) found")
print(("Radar node %d running with %d radar peripheral(s). Ctrl+T to stop."):format(myId, #radars))

local function broadcast()
  for _, name in ipairs(radars) do
    local ok, tracks = pcall(peripheral.call, name, "getTracks")
    if ok and type(tracks) == "table" then
      local pos
      local okp, p = pcall(peripheral.call, name, "getPosition")
      if okp and type(p) == "table" then pos = p end
      rednet.broadcast({ type="tracks", from=myId, radar=name, position=pos, tracks=tracks }, PROTO)
    end
  end
end

local timer = os.startTimer(0)
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == timer then
    broadcast(); timer = os.startTimer(REFRESH)
  end
end
