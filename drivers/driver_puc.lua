local hasFilesystem, lfs = pcall(require, "lfs")

local driver = {}

-- Taken from a previous project of mine (gitl), stripped down

driver.filesystem = {}
driver.filesystem.collapse = function(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then
        table.remove(parts, #parts)
      end
    elseif part ~= "." then
      table.insert(parts, part)
    end
  end

  local str = table.concat(parts, "/")
  if (str:sub(1, 1) == "/") and (path:sub(1, 1) ~= "/") then
    return str:sub(2)
  end
  if (str:sub(1, 1) ~= "/") and (path:sub(1, 1) == "/") then
    return "/" .. str
  end

  return str
end
driver.filesystem.combine = function(...)
  local result = table.concat({...}, "/")
  
  local hasSlash, args, i = false, {...}, 1
  while i ~= -1 and args[i] do
    if args[i] == "" then
      i = i + 1
    elseif args[i]:sub(1, 1) == "/" then
      hasSlash = true
      i = -1
    else
      i = i + 1
    end
  end

  if not hasSlash and result:sub(1, 1) == "/" then
    return result:sub(2)
  end
  return result
end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDir = driver.filesystem.combine(scriptPath:match("(.*/)") or "./", "..")
driver.filesystem.workingDir = function()
  return lfs.currentdir()
end
driver.filesystem.codeDir = function()
  return scriptDir
end
driver.filesystem.homeDir = function()
  return os.getenv("HOME")
end
driver.filesystem.list = function(path)
  local files = {}
  for file in lfs.dir(path) do
    if file ~= "." and file ~= ".." then
      table.insert(files, file)
    end
  end
  return files
end
driver.filesystem.makeDir = function(path, recursive)
  if recursive then
    local parent = driver.filesystem.collapse(driver.filesystem.combine(path, ".."))
    if parent ~= "" and not driver.filesystem.exists(parent) then
      driver.filesystem.makeDir(parent, true)
    end
  end
  lfs.mkdir(driver.filesystem.collapse(path))
end
driver.filesystem.exists = function(path)
  return lfs.attributes(path) ~= nil
end
driver.filesystem.isFile = function(path)
  return lfs.attributes(path, "mode") == "file"
end
driver.filesystem.isDir = function(path)
  return lfs.attributes(path, "mode") == "directory"
end

driver.filesystem.rm = function(path, recursive)
  if recursive and driver.filesystem.isDir(path) then
    for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
        driver.filesystem.rm(driver.filesystem.combine(path, file), true)
      end
    end
  end
  os.remove(path)
end

driver.filesystem.resolve = function(path)
  return path
end

local function getTimezoneOffset(ts)
  ts = ts or os.time()
  local utcTable = os.date("!*t", ts)
  ---@diagnostic disable-next-line: param-type-mismatch
  local utcAsLocal = os.time(utcTable)
  return os.difftime(ts, utcAsLocal)
end

local baseTime = driver.time or os.time
driver.time = function()
  local now = baseTime()
  return now + getTimezoneOffset(now)
end

if not hasFilesystem then
  driver.filesystem = nil
end

return driver