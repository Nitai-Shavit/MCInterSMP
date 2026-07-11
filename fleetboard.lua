-- fleetboard.lua  (CC:Tweaked + CC:Sable) — runs on the MASTER ship's own
-- computer, wired to its monitor. Read-only fleet status board: distance,
-- cannon-ready state, and pitch/roll for every ship.lua node reporting in,
-- so you can see at a glance whether a ship is stable enough to safely fire
-- before you order a shot over binoculars. This never sends any command —
-- aiming and firing stay fully manual, separate from the master.lua /
-- cannon.lua / radar.lua auto-aim system built for stationary cannons.
--
-- Must run on a computer that is ITSELF on a Sub-Level (the master ship),
-- since it needs its own position via CC:Sable's `sublevel` API to compute
-- distance to each ship. Same verification note as ship.lua applies to
-- myPosition() below.
--
-- CONFIG ----------------------------------------------------------------
local PROTO       = "shipnet"
local STALE       = 8      -- seconds before a ship's data is shown OFFLINE
local SCALE       = 0.5    -- small monitor -> smaller text, more rows/cols
local SAFE_TILT   = 10     -- degrees; |pitch| or |roll| beyond this = unsafe to fire
local PAGE_PERIOD = 4      -- seconds between auto-advancing pages
-- -------------------------------------------------------------------------

local function myPosition()
  if not sublevel then return nil end
  local ok, pos = pcall(sublevel.getPosition)
  if ok and type(pos) == "table" then return pos end
end

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

local function pad(s, w) s = tostring(s); w = math.max(w, 0); if #s > w then return s:sub(1,w) end return s..(" "):rep(w-#s) end
local function dist(a, b)
  if not a or not b then return nil end
  local dx, dy, dz = a.x-b.x, a.y-b.y, a.z-b.z
  return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Smart-for-small-screens: one compact line per ship (id, distance, ready
-- indicator, pitch/roll), auto-paginating if more ships don't fit than the
-- monitor has rows for. Works on a plain (non-Advanced) monitor too, since
-- it relies on a timer to flip pages, not touch — touch just skips sooner
-- if you do have an Advanced monitor.
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
  mon.write(pad(pages > 1 and ("FLEET %d/%d"):format(page, pages) or "FLEET", W))

  if #ids == 0 then
    mon.setTextColor(colors.gray); mon.setCursorPos(1,2); mon.write("No ships reporting in yet.")
    return
  end

  local y = 2
  for i = start+1, math.min(start+rows, #ids) do
    local id = ids[i]
    local entry = ships[id]
    local m = entry.msg
    mon.setCursorPos(1,y)

    if (now - entry.t) > STALE then
      mon.setTextColor(colors.gray)
      mon.write(pad(pad(id, 4).." OFFLINE", W))
    else
      local d = dist(here, m.position)
      mon.setTextColor(colors.white);     mon.write(pad(id, 4))
      mon.setTextColor(colors.lightGray); mon.write(pad(d and (math.floor(d).."m") or "?m", 6))
      mon.setTextColor(m.loaded and colors.lime or colors.gray)
      mon.write(m.loaded and "RDY " or "--- ")

      local unsafe = (m.pitch and math.abs(m.pitch) > SAFE_TILT)
                  or (m.roll  and math.abs(m.roll)  > SAFE_TILT)
      mon.setTextColor(unsafe and colors.red or colors.lightGray)
      mon.write(("p%s r%s"):format(
        m.pitch and math.floor(m.pitch) or "?",
        m.roll  and math.floor(m.roll)  or "?"))
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
    if a == redrawTimer then
      draw(); redrawTimer = os.startTimer(2)
    elseif a == pageTimer then
      page = page + 1; draw(); pageTimer = os.startTimer(PAGE_PERIOD)
    end
  end
end
