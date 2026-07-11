-- install.lua (CC:Tweaked) — bootstrap installer for the storage monitor,
-- the cannon command subsystem, and the player radar. Fetches the matching
-- program straight from this repo (no pastebin) and writes a startup.lua
-- that re-pulls the latest version from GitHub on every boot before
-- running it, so an already-deployed computer picks up updates just by
-- rebooting. If the pull fails
-- (offline / http disabled), it falls back to whatever copy is already on
-- disk. Single-line paste, one of:
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua collector
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua display
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua radar
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua cannon
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua gunner
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua master
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua ship
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua fleetboard
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua playerradar

local REPO = "https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/"
local ROLES = { collector=true, display=true, radar=true, cannon=true, master=true,
                ship=true, fleetboard=true, playerradar=true, gunner=true }
local role = ...

if not ROLES[role] then
  print("Usage: wget run "..REPO.."install.lua <collector|display|radar|cannon|gunner|master|ship|fleetboard|playerradar>")
  return
end

local file = role..".lua"
print("Fetching "..file.." ...")
if not shell.run("wget", REPO..file, file) then
  print("Download failed — check that http.enabled is true and")
  print("raw.githubusercontent.com is allowed in the server's CC config.")
  return
end

local f = fs.open("startup.lua", "w")
f.write(([[
-- Auto-pull the latest %s from GitHub, then run it.
-- Falls back to the copy already on disk if the pull fails.
shell.run("wget", "%s%s", "%s")
shell.run("%s")
]]):format(file, REPO, file, file, file))
f.close()

print("Installed "..file.." and set startup.lua (auto-updates on every boot).")
print("Reboot to auto-start (Ctrl+R), or run: "..file)
