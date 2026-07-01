-- install.lua (CC:Tweaked) — bootstrap installer for the storage monitor.
-- Fetches collector.lua or display.lua straight from this repo (no pastebin)
-- and writes a startup.lua that re-pulls the latest version from GitHub on
-- every boot before running it, so an already-deployed computer picks up
-- updates just by rebooting. If the pull fails (offline / http disabled),
-- it falls back to whatever copy is already on disk. Single-line paste:
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua collector
--   wget run https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/install.lua display

local REPO = "https://raw.githubusercontent.com/Nitai-Shavit/MCInterSMP/main/"
local role = ...

if role ~= "collector" and role ~= "display" then
  print("Usage: wget run "..REPO.."install.lua <collector|display>")
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
