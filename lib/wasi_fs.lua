local bits = localRequire("lib/bits")
local driver = localRequire("driver")
local bshl, bor = bits.shl, bits.bor
local filesystem = driver.filesystem

local U32_MAX = 0xFFFFFFFF

local ERR_EIO = 5
local ERR_ENOENT = 44
local ERR_EEXIST = 17
local ERR_ENOTDIR = 20
local ERR_ENOSYS = 52

local WASI_FILETYPE_CHARACTER_DEVICE = 2
local WASI_FILETYPE_DIRECTORY = 3
local WASI_FILETYPE_REGULAR_FILE = 4

local WASI_RIGHTS_FD_READ = bshl(1, 1)
local WASI_RIGHTS_FD_WRITE = bshl(1, 6)

local wasiFS = {}

function wasiFS.bytesFile(bytes)
  local handle = {
    type = WASI_FILETYPE_CHARACTER_DEVICE
  }
  function handle.close() end
  return handle
end

function wasiFS.logFile(lineHandler)
  local handle = {
    type = WASI_FILETYPE_CHARACTER_DEVICE
  }
  local lineBuffer = ""

  function handle.write(arg)
    lineBuffer = lineBuffer .. arg

    while true do
      local nlPos = lineBuffer:find("\n", 1, true)
      if not nlPos then break end

      local line = lineBuffer:sub(1, nlPos - 1)
      lineBuffer = lineBuffer:sub(nlPos + 1)

      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end

      lineHandler(line)
    end

    return #arg
  end

  function handle.close() end

  return handle
end

function wasiFS.relPath(path)
  if not filesystem then
    error("Could not load filesystem support!")
  end

  return filesystem.collapse(filesystem.combine(filesystem.workingDir(), path))
end

function wasiFS.realFile(filePath, ops)
  local mode
  if ops.write then
    if ops.truncate then
      mode = ops.read and "w+b" or "wb"
    else
      mode = ops.read and "a+b" or "ab"
    end
  else
    mode = "rb"
  end

  local ioHandle = io.open(filePath, mode)
  if not ioHandle then return nil, ERR_EIO end

  local handle = {
    type = WASI_FILETYPE_REGULAR_FILE
  }

  function handle.read(count)
    local data, err = ioHandle:read(count)
    if not data then
      return nil, err or ERR_EIO
    end
    return data
  end

  function handle.write(str)
    local ok = ioHandle:write(str)
    if not ok then return nil, ERR_EIO end
    return #str
  end

  function handle.seek(offset, whence)
    local pos, err = ioHandle:seek(whence, offset)
    if not pos then
      return nil, err
    end
    return pos
  end

  function handle.close()
    ioHandle:close()
  end

  function handle.attributes()
    return filesystem.attributes(filePath)
  end

  return handle
end

function wasiFS.realDir(dirPath)
  if not filesystem then
    error("Could not load filesystem support!")
  end

  filesystem.makeDir(dirPath)

  local function fullPath(path)
    return filesystem.combine(dirPath, filesystem.collapse(path))
  end

  local handle = {
    type = WASI_FILETYPE_DIRECTORY
  }

  function handle.exists(path)
    return filesystem.exists(fullPath(path))
  end

  function handle.childType(path)
    return filesystem.isFile(fullPath(path)) and WASI_FILETYPE_REGULAR_FILE
      or WASI_FILETYPE_DIRECTORY
  end

  function handle.open(path, ops)
    path = fullPath(path)
    local parentDir = filesystem.collapse(filesystem.combine(path, ".."))
    if not filesystem.isDir(parentDir) then
      return nil, ERR_ENOENT
    end

    if ops.enforceDirectory and not filesystem.isDir(path) then
      return nil, ERR_ENOTDIR
    end
    if not filesystem.exists(path) then
      if ops.createFile then
        return wasiFS.realFile(path, ops)
      else
        return nil, ERR_ENOENT
      end
    elseif ops.failIfExists then
      return nil, ERR_EEXIST
    elseif filesystem.isDir(path) then
      return wasiFS.realDir(path)
    elseif filesystem.isFile(path) then
      return wasiFS.realFile(path, ops)
    else
      return ERR_ENOSYS -- TODO
    end
  end

  function handle.close()

  end

  function handle.attributes()
    return filesystem.attributes(dirPath)
  end

  return handle
end

function wasiFS.createFile(handle)
  local rights0 = 0
  if handle.read then
    rights0 = bor(rights0, WASI_RIGHTS_FD_READ)
  end
  if handle.write then
    rights0 = bor(rights0, WASI_RIGHTS_FD_WRITE)
  end
  return {
    type = handle.type,
    rights0 = rights0,
    rights1 = 0,
    rights_inh0 = 0,
    rights_inh1 = 0,
    handle = handle
  }
end

function wasiFS.createDirectory(handle)
  local rights0 = bor(WASI_RIGHTS_FD_READ, WASI_RIGHTS_FD_WRITE)
  return {
    type = handle.type,
    rights0 = rights0,
    rights1 = 0,
    rights_inh0 = U32_MAX,
    rights_inh1 = U32_MAX,
    handle = handle
  }
end

function wasiFS.createPreOpenDirectory(path, handle)
  local directory = wasiFS.createDirectory(handle)
  directory.path = path
  return directory
end

function wasiFS.wrapHandle(handle)
  if handle.type == WASI_FILETYPE_DIRECTORY then
    return wasiFS.createDirectory(handle)
  elseif handle.type == WASI_FILETYPE_REGULAR_FILE then
    return wasiFS.createFile(handle)
  else
    return nil, "Type not implemented"
  end
end

return wasiFS