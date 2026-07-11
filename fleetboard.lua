-- fleetboard.lua  (CC:Tweaked) — runs on the MASTER ship's (Lightning's) own
-- computer, wired to its monitor. Shows live status for every ship.lua node
-- (Bolt I/II/III, etc.) reporting in, and gives you a terminal command
-- console to aim and fire them:
--
--   list                 -- show every bolt heard from, and whether it's enabled
--   enable <name>        -- let that bolt receive aim commands
--   disable <name>       -- stop sending it aim commands
--   aim <x> <y> <z>      -- send that point to every ENABLED bolt; each one
--                           solves its own firing solution and fires once
--                           it settles on target (see ship.lua)
--
-- SAFETY: a bolt only ever receives "aim" if you've explicitly `enable`d it
-- in THIS session — commands are sent by targeted rednet.send() to known
-- computer IDs, never broadcast, and every bolt starts disabled on boot (the
-- roster is not saved to disk), so a bolt left behind on a previous session
-- can't be commanded by accident.
--
-- The monitor is read-only status; all commands go through this computer's
-- own terminal (keyboard), run alongside the monitor update loop via
-- parallel.waitForAny so typing a command doesn't freeze the board.

local PROTO = "shipnet"
local STALE = 8       -- seconds before a bolt's data is shown OFFLINE
local SCALE = 0.5      -- small monitor -> smaller text, more rows/cols

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

-- roster[name] = { computerId=, enabled=false, msg=<last status msg>, t=<os.clock at receipt> }
local roster = {}

local function myPosition()
  local ok, x, y, z = pcall(gps.locate, 2)
  if ok and x then return { x = x, y = y, z = z } end
end

local function dist(a, b)
  if not a or not b then return nil end
  local dx, dy, dz = a.x-b.x, a.y-b.y, a.z-b.z
  return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function pad(s, w) s = tostring(s); w = math.max(w, 0); if #s > w then return s:sub(1,w) end return s..(" "):rep(w-#s) end

-- Summarize a bolt's cannon states into one short label for the board.
local function cannonSummary(cannons)
  if not cannons or #cannons == 0 then return "no cannons" end
  local counts = { idle=0, aiming=0, fired=0 }
  for _, c in ipairs(cannons) do counts[c.state] = (counts[c.state] or 0) + 1 end
  if counts.aiming > 0 then return ("AIMING x%d"):format(counts.aiming) end
  if counts.fired == #cannons then return ("FIRED x%d"):format(counts.fired) end
  if counts.idle == #cannons then return ("idle x%d"):format(counts.idle) end
  return ("mixed (%d cannons)"):format(#cannons)
end

-- ---- monitor board (read-only, auto-paginating) ---------------------------

local page = 1

local function draw()
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  local here = myPosition()
  local now = os.clock()

  local names = {}
  for name in pairs(roster) do names[#names+1] = name end
  table.sort(names)

  local rows = math.max(H - 1, 1)
  local pages = math.max(math.ceil(#names / rows), 1)
  if page > pages then page = 1 end
  local start = (page-1)*rows

  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan)
  mon.write(pad(pages > 1 and ("FLEET %d/%d"):format(page, pages) or "FLEET", W))

  if #names == 0 then
    mon.setTextColor(colors.gray); mon.setCursorPos(1,2); mon.write("No bolts reporting in yet.")
    return
  end

  local y = 2
  for i = start+1, math.min(start+rows, #names) do
    local name = names[i]
    local b = roster[name]
    mon.setCursorPos(1,y)

    mon.setTextColor(b.enabled and colors.lime or colors.gray)
    mon.write(b.enabled and "[ON] " or "[--] ")

    if (now - b.t) > STALE then
      mon.setTextColor(colors.gray); mon.write(pad(name.." OFFLINE", W-5))
    else
      local m = b.msg
      local d = dist(here, m.position)
      mon.setTextColor(colors.white);     mon.write(pad(name, 8))
      mon.setTextColor(colors.lightGray); mon.write(pad(d and (math.floor(d).."m") or "?m", 6))
      mon.setTextColor(colors.yellow);    mon.write(pad(cannonSummary(m.cannons), W))
    end
    y = y + 1
  end
end

-- ---- background: ingest status, redraw, auto-page --------------------------

local function eventLoop()
  local redrawTimer = os.startTimer(0)
  local pageTimer    = os.startTimer(4)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "status" then
      local prev = roster[b.id]
      roster[b.id] = { computerId = a, enabled = prev and prev.enabled or false, msg = b, t = os.clock() }
    elseif ev == "monitor_touch" then
      page = page + 1; draw()
    elseif ev == "timer" then
      if a == redrawTimer then draw(); redrawTimer = os.startTimer(2)
      elseif a == pageTimer then page = page + 1; draw(); pageTimer = os.startTimer(4) end
    end
  end
end

-- ---- foreground: terminal command console ----------------------------------

local function printHelp()
  print("Commands:")
  print("  list                -- show known bolts and enabled state")
  print("  enable <name>       -- allow a bolt to receive aim commands")
  print("  disable <name>      -- stop sending it aim commands")
  print("  aim <x> <y> <z>     -- send target to every ENABLED bolt")
  print("  help                -- show this again")
end

local function cmdList()
  local names = {}
  for name in pairs(roster) do names[#names+1] = name end
  table.sort(names)
  if #names == 0 then print("No bolts heard from yet."); return end
  for _, name in ipairs(names) do
    local b = roster[name]
    local age = os.clock() - b.t
    print(("  %-10s %s  last seen %ds ago  %s"):format(
      name, b.enabled and "ENABLED " or "disabled", math.floor(age), cannonSummary(b.msg.cannons)))
  end
end

local function cmdEnable(name, on)
  local b = roster[name]
  if not b then print(("Unknown bolt \"%s\" — no status heard yet."):format(name)); return end
  b.enabled = on
  print(("%s %s."):format(name, on and "enabled" or "disabled"))
end

local function cmdAim(parts)
  local x, y, z = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
  if not (x and y and z) then print("Usage: aim <x> <y> <z>"); return end
  local sent = {}
  for name, b in pairs(roster) do
    if b.enabled then
      rednet.send(b.computerId, { type="aim", target={x=x,y=y,z=z} }, PROTO)
      sent[#sent+1] = name
    end
  end
  if #sent == 0 then
    print("No bolts are enabled -- nothing sent. Use `enable <name>` first.")
  else
    table.sort(sent)
    print(("Sent (%s, %s, %s) to: %s"):format(x, y, z, table.concat(sent, ", ")))
  end
end

local function commandLoop()
  printHelp()
  while true do
    write("> ")
    local line = read()
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts+1] = w end
    local cmd = parts[1]
    if cmd == "list" then cmdList()
    elseif cmd == "enable" and parts[2] then cmdEnable(parts[2], true)
    elseif cmd == "disable" and parts[2] then cmdEnable(parts[2], false)
    elseif cmd == "aim" then cmdAim(parts)
    elseif cmd == "help" or cmd == nil then printHelp()
    else print("Unknown command. Type 'help' for the list.") end
  end
end

parallel.waitForAny(commandLoop, eventLoop)
