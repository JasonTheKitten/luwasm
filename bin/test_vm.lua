local originalEnv = {}
for k, v in pairs(_ENV or _G) do
  originalEnv[k] = v
end

local cache = {}
local localRequire
function localRequire(name)
  if cache[name] then
    return cache[name]
  end

  local scriptPath, scriptDir
  if originalEnv.PROGRAM_LOCATION then
    scriptDir = _ENV.PROGRAM_LOCATION
  else
    scriptPath = debug.getinfo(1, "S").source:sub(2)
    scriptDir = (scriptPath:match("(.*/)") or "./") .. "../"
  end

  local env = {}
  for k, v in pairs(originalEnv) do
    env[k] = v
  end
  env.localRequire = localRequire

  local loadName = name
  if loadName == "driver" then
    if originalEnv.DRIVER_NAME then
      loadName = "drivers/" .. _ENV.DRIVER_NAME
    else
      loadName = "drivers/driver_puc"
    end
  end
  
  local ok, err = loadfile(scriptDir .. loadName .. ".lua", "t", env)
  if not ok then
    error(err)
  end

  local result = ok()
  cache[name] = result
  return result
end

--

local args = { ... }
if not args[1] then
  error("Must specify a valid module file")
end
if not args[2] then
  error("Must specify function to call")
end

local moduleParser = localRequire("lib/moduleparser")
local testModule = args[1]
local testModuleHandle, err = io.open(testModule, "rb")
if not testModuleHandle then error(err) end
local module, err = moduleParser.readModule(testModuleHandle)
testModuleHandle:close()
if not module then error(err) end

local wasiLib = localRequire("lib/wasi")
local wasiFS = localRequire("lib/wasi_fs")

local env = {}
local fds = {
  wasiFS.createFile(wasiFS.bytesFile({})),
  wasiFS.createFile(wasiFS.logFile(function(msg)
    print("[STDOUT] " .. msg)
  end)),
  wasiFS.createFile(wasiFS.logFile(function(msg)
    print("[STDERR] " .. msg)
  end)),
  wasiFS.createPreOpenDirectory(".", wasiFS.realDir(wasiFS.relPath("../data")))
}
local wasi = wasiLib.create(env, fds)

local VM = localRequire("lib/vm")
local vm = assert(VM.createVM(module, {
  wasi_snapshot_preview1 = wasi.imports,
  env = {}
}))
wasi.initialize(vm)

print(assert(vm.exports[args[2]]()))