local bits = localRequire("lib/bits")
local memutils = localRequire("lib/memutils")
local driver = localRequire("driver")
local wasiFS = localRequire("lib/wasi_fs")
local bshl, band = bits.shl, bits.band
local readLenString, writeString = memutils.readLenString, memutils.writeString

local wasiLib = {}

local ERR_ENOENT = 8
local ERR_EBADF = 8
local ERR_WASI_EINVAL = 28
local ERR_ERANGE = 34
local ERR_ENOSYS = 38

local WASI_PREOPENTYPE_DIR = 0

local WASI_FILETYPE_CHARACTER_DEVICE = 2
local WASI_FILETYPE_DIRECTORY = 3
local WASI_FILETYPE_REGULAR_FILE = 4

local WASI_OFLAGS_CREAT = bshl(1, 0)
local WASI_OFLAGS_DIRECTORY = bshl(1, 1)
local WASI_OFLAGS_EXCL = bshl(1, 2)
local WASI_OFLAGS_TRUNC = bshl(1, 3)

local CLOCK_REALTIME = 0

local ERRNO_SUCCESS = 0
local ERRNO_EINVAL = 28

---@diagnostic disable-next-line: deprecated
local unpack = unpack or table.unpack

local function secondsToNanosecondsU64(seconds)
  local TWO_32 = 4294967296

  local secInt = math.floor(seconds)
  local secFrac = seconds - secInt
  local nsecExtra = math.floor(secFrac * 1e9)

  local s_hi = math.floor(secInt / TWO_32)
  local s_lo = secInt % TWO_32

  local loRaw = s_lo * 1000000000 + nsecExtra
  local hi = s_hi * 1000000000 + math.floor(loRaw / TWO_32)
  local lo = loRaw % TWO_32

  return math.floor(lo), math.floor(hi)
end

function wasiLib.create(env, fds)
  local memory, structWriter, instance
  local wasi = {
    imports = {
      ___nopcall = {}
    }
  }

  local fds = { unpack(fds)}

  function wasi.initialize(newInstance)
    memory = newInstance.exports.memory
    structWriter = memutils.newStructWriter(memory, 0)
    instance = newInstance
  end

  function wasi.imports.fd_prestat_get(fd, bufPtr)
    local dir = fds[fd + 1]
    if not dir then
      return ERR_EBADF
    elseif not dir.path then
      return ERR_WASI_EINVAL
    end

    structWriter.pos(bufPtr)
    assert(structWriter.u8(WASI_PREOPENTYPE_DIR))
    assert(structWriter.u32(#dir.path + 1))

    return 0
  end

  function wasi.imports.fd_prestat_dir_name(fd, pathPtr, pathLen)
    local dir = fds[fd + 1]
    if not dir then
      return ERR_EBADF
    elseif not dir.path then
      return ERR_WASI_EINVAL
    end

    if pathLen < #dir.path + 1 then
      return ERR_ERANGE
    end

    assert(writeString(memory, pathPtr, dir.path))
  end

  function wasi.imports.fd_fdstat_get(fd, bufPtr)
    local file = fds[fd + 1]
    if not file then
      return ERR_EBADF
    end

    structWriter.pos(bufPtr)
    assert(structWriter.u8(file.type))
    -- TODO: Correct flags
    assert(structWriter.u16(0))
    assert(structWriter.u64(file.rights0, file.rights1))
    assert(structWriter.u64(file.rights_inh0, file.rights_inh1))

    return 0
  end

  function wasi.imports.path_filestat_get(fd, flags, pathPtr, pathLen, bufPtr)
    local dir = fds[fd + 1]
    if not dir then
      return ERR_EBADF
    elseif not dir.type == WASI_FILETYPE_DIRECTORY then
      return ERR_WASI_EINVAL
    end

    local dirHandle = dir.handle
    local path = readLenString(memory, pathPtr, pathLen)
    if not dirHandle.exists(path) then
      return ERR_ENOENT
    end

    assert(memory.fillMemBytes(bufPtr, 0, 64))
    assert(memory.writeU8(bufPtr + 16, dirHandle.childType(path)))
    
    return 0
  end

  function wasi.imports.path_open(
    dirfd, dirflags, pathPtr, pathLen, oFlags,
    fsRightsBase_l, fsRightsBase_h,
    fsRightsInheriting_l, fsRightsInheriting_h,
    fsFlags, fd
  )
    local dir = fds[dirfd + 1]
    if not dir then
      return ERR_EBADF
    elseif not dir.type == WASI_FILETYPE_DIRECTORY then
      return ERR_WASI_EINVAL
    end

    local ops = {
      createFile = band(oFlags, WASI_OFLAGS_CREAT) ~= 0,
      enforceDirectory = band(oFlags, WASI_OFLAGS_DIRECTORY) ~= 0,
      failIfExists = band(oFlags, WASI_OFLAGS_EXCL) ~= 0,
      truncate = band(oFlags, WASI_OFLAGS_TRUNC) ~= 0
    }
    local path = readLenString(memory, pathPtr, pathLen)
    local handle, err = dir.handle.open(path, ops)
    if not handle then return err end

    local newFd = #fds
    fds[newFd + 1] = wasiFS.wrapHandle(handle)

    assert(memory.writeU32(fd, newFd))
    return 0
  end

  function wasi.imports.fd_fdstat_set_flags(fd)
    return ERR_ENOSYS
  end

  function wasi.imports.fd_write(fd, iovsPtr, iovsLen, nwrittenPtr)
    local file = fds[fd + 1]
    if not file then
      return ERR_EBADF
    end

    if
      file.type ~= WASI_FILETYPE_REGULAR_FILE
      and file.type ~= WASI_FILETYPE_CHARACTER_DEVICE
    then
      return ERR_WASI_EINVAL
    end

    local totalWritten = 0

    for i = 0, iovsLen - 1 do
      local ciovecPtr = iovsPtr + (i * 8)
      local bufPtr = assert(memory.u32(ciovecPtr))
      local bufLen = assert(memory.u32(ciovecPtr + 4))

      if bufLen > 0 then
        local data = readLenString(memory, bufPtr, bufLen)

        local written, err = file.handle.write(data)
        if not written then return err end

        local bytesWritten = (type(written) == "number") and written or #data
        totalWritten = totalWritten + bytesWritten
      end
    end

    assert(memory.writeU32(nwrittenPtr, totalWritten))
    return 0
  end

  function wasi.imports.fd_close(fd)
    local entity = fds[fd + 1]
    if not entity then
      return ERR_EBADF
    end
    entity.handle.close()
    fds[fd + 1] = nil

    return 0
  end

  function wasi.imports.path_create_directory(fd, pathPtr, pathLen)
    return ERR_ENOENT
  end

  function wasi.imports.environ_get(environPtr, environBufPtr)
    local currentBufPtr = environBufPtr
    local currentArrPtr = environPtr

    for _, entry in ipairs(env) do
      assert(memory.writeU32(currentArrPtr, currentBufPtr))

      local writeLen = writeString(memory, currentBufPtr, entry)

      currentBufPtr = currentBufPtr + writeLen
      currentArrPtr = currentArrPtr + 4
    end

    assert(memory.writeU32(currentArrPtr, 0))

    return 0
  end

  function wasi.imports.environ_sizes_get(countPtr, sizePtr)
    local totalBytes = 0
    for _, entry in ipairs(env) do
      totalBytes = totalBytes + #entry + 1
    end
    assert(memory.writeU32(countPtr, #env))
    assert(memory.writeU32(sizePtr, totalBytes))

    return 0
  end

  function wasi.imports.clock_time_get(clockId, _, _, timePtr)
    if clockId ~= CLOCK_REALTIME then
      return ERR_ENOSYS
    end
    local nowSeconds = driver.time()

    local lo, hi = secondsToNanosecondsU64(nowSeconds)
    local ok = memory.writeU64(timePtr, lo, hi)

    if not ok then
      return ERRNO_EINVAL
    end

    return ERRNO_SUCCESS
  end

  function wasi.imports.___nopcall.proc_exit(x)
    return instance.exit(x)
  end

  return wasi
end

return wasiLib