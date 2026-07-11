-- playerradar.lua  (CC:Tweaked) — runs on a computer wired to an ADVANCED
-- monitor with HTTP access. Polls BlueMap's live player API and plots
-- player positions as a top-down radar. No modem or op access needed —
-- only outbound HTTP to the BlueMap web server. Unrelated to radar.lua
-- (Create: Radars cannon-targeting radar, Part 2) despite the similar name.
--
-- Prereq: BlueMap's host:port must be allowed in the server's CC:Tweaked
-- http.rules allowlist (computercraft-server.toml) and BlueMap's live
-- player markers must be enabled. That's server-admin config, same as
-- raw.githubusercontent.com for wget — not an in-game op action.
--
-- First launch runs setup; re-run anytime with: playerradar setup
-- ---------------------------------------------------------------------------

local CFGFILE = "playerradar.cfg"
local TITLE   = "PLAYER RADAR"
local SCALE   = 0.5      -- monitor font: smaller = finer radar grid.
local SELDUR  = 6        -- seconds a touched player's info stays on screen.

local function loadCfg()
  if not fs.exists(CFGFILE) then return nil end
  local f = fs.open(CFGFILE, "r"); local d = f.readAll(); f.close()
  return textutils.unserialise(d)
end
local function saveCfg(c)
  local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(c)); f.close()
end

local function parseSet(s)
  local set = {}
  for name in s:gmatch("[^,]+") do
    name = name:match("^%s*(.-)%s*$")
    if name ~= "" then set[name] = true end
  end
  return set
end

-- Setup wizard: BlueMap connection + radar view window + ally/enemy roster.
-- Roster only affects dot color for now — everyone BlueMap reports is
-- plotted regardless of classification (see CLAUDE.md).
local function setup()
  print("=== Player Radar setup ===")
  local cfg = {}
  write("BlueMap URL (e.g. http://192.168.1.50:8100): "); cfg.url = read()
  write("Map id (e.g. world): "); cfg.map = read()
  write("Poll interval seconds [5]: ")
  cfg.refresh = tonumber(read()) or 5
  write("Radar center X: "); cfg.originX = tonumber(read()) or 0
  write("Radar center Z: "); cfg.originZ = tonumber(read()) or 0
  write("View radius in blocks [500]: ")
  local r = tonumber(read()); cfg.range = (r and r > 0 and r) or 500
  write("Allies, comma-separated (blank = none): "); cfg.allies = parseSet(read())
  write("Enemies, comma-separated (blank = none): "); cfg.enemies = parseSet(read())
  saveCfg(cfg)
  print("\nSaved playerradar.cfg.")
  return cfg
end

local arg = ...
local cfg = loadCfg()
if arg == "setup" or not cfg then cfg = setup() end

local mon = peripheral.find("monitor"); assert(mon, "No monitor")
mon.setTextScale(SCALE)

local function classify(name)
  if cfg.enemies[name] then return "enemy" end
  if cfg.allies[name] then return "ally" end
  return "neutral"
end
local function colorFor(cls)
  if cls == "enemy" then return colors.red
  elseif cls == "ally" then return colors.lime
  else return colors.yellow end
end

local function fetchPlayers()
  local ok, res = pcall(http.get, cfg.url.."/maps/"..cfg.map.."/live/players")
  if not ok or not res then return nil end
  local body = res.readAll(); res.close()
  local ok2, data = pcall(textutils.unserialiseJSON, body)
  if not ok2 or type(data) ~= "table" then return nil end
  return data.players or {}
end

local players, touchMap, selected, selTimer = {}, {}, nil, 0

-- Maps a world (x,z) to a monitor (col,row); nil if outside the view radius.
local function screenPos(px, pz, gridTop, gridBottom, W)
  local dx, dz = px - cfg.originX, pz - cfg.originZ
  if math.abs(dx) > cfg.range or math.abs(dz) > cfg.range then return nil end
  local gridH = gridBottom - gridTop
  local col = math.floor((dx + cfg.range) / (2*cfg.range) * (W-1) + 0.5) + 1
  local row = gridTop + math.floor((dz + cfg.range) / (2*cfg.range) * gridH + 0.5)
  return col, row
end

local function drawLegend(y)
  mon.setCursorPos(1, y)
  mon.setBackgroundColor(colors.lime); mon.write("  ")
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.write(" Ally  ")
  mon.setBackgroundColor(colors.red); mon.write("  ")
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.write(" Enemy  ")
  mon.setBackgroundColor(colors.yellow); mon.write("  ")
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.write(" Neutral")
end

local function draw()
  touchMap = {}
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan); mon.write(TITLE)
  mon.setTextColor(colors.lightGray); mon.setCursorPos(W-4,1)
  mon.write(textutils.formatTime(os.time(), true))

  mon.setCursorPos(1,2)
  if selected and os.clock() < selTimer then
    mon.setTextColor(colorFor(selected.cls))
    mon.write(("%s  (%d, %d)"):format(selected.name, selected.x, selected.z))
  else
    mon.setTextColor(colors.lightGray)
    mon.write(("%d players tracked"):format(#players))
  end

  local gridTop, gridBottom = 3, H-1
  local ox, oz = screenPos(cfg.originX, cfg.originZ, gridTop, gridBottom, W)
  if ox then
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.gray)
    mon.setCursorPos(ox, oz); mon.write("+")
  end

  for _, p in ipairs(players) do
    local col, row = screenPos(p.x, p.z, gridTop, gridBottom, W)
    if col then
      mon.setCursorPos(col, row); mon.setBackgroundColor(colors.black)
      mon.setTextColor(colorFor(p.cls)); mon.write(p.letter)
      touchMap[row] = touchMap[row] or {}
      touchMap[row][col] = p
    end
  end

  drawLegend(H)
end

-- Foreign entries are on a different BlueMap map than the one we're
-- querying, so their coordinates wouldn't land correctly on this grid.
local function refresh()
  local raw = fetchPlayers()
  if not raw then return end
  local list = {}
  for _, r in ipairs(raw) do
    if not r.foreign and r.position then
      list[#list+1] = { name=r.name, x=r.position.x, z=r.position.z,
                         cls=classify(r.name), letter=r.name:sub(1,1):upper() }
    end
  end
  players = list
end

local pollTimer = os.startTimer(0)
print("Player radar running. Ctrl+T to stop.")
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == pollTimer then
    refresh(); draw(); pollTimer = os.startTimer(cfg.refresh)
  elseif ev == "monitor_touch" then          -- event, side, x, y
    local hit = touchMap[c] and touchMap[c][b]
    if hit then selected = hit; selTimer = os.clock() + SELDUR end
    draw()
  end
end
