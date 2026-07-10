-- master.lua  (CC:Tweaked) — the central Cannon Command computer, wired to
-- an ADVANCED monitor. Listens to radar.lua and cannon.lua over rednet,
-- lets you touch-assign radar targets to cannons, and continuously computes
-- and sends firing solutions for assigned cannons.
--
-- Run "master commission" (no monitor needed) to hand cannons from the radar
-- mod's own auto-aim network to full computer control. That is the ONLY
-- place stopAuto() gets triggered, and it asks for one typed "YES" up front
-- for the whole batch — see the big comment above the commission() function.
--
-- ============================================================================
-- CALIBRATION NOTES (nothing here has been verified against a live server —
-- this project was written before any of it was physically built; expect to
-- tune these once you can test-fire in-game):
--
-- - GRAVITY / DRAG below are placeholders borrowed from a DIFFERENT Create-
--   family subsystem (rocket launchpads: -0.04 blocks/tick^2 gravity, 1%/tick
--   drag) because there is no published formula for CBC cannon shells
--   specifically — even the one community ballistic calculator for this mod
--   pair says outright there's no known closed-form formula, and solves by
--   brute-force simulation, which is exactly what solvePitches() below does.
-- - MPS_PER_CHARGE = 40 (m/s per propellant charge, linear) comes from your
--   own in-game testing, converted to blocks/tick in cannon.lua.
-- - The yaw convention (0..360, which direction is 0) and the muzzle forward
--   vector in muzzlePos() are a best guess at Minecraft's usual yaw/pitch
--   convention. If a commissioned cannon aims 90/180 degrees off after you
--   send it a solution, that's the first thing to fix — aim a cannon at a
--   known nearby point manually via setAngle and compare to F3's facing to
--   pin down the real convention, then adjust the dx/dz signs here.
-- - No collision/obstacle checking: a solved trajectory that clips terrain
--   or a build in the way is not detected.
-- ============================================================================

local PROTO  = "cbcnet"
local STALE  = 6         -- seconds before a track or cannon status drops off
local SCALE  = 1
local AIM_PERIOD = 1      -- seconds between re-solving/re-sending aim commands

local GRAVITY = -0.04     -- blocks/tick^2 (UNVERIFIED for cannon shells, see above)
local DRAG    = 0.01      -- fraction of velocity lost per tick (UNVERIFIED, see above)

-- ---------------------------------------------------------------------------
-- Ballistics: muzzle offset + brute-force trajectory search (no closed form
-- exists for a drag-affected shell; this mirrors the community CBC
-- calculator's approach of scanning angles and refining by bisection).
-- ---------------------------------------------------------------------------

-- World position the shell actually leaves from: mount position, offset by
-- barrel length along the barrel's facing (yaw/pitch), NOT the pivot point.
local function muzzlePos(mount, barrel, yawDeg, pitchDeg)
  local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
  local dx = -math.sin(yaw) * math.cos(pitch)
  local dz =  math.cos(yaw) * math.cos(pitch)
  local dy =  math.sin(pitch)
  return { x = mount.x + dx*barrel, y = mount.y + dy*barrel, z = mount.z + dz*barrel }
end

-- Simulate a shell fired at `pitchDeg` and `speed` (blocks/tick); return its
-- height once horizontal distance reaches `dist`, or nil if it never gets
-- there (falls short / stalls first).
local function heightAtDistance(speed, pitchDeg, dist)
  local rad = math.rad(pitchDeg)
  local vh, vy = speed*math.cos(rad), speed*math.sin(rad)
  local x, y = 0, 0
  for _ = 1, 2400 do
    vy = vy + GRAVITY
    vh, vy = vh*(1-DRAG), vy*(1-DRAG)
    x, y = x + vh, y + vy
    if x >= dist then return y end
    if vh < 0.001 then return nil end  -- stalled horizontally, will never reach
  end
  return nil
end

-- Scan pitch 1..89 degrees, refining every sign change of (height - dh) by
-- bisection. Returns a list of viable pitches in ascending order (typically
-- {shallow, steep}, or {} if the target is out of range at this speed).
local function solvePitches(speed, dist, dh)
  local solutions = {}
  local prevErr, prevDeg
  for deg = 1, 89 do
    local h = heightAtDistance(speed, deg, dist)
    local err = h and (h - dh) or nil
    if err and prevErr and ((prevErr < 0 and err >= 0) or (prevErr > 0 and err <= 0)) then
      local lo, hi = prevDeg, deg
      for _ = 1, 25 do
        local mid = (lo+hi)/2
        local hm = heightAtDistance(speed, mid, dist)
        local errm = hm and (hm - dh) or -math.huge
        if (prevErr < 0 and errm < 0) or (prevErr > 0 and errm > 0) then lo = mid else hi = mid end
      end
      solutions[#solutions+1] = (lo+hi)/2
    end
    prevErr, prevDeg = err, deg
  end
  return solutions
end

-- Solve yaw/pitch to hit `target` from `cannon` (mount + barrel + muzzleSpeed),
-- iterating a couple of times since the muzzle position itself depends on
-- the yaw/pitch being solved for. Returns nil if out of range.
local function solveAim(cannon, target)
  local mount = { x = cannon.x, y = cannon.y, z = cannon.z }
  local yaw = math.deg(math.atan2(target.x - mount.x, target.z - mount.z))
  if yaw < 0 then yaw = yaw + 360 end
  local pitch = 20  -- seed guess
  for _ = 1, 3 do
    local muzzle = muzzlePos(mount, cannon.barrel or 0, yaw, pitch)
    local dx, dz = target.x - muzzle.x, target.z - muzzle.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local dh = target.y - muzzle.y
    yaw = math.deg(math.atan2(dx, dz)); if yaw < 0 then yaw = yaw + 360 end
    local sols = solvePitches(cannon.muzzleSpeed, dist, dh)
    if #sols == 0 then return nil end
    pitch = sols[1]  -- shallow arc: faster, more direct
  end
  return yaw, pitch
end

-- Lead a moving target by estimated time-of-flight, refined over a couple of
-- passes alongside the aim solve itself.
local function aimAtTrack(cannon, track)
  local tof, yaw, pitch = 0, nil, nil
  for _ = 1, 3 do
    local lead = { x = track.position.x + track.velocity.x*tof,
                   y = track.position.y + track.velocity.y*tof,
                   z = track.position.z + track.velocity.z*tof }
    yaw, pitch = solveAim(cannon, lead)
    if not yaw then return nil end
    local dx, dz = lead.x - cannon.x, lead.z - cannon.z
    local dist = math.sqrt(dx*dx + dz*dz)
    tof = dist / (cannon.muzzleSpeed * math.cos(math.rad(pitch)) + 1e-6)
  end
  return yaw, pitch
end

-- ---------------------------------------------------------------------------
-- Networking / peripherals
-- ---------------------------------------------------------------------------

local function wirelessModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then return n end
  end
end

-- ---------------------------------------------------------------------------
-- master commission — terminal-only, one-time confirmation for the WHOLE
-- batch of not-yet-commissioned cannons (not per cannon, not per node).
-- stopAuto() is irreversible without physically re-linking in-game, so this
-- never runs silently.
-- ---------------------------------------------------------------------------

local function commission()
  local mside = wirelessModem()
  assert(mside, "No wireless/ender modem found for rednet")
  rednet.open(mside)
  print("Listening for cannon nodes (5s)...")
  local pending, seenCount = {}, 0
  local endAt = os.clock() + 5
  while os.clock() < endAt do
    local timer = os.startTimer(math.max(endAt - os.clock(), 0))
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == PROTO and type(b) == "table" and b.type == "status" then
      for _, cn in ipairs(b.cannons) do
        seenCount = seenCount + 1
        if not cn.commissioned then pending[cn.id] = true end
      end
    elseif ev == "timer" and a == timer then
      break
    end
  end
  local ids = {}
  for id in pairs(pending) do ids[#ids+1] = id end
  table.sort(ids)
  if #ids == 0 then
    print(("No un-commissioned cannons heard (saw %d cannon status report(s))."):format(seenCount))
    return
  end
  print(("\n%d cannon(s) NOT yet under computer control:"):format(#ids))
  for _, id in ipairs(ids) do print("  - "..id) end
  print("\nThis calls stopAuto() on each one's pitch + yaw controllers,")
  print("permanently handing control from the radar mod's auto-aim network to")
  print("these computers. Undoing it requires physically re-linking in-game.")
  write("Type YES to commission all of the above: ")
  if read() == "YES" then
    for _, id in ipairs(ids) do rednet.broadcast({ type="commission", cannon=id }, PROTO) end
    print("Commission command sent.")
  else
    print("Cancelled — nothing changed.")
  end
end

local arg = ...
if arg == "commission" then
  commission()
  return
end

-- ---------------------------------------------------------------------------
-- Normal run: monitor UI + continuous target tracking / aiming
-- ---------------------------------------------------------------------------

local mon = peripheral.find("monitor"); assert(mon, "No monitor")
mon.setTextScale(SCALE)
local mside = wirelessModem()
assert(mside, "No wireless/ender modem found"); rednet.open(mside)

local tracks, cannons = {}, {}
local view = { mode = "main", page = 1, pages = 1 }
local rowMap = {}
local lastArmedCol = 1

local function ingestTracks(msg)
  for _, tr in ipairs(msg.tracks) do tracks[tr.id] = { t = tr, at = os.clock() } end
end
local function ingestStatus(msg)
  for _, cn in ipairs(msg.cannons) do
    local prev = cannons[cn.id]
    cannons[cn.id] = { c = cn, at = os.clock(), assigned = prev and prev.assigned, node = msg.node }
  end
end

local function liveTracks()
  local now, out = os.clock(), {}
  for _, v in pairs(tracks) do if now - v.at <= STALE then out[#out+1] = v.t end end
  return out
end
local function liveCannons()
  local now, out = os.clock(), {}
  for id, v in pairs(cannons) do if now - v.at <= STALE then out[id] = v end end
  return out
end

local function pad(s, w) s = tostring(s); w = math.max(w, 0); if #s > w then return s:sub(1,w) end return s..(" "):rep(w-#s) end
local function pretty(id) return (tostring(id):gsub("^[^:]+:",""):gsub("_"," ")) end

-- ---- main screen: one row per cannon --------------------------------------

local function drawMain()
  rowMap = {}
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan); mon.write(pad("CANNON COMMAND", W))

  local ids = {}
  for id in pairs(liveCannons()) do ids[#ids+1] = id end
  table.sort(ids)

  -- Column widths scale with monitor width instead of assuming a minimum
  -- size; each has a floor so text never disappears, and the target column
  -- soaks up whatever's left (or gets squeezed to 0 on a very small monitor).
  local idW    = math.min(8, math.max(math.floor(W*0.15), 3))
  local statW  = math.min(9, math.max(math.floor(W*0.18), 4))
  local angW   = math.min(12, math.max(math.floor(W*0.22), 6))
  local armedW = math.min(6, math.max(math.floor(W*0.12), 4))
  local statCol, angCol = idW+2, idW+2+statW+1
  local tgtCol = angCol+angW+1
  local tgtW = math.max(W - tgtCol - armedW - 1, 0)
  local armedCol = W - armedW + 1
  lastArmedCol = armedCol

  local y = 3
  for _, id in ipairs(ids) do
    if y > H-1 then break end
    local entry = cannons[id]
    local cn = entry.c
    mon.setBackgroundColor(colors.black)
    mon.setCursorPos(1,y); mon.setTextColor(colors.white); mon.write(pad(id, idW))

    mon.setTextColor(cn.commissioned and colors.lime or colors.gray)
    mon.setCursorPos(statCol,y); mon.write(pad(cn.commissioned and "COMPUTER" or "AUTO", statW))

    mon.setTextColor(colors.lightGray)
    mon.setCursorPos(angCol,y)
    mon.write(pad(("y%d p%d"):format(math.floor(cn.yaw or 0), math.floor(cn.pitch or 0)), angW))

    local target = entry.assigned and tracks[entry.assigned]
    mon.setCursorPos(tgtCol,y)
    if entry.assigned and not target then
      mon.setTextColor(colors.orange); mon.write(pad("target lost", tgtW))
    elseif target then
      mon.setTextColor(colors.yellow); mon.write(pad(pretty(target.t.entityType or "target"), tgtW))
    else
      mon.setTextColor(colors.gray); mon.write(pad("no target", tgtW))
    end

    mon.setCursorPos(armedCol,y)
    if cn.armed then
      mon.setTextColor(colors.red); mon.write(pad("ARMED", armedW))
    else
      mon.setTextColor(colors.gray); mon.write(pad("safe", armedW))
    end

    rowMap[y] = id
    y = y + 1
  end

  if #ids == 0 then
    mon.setTextColor(colors.gray); mon.setCursorPos(1,3); mon.write("No cannon nodes reporting in yet.")
  end

  mon.setTextColor(colors.gray); mon.setCursorPos(1,H)
  mon.write(pad("touch cannon: pick target   |   right edge: toggle fire", W))
end

-- ---- target picker: paginated list of live radar tracks --------------------

local DETAIL_CHROME = 3

local function drawTargets()
  mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
  local W, H = mon.getSize()
  mon.setCursorPos(1,1); mon.setTextColor(colors.cyan)
  mon.write(pad(("Assign target -> cannon %s"):format(view.pendingCannon), W))

  local cn = cannons[view.pendingCannon] and cannons[view.pendingCannon].c
  local sorted = liveTracks()
  if cn then
    for _, tr in ipairs(sorted) do
      local dx, dz = tr.position.x - cn.x, tr.position.z - cn.z
      tr.__dist = math.sqrt(dx*dx + dz*dz)
    end
    table.sort(sorted, function(a,b) return (a.__dist or 0) < (b.__dist or 0) end)
  end

  local rows = math.max(H - DETAIL_CHROME, 1)
  local pages = math.max(math.ceil(#sorted / rows), 1)
  if view.page > pages then view.page = pages end
  view.pages = pages
  local start = (view.page - 1) * rows

  mon.setCursorPos(1,2); mon.setTextColor(colors.gray)
  mon.write(pages > 1 and ("page %d/%d  (%d tracks)"):format(view.page, pages, #sorted)
                       or ("%d tracks"):format(#sorted))

  view.rowTargets = {}
  local y = 3
  for i = start+1, math.min(start+rows, #sorted) do
    local tr = sorted[i]
    mon.setCursorPos(1,y); mon.setTextColor(colors.white)
    mon.write(pad(pretty(tr.entityType or tr.category or "contact"), W-10))
    mon.setTextColor(colors.lime); mon.setCursorPos(W-9,y)
    mon.write(pad(tr.__dist and (math.floor(tr.__dist).."m") or "?", 9))
    view.rowTargets[y] = tr.id
    y = y + 1
  end

  mon.setTextColor(colors.gray); mon.setCursorPos(1,H)
  if pages > 1 then
    local half = math.floor(W/2)
    mon.write(pad("< back", half))
    mon.setCursorPos(half+1,H); mon.write(pad("next page >", W-half))
  else
    mon.write("touch a row to assign, or touch here to go back")
  end
end

local function draw() if view.mode == "targets" then drawTargets() else drawMain() end end

-- ---- periodic aim solving --------------------------------------------------

local function retarget()
  for id, entry in pairs(liveCannons()) do
    local cn = entry.c
    if cn.commissioned and entry.assigned then
      local track = tracks[entry.assigned]
      if track and (os.clock() - track.at) <= STALE then
        local yaw, pitch = aimAtTrack(cn, track.t)
        if yaw then
          rednet.broadcast({ type="aim", cannon=id, yaw=yaw, pitch=pitch }, PROTO)
        end
      end
    end
  end
end

-- ---- event loop -------------------------------------------------------------

local redrawTimer = os.startTimer(0)
local aimTimer = os.startTimer(AIM_PERIOD)

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "rednet_message" and c == PROTO and type(b) == "table" then
    if b.type == "tracks" then ingestTracks(b)
    elseif b.type == "status" then ingestStatus(b) end
  elseif ev == "monitor_touch" then     -- event, side, x, y -> x is b, y is c
    local W, H = mon.getSize()
    if view.mode == "main" then
      local id = rowMap[c]
      if id then
        if b >= lastArmedCol then
          local cn = cannons[id] and cannons[id].c
          if cn and cn.commissioned then
            rednet.broadcast({ type="fire", cannon=id, on = not cn.armed }, PROTO)
          end
        else
          view = { mode="targets", pendingCannon=id, page=1, pages=1 }
        end
      end
    else
      if c == H then
        if view.pages > 1 and b > math.floor(W/2) then
          view.page = (view.page % view.pages) + 1
        else
          view = { mode="main", page=1, pages=1 }
        end
      elseif view.rowTargets and view.rowTargets[c] then
        local cur = cannons[view.pendingCannon]
        if cur then cur.assigned = view.rowTargets[c] end
        view = { mode="main", page=1, pages=1 }
      end
    end
    draw()
  elseif ev == "timer" then
    if a == redrawTimer then
      draw(); redrawTimer = os.startTimer(2)
    elseif a == aimTimer then
      retarget(); aimTimer = os.startTimer(AIM_PERIOD)
    end
  end
end
