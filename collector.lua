-- collector.lua  (CC:Tweaked) — run one per storage cluster.
-- First launch runs setup; re-run setup anytime with: collector setup
-- Connects to nearby silos/vaults/tanks over a WIRED modem network,
-- broadcasts fill data over a WIRELESS/ENDER modem (rednet) to the display.

local PROTO, CFGFILE, REFRESH = "storagemon", "storage.cfg", 3

local function methods(name) return peripheral.getMethods(name) or {} end
local function hasM(name, m)
  for _, x in ipairs(methods(name)) do if x == m then return true end end
  return false
end
-- Detect kind by available methods (works regardless of registry name: silo vs vault)
local function kindOf(name)
  if hasM(name, "list")  then return "item"  end
  if hasM(name, "tanks") then return "fluid" end
end

local function loadCfg()
  if not fs.exists(CFGFILE) then return nil end
  local f = fs.open(CFGFILE, "r"); local d = f.readAll(); f.close()
  return textutils.unserialise(d)
end
local function saveCfg(c)
  local f = fs.open(CFGFILE, "w"); f.write(textutils.serialise(c)); f.close()
end

-- Setup wizard: assign Label (per-unit name) + Group (merge key / bar title).
-- Same Group = merged into one bar on the display. Fluid capacity is asked in
-- buckets because CC's generic fluid peripheral reports amount but NOT capacity.
local function setup()
  print("=== Storage Monitor setup ===")
  local cfg = { entries = {} }
  for _, name in ipairs(peripheral.getNames()) do
    local k = kindOf(name)
    if k then
      print(("\nFound %s  [%s]"):format(name, k))
      write("  Label (blank = skip): "); local label = read()
      if label ~= "" then
        write("  Group (blank = use label): "); local group = read()
        if group == "" then group = label end
        local cap
        if k == "fluid" then
          write("  Capacity in buckets: ")
          cap = tonumber(read()); if cap then cap = cap * 1000 end  -- store as mB
        end
        cfg.entries[#cfg.entries+1] =
          { peripheral=name, label=label, group=group, kind=k, capacity=cap }
        print("  added.")
      end
    end
  end
  saveCfg(cfg)
  print(("\nSaved %d storages."):format(#cfg.entries))
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

local function scanItem(name)
  local p = peripheral.wrap(name)
  local used = 0
  for _ in pairs(p.list()) do used = used + 1 end   -- list() = occupied slots only
  return used, p.size()
end
local function detailItem(name)
  local p, agg = peripheral.wrap(name), {}
  for _, it in pairs(p.list()) do agg[it.name] = (agg[it.name] or 0) + it.count end
  return agg
end
local function scanFluid(name)
  local amount = 0
  local ok, tanks = pcall(peripheral.call, name, "tanks")
  if ok and type(tanks) == "table" then
    for _, t in ipairs(tanks) do amount = amount + (t.amount or 0) end
  end
  return amount
end

local arg = ...
local cfg = loadCfg()
if arg == "setup" or not cfg then cfg = setup() end

local mside = wirelessModem()
assert(mside, "No wireless/ender modem found for rednet")
rednet.open(mside)
local myId = os.getComputerID()
print("Collector "..myId.." running. Ctrl+T to stop.")

local function broadcast()
  local entries = {}
  for _, e in ipairs(cfg.entries) do
    local row = { id=myId.."/"..e.peripheral, label=e.label,
                  group=e.group, kind=e.kind, online=peripheral.isPresent(e.peripheral) }
    if row.online then
      if e.kind == "item" then row.used, row.total = scanItem(e.peripheral)
      else row.amount, row.capacity = scanFluid(e.peripheral), e.capacity end
    end
    entries[#entries+1] = row
  end
  rednet.broadcast({ type="summary", from=myId, entries=entries }, PROTO)
end

local timer = os.startTimer(0)
while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "timer" and a == timer then
    broadcast(); timer = os.startTimer(REFRESH)
  elseif ev == "rednet_message" and c == PROTO and type(b) == "table"
         and b.type == "detail_req" then
    local items = {}
    for _, e in ipairs(cfg.entries) do
      if e.kind == "item" and e.group == b.group and peripheral.isPresent(e.peripheral) then
        for nm, ct in pairs(detailItem(e.peripheral)) do items[nm] = (items[nm] or 0) + ct end
      end
    end
    rednet.send(a, { type="detail", group=b.group, items=items }, PROTO)
  end
end
