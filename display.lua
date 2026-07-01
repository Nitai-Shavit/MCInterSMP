-- display.lua  (CC:Tweaked) — runs on the computer wired to an ADVANCED monitor.
-- Listens to all collectors over rednet, merges storages by group, draws bars,
-- and shows an item breakdown when an item bar is touched.
--
-- CONFIG --------------------------------------------------------------------
local PROTO  = "storagemon"
local TITLE  = "Kingdom of Bavaria Storage Monitor"
local STALE  = 12       -- seconds before a missing collector's data drops off
local SCALE  = 1        -- monitor font: 0.5..5 in 0.5 steps. Smaller = more rows.
-- Display order, top to bottom. Names must match the GROUP set in setup exactly.
-- Anything not listed falls below these, alphabetically.
local ORDER  = { "Main", "Resource Vault", "Agricultural", "Arbor" }
-- ---------------------------------------------------------------------------

local mon = peripheral.find("monitor"); assert(mon, "No monitor")
mon.setTextScale(SCALE)

local mside
for _, n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then mside = n break end
end
assert(mside, "No wireless/ender modem found"); rednet.open(mside)

local latest, view, rowMap = {}, { mode="main" }, {}

local function ingest(es) for _, r in ipairs(es) do latest[r.id] = { row=r, t=os.clock() } end end

-- Merge all live entries by group.
local function groups()
  local g, order, now = {}, {}, os.clock()
  for _, v in pairs(latest) do
    if now - v.t <= STALE then
      local r = v.row
      local a = g[r.group]
      if not a then a = { label=r.group, kind=r.kind, online=false }; g[r.group]=a; order[#order+1]=r.group end
      if r.online then
        a.online = true
        if r.kind == "item" then a.used=(a.used or 0)+(r.used or 0); a.total=(a.total or 0)+(r.total or 0)
        else a.amount=(a.amount or 0)+(r.amount or 0); a.capacity=(a.capacity or 0)+(r.capacity or 0) end
      end
    end
  end
  local out = {}; for _, n in ipairs(order) do out[#out+1] = g[n] end
  return out
end

local function rank(name)
  for i, n in ipairs(ORDER) do if n == name then return i end end
  return math.huge
end
-- Items: full = red (bad), empty = green (good).
local function colorFor(f)
  if f >= .90 then return colors.red elseif f >= .70 then return colors.orange
  elseif f >= .40 then return colors.yellow else return colors.lime end
end
-- Fluids: inverted — full = green (good), empty = red (bad).
local function colorForFluid(f) return colorFor(1 - f) end
local function pad(s, w) s = tostring(s); if #s > w then return s:sub(1,w) end return s..(" "):rep(w-#s) end
local function pretty(id) return (id:gsub("^[^:]+:",""):gsub("_"," ")) end

local function drawBar(d, y, labelW, statsW, barW)
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white)
  mon.setCursorPos(1,y); mon.write(pad(d.label, labelW))
  if not d.online then
    mon.setTextColor(colors.red); mon.setCursorPos(labelW+2,y); mon.write("OFFLINE"); return
  end
  local frac, stats, col
  if d.kind == "item" and d.total and d.total > 0 then
    frac = d.used/d.total; col = colorFor(frac)
    stats = ("%d%% | %d free"):format(math.floor(frac*100+.5), d.total-d.used)
  elseif d.kind == "fluid" and d.capacity and d.capacity > 0 then
    frac = math.min(d.amount/d.capacity,1); col = colorForFluid(frac)
    stats = ("%d%% | %.0fB"):format(math.floor(frac*100+.5), d.amount/1000)  -- total stored
  end
  if frac then
    local fill = math.floor(frac*barW + .5)
    mon.setCursorPos(labelW+2,y)
    mon.setBackgroundColor(col);          mon.write((" "):rep(fill))
    mon.setBackgroundColor(colors.gray);  mon.write((" "):rep(barW-fill))
    mon.setBackgroundColor(colors.black); mon.setTextColor(col)
    mon.setCursorPos(labelW+2+barW+1,y);  mon.write(pad(stats, statsW))
  else
    mon.setTextColor(colors.lightGray); mon.setCursorPos(labelW+2,y)
    mon.write(("%.0fB stored (no cap)"):format((d.amount or 0)/1000))
  end
end

local function drawMain()
  rowMap = {}
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  local clock = textutils.formatTime(os.time(), true)
  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan)
  if W - #clock - 2 >= 8 then
    mon.write(pad(TITLE, W - #clock - 1))
    mon.setTextColor(colors.lightGray); mon.setCursorPos(W-#clock+1,1); mon.write(clock)
  else
    mon.write(pad(TITLE, W))  -- monitor too narrow for title + clock; drop the clock
  end

  local items, fluids = {}, {}
  for _, d in ipairs(groups()) do
    if d.kind == "fluid" then fluids[#fluids+1] = d else items[#items+1] = d end
  end
  local function byRank(a,b)
    local ra, rb = rank(a.label), rank(b.label)
    if ra ~= rb then return ra < rb end
    return a.label < b.label
  end
  table.sort(items, byRank); table.sort(fluids, byRank)

  -- Size the label column to the longest label actually on screen (capped),
  -- so names like "Resource Vault" don't get truncated, while still leaving
  -- the bar a sane minimum width.
  local maxLabel = 4
  for _, d in ipairs(items) do maxLabel = math.max(maxLabel, #d.label) end
  for _, d in ipairs(fluids) do maxLabel = math.max(maxLabel, #d.label) end
  local labelW = math.min(maxLabel, math.max(math.floor(W * 0.35), 6))
  local statsW = math.min(16, math.max(math.floor(W * 0.3), 8))
  local barW = math.max(W - labelW - statsW - 2, 4)

  local y = 3
  for _, d in ipairs(items) do
    if y > H-1 then break end
    if d.online and d.total and d.total > 0 then rowMap[y] = d.label end  -- touchable
    drawBar(d, y, labelW, statsW, barW); y = y + 1
  end
  if #fluids > 0 and y <= H-1 then
    local sep = "----- Fluids "; sep = sep..("-"):rep(math.max(W-#sep,0))
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.blue)
    mon.setCursorPos(1,y); mon.write(sep:sub(1,W)); y = y + 1
  end
  for _, d in ipairs(fluids) do
    if y > H then break end
    drawBar(d, y, labelW, statsW, barW); y = y + 1
  end
end

-- Rows reserved outside the item list: title, status/page line, footer.
local DETAIL_CHROME = 3

local function drawDetail()
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan); mon.write(pad(view.group.." - details", W))

  local sorted = {}
  for nm, ct in pairs(view.items) do sorted[#sorted+1] = { nm=nm, ct=ct } end
  table.sort(sorted, function(a,b) return a.ct > b.ct end)

  local rows = math.max(H - DETAIL_CHROME, 1)
  local pages = math.max(math.ceil(#sorted / rows), 1)
  if view.page > pages then view.page = pages end
  view.pages = pages
  local start = (view.page - 1) * rows

  mon.setCursorPos(1,2); mon.setTextColor(colors.gray)
  if view.collecting then
    mon.write("scanning...")
  elseif pages > 1 then
    mon.write(("page %d/%d  (%d items)"):format(view.page, pages, #sorted))
  else
    mon.write(("%d items"):format(#sorted))
  end

  local y = 3
  for i = start+1, math.min(start+rows, #sorted) do
    local it = sorted[i]
    mon.setCursorPos(1,y); mon.setTextColor(colors.white); mon.write(pad(pretty(it.nm), W-8))
    mon.setTextColor(colors.lime); mon.setCursorPos(W-7,y); mon.write(pad(it.ct, 8))
    y = y + 1
  end

  mon.setTextColor(colors.gray); mon.setCursorPos(1,H)
  if pages > 1 then
    local half = math.floor(W/2)
    mon.write(pad("< back", half))
    mon.setCursorPos(half+1,H); mon.write(pad("next page >", W-half))
  else
    mon.write("touch to go back")
  end
end

local function draw() if view.mode == "detail" then drawDetail() else drawMain() end end

-- Two separate timers so a routine redraw can't slam the detail window shut early.
local redrawTimer, collectTimer = os.startTimer(0), nil
local function requestDetail(g)
  view = { mode="detail", group=g, items={}, collecting=true, page=1, pages=1 }
  rednet.broadcast({ type="detail_req", group=g }, PROTO)
  collectTimer = os.startTimer(1.2)
end

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "rednet_message" and c == PROTO and type(b) == "table" then
    if b.type == "summary" then ingest(b.entries)
    elseif b.type == "detail" and view.mode=="detail" and view.collecting and b.group==view.group then
      for nm, ct in pairs(b.items) do view.items[nm] = (view.items[nm] or 0) + ct end
      draw()
    end
  elseif ev == "monitor_touch" then     -- event, side, x, y  -> x is b, y is c
    if view.mode == "detail" then
      local W, H = mon.getSize()
      if c == H then
        if view.pages > 1 and b > math.floor(W/2) then
          view.page = (view.page % view.pages) + 1
        else
          view = { mode="main" }
        end
      end
    else
      local g = rowMap[c]; if g then requestDetail(g) end
    end
    draw()
  elseif ev == "timer" then
    if a == collectTimer then
      if view.mode == "detail" then view.collecting = false; draw() end
    elseif a == redrawTimer then
      draw(); redrawTimer = os.startTimer(2)
    end
  end
end
