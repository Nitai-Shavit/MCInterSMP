-- install.lua (CC:Tweaked) — bootstrap installer for the storage monitor.
-- Fetches collector.lua or display.lua straight from this repo (no pastebin)
-- and points startup.lua at it. Single-line paste, e.g.:
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
f.write('shell.run("'..file..'")\n')
f.close()

print("Installed "..file.." and set startup.lua.")
print("Reboot to auto-start (Ctrl+R), or run: "..file)
