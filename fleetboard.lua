-- fleetboard.lua  (CC:Tweaked) — runs on the master ship's (Lightning's) own
-- computer, wired to its monitor. Read-only armada viewer: distance,
-- compass direction (via its own gps.locate() vs each ship's reported
-- position — plain geometry, no ship-orientation API needed), and pitch/
-- roll (from each ship's Gimbal Sensor, color-coded green/yellow/red by
-- tilt severity) for every ship.lua node reporting in. No cannon control —
-- see CLAUDE.md Part 3.

local PROTO       = "shipnet"
local STALE       = 15     -- seconds before a ship's data is shown OFFLINE
local SCALE       = 0.5    -- small monitor -> smaller text, more rows/cols
local PAGE_PERIOD = 4       -- seconds between auto-advancing pages

local function wirelessModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then
      return n
    end
  end
end

local mon = peripheral.find("monitor"); assert(mon, "No monitor")
mon.setTextScale(SCALE)
local mside = wirelessModem()
assert(mside, "No wireless/ender modem found"); rednet.open(mside)

local ships = {}
local function ingest(msg) ships[msg.id] = { msg = msg, t = os.clock() } end

local function myPosition()
  local ok, x, y, z = pcall(gps.locate, 2)
  if ok and x then return { x = x, y = y, z = z } end
end

local function pad(s, w) s = tostring(s); w = math.max(w, 0); if #s > w then return s:sub(1,w) end return s..(" "):rep(w-#s) end
local function dist(a, b)
  if not a or not b then return nil end
  local dx, dy, dz = a.x-b.x, a.y-b.y, a.z-b.z
  return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Tilt severity: green under 5deg, yellow 5-15deg, red over 15deg.
local function tiltColor(angle)
  if not angle then return colors.gray end
  local a = math.abs(angle)
  if a < 5 then return colors.lime
  elseif a <= 15 then return colors.yellow
  else return colors.red end
end
local function fmtAngle(v) return v and ("%.1f"):format(v) or "?" end

-- Standard real-world compass bearing (0=N, 90=E, 180=S, 270=W) from `a` to
-- `b`, using Minecraft's world axes (north = -Z, east = +X). This is plain
-- geometry from the two GPS positions we already have -- no ship-orientation
-- API needed, unlike pitch/roll below.
local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function bearing(a, b)
  if not a or not b then return nil end
  local dx, dz = b.x - a.x, b.z - a.z
  if dx == 0 and dz == 0 then return nil end
  return (math.deg(math.atan2(dx, -dz)) + 360) % 360
end
local function compassLabel(deg)
  if not deg then return "?" end
  return COMPASS[math.floor((deg + 22.5) / 45) % 8 + 1]
end

-- One compact line per ship, auto-paginating on a timer if more ships don't
-- fit than the monitor has rows for — works on a plain, non-Advanced
-- monitor too, since paging is timer-driven, not touch-driven.
local page = 1

local function draw()
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  local here = myPosition()
  local now = os.clock()

  local ids = {}
  for id in pairs(ships) do ids[#ids+1] = id end
  table.sort(ids)

  local rows = math.max(H - 1, 1)
  local pages = math.max(math.ceil(#ids / rows), 1)
  if page > pages then page = 1 end
  local start = (page-1)*rows

  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan)
  mon.write(pad(pages > 1 and ("ARMADA %d/%d"):format(page, pages) or "ARMADA", W))

  if #ids == 0 then
    mon.setTextColor(colors.gray); mon.setCursorPos(1,2); mon.write("No ships reporting in yet.")
    return
  end

  -- Name column widens to fit the longest ship ID actually on screen (plus
  -- a guaranteed gap), instead of a fixed width that a long name could fill
  -- exactly and butt up against the next column with no gap at all.
  local maxId = 4
  for _, id in ipairs(ids) do maxId = math.max(maxId, #id) end
  local idW = math.min(maxId + 2, math.max(math.floor(W * 0.3), 6))

  local y = 2
  for i = start+1, math.min(start+rows, #ids) do
    local id = ids[i]
    local entry = ships[id]
    local m = entry.msg
    mon.setCursorPos(1,y)

    if (now - entry.t) > STALE then
      mon.setTextColor(colors.gray)
      mon.write(pad(pad(id, idW).." OFFLINE", W))
    else
      local d = dist(here, m.position)
      local brg = bearing(here, m.position)
      mon.setTextColor(colors.white);     mon.write(pad(id, idW))
      mon.setTextColor(colors.lightGray); mon.write(pad(d and (math.floor(d).."m") or "?m", 6))
      mon.setTextColor(colors.orange);    mon.write(pad(compassLabel(brg), 3))

      mon.setTextColor(colors.lightGray); mon.write(" Pitch:")
      mon.setTextColor(tiltColor(m.pitch)); mon.write(pad(fmtAngle(m.pitch), 6))
      mon.setTextColor(colors.lightGray); mon.write(" Roll:")
      mon.setTextColor(tiltColor(m.roll));  mon.write(pad(fmtAngle(m.roll), 6))
    end
    y = y + 1
  end
end

local redrawTimer = os.startTimer(0)
local pageTimer    = os.startTimer(PAGE_PERIOD)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "status" then
    ingest(b)
  elseif ev == "monitor_touch" then
    page = page + 1; draw()
  elseif ev == "timer" then
    if a == redrawTimer then draw(); redrawTimer = os.startTimer(2)
    elseif a == pageTimer then page = page + 1; draw(); pageTimer = os.startTimer(PAGE_PERIOD) end
  end
end
