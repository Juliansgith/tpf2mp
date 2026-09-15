local bootstrap = assert(arg[1])
local files, now = {}, 100
local environment = {TPF2MP_PEER_ID='player1',TPF2MP_SESSION_ID='lobby-load-test',
  TPF2MP_BRIDGE_DIR='bridge',TPF2MP_STAGED_SAVE_NAME='pinned-world',
  TPF2MP_AUTOMATIC_WORLD_LOAD='1'}
os.getenv = function(name) return environment[name] end
os.time = function() return now end
io.open = function(path, mode)
  if not tostring(mode):find('w',1,true) then
    if not files[path] then return nil end
    return {read=function() return files[path] end,close=function() end}
  end
  return {write=function(_,text) files[path]=text end,close=function() end}
end
local menu = {isVisible=function() return true end}
api = {gui={util={getById=function(id) if id=='menuUI' then return menu end end}}}
local loads, runtime = 0, nil
app = {loadGame=function(name)
  assert(name=='pinned-world')
  assert(files['bridge/launcher/start-clicked']=='native-load','must fence before native re-entry')
  loads=loads+1
  for _=1,35 do runtime.update() end
  return true
end}
dofile(bootstrap)
runtime = data()
for _=1,60 do runtime.update() end
assert(loads==0,'must wait for startup settling')
now=111
for _=1,90 do runtime.update() end
assert(loads==1,'exactly one native load, including re-entry')
environment.TPF2MP_STAGED_SAVE_NAME='../foreign-save'
assert(not pcall(data),'path traversal must not reach the application loader')
print('PASS automatic native load: delayed, pinned, re-entry fenced, no click/console path')
