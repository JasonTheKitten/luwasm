local bits = localRequire("lib/bits")
local memutils = localRequire("lib/memutils")
local driver = localRequire("driver")
local wasiFS = localRequire("lib/wasi_fs")
local bshl, band = bits.shl, bits.band
local readLenString, writeString = memutils.readLenString, memutils.writeString

local wasiLib = {}

local U32_MASK = 0x100000000

local ERR_EIO = 5
local ERR_ENOENT = 44
local ERR_EBADF = 8
local ERR_EINVAL = 28
local ERR_ERANGE = 68
local ERR_ENOSYS = 52

local WASI_PREOPENTYPE_DIR = 0

local WASI_FILETYPE_CHARACTER_DEVICE = 2
local WASI_FILETYPE_DIRECTORY = 3
local WASI_FILETYPE_REGULAR_FILE = 4

local WASI_OFLAGS_CREAT = bshl(1, 0)
local WASI_OFLAGS_DIRECTORY = bshl(1, 1)
local WASI_OFLAGS_EXCL = bshl(1, 2)
local WASI_OFLAGS_TRUNC = bshl(1, 3)

local WASI_RIGHTS_FD_READ = bshl(1, 1)
local WASI_RIGHTS_FD_WRITE = bshl(1, 6)

local CLOCK_REALTIME = 0

local ERRNO_SUCCESS = 0
local ERRNO_EINVAL = 28

---@diagnostic disable-next-line: deprecated
local unpack = unpack or table.unpack

local function toU64Nanos(sec, nsec)
  if not nsec then
    local secInt = math.floor(sec)
    nsec = math.floor((sec - secInt) * 1e9)
    sec = secInt
  end

  local TWO_32 = 4294967296
  local s_hi = math.floor(sec / TWO_32)
  local s_lo = sec % TWO_32

  local loRaw = s_lo * 1000000000 + nsec
  local hi = s_hi * 1000000000 + math.floor(loRaw / TWO_32)
  local lo = loRaw % TWO_32

  return math.floor(lo), math.floor(hi)
end

local function lfsModeToWasiType(mode)
  if mode == "file" then
    return 4
  elseif mode == "directory" then
    return 3
  elseif mode == "link" then
    return 7
  elseif mode == "char device" then
    return 2
  elseif mode == "block device" then
    return 1
  end
  return 0
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
      return ERR_EINVAL
    end

    structWriter.pos(bufPtr)
    assert(structWriter.u8(WASI_PREOPENTYPE_DIR))
    assert(structWriter.u32(#dir.path))

    return 0
  end

  function wasi.imports.fd_prestat_dir_name(fd, pathPtr, pathLen)
    local dir = fds[fd + 1]
    if not dir then
      return ERR_EBADF
    elseif not dir.path then
      return ERR_EINVAL
    end

    if pathLen < #dir.path then
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
    elseif dir.type ~= WASI_FILETYPE_DIRECTORY then
      return ERR_EINVAL
    end

    local path = readLenString(memory, pathPtr, pathLen)
    if not dir.handle.exists(path) then
      return ERR_ENOENT
    end

    local attr = dir.handle.attributes(path)
    if not attr then
      return ERR_ENOENT
    end

    structWriter.pos(bufPtr)

    local atimLo, atimHi = toU64Nanos(attr.atime, attr.atimeNanos)
    local mtimLo, mtimHi = toU64Nanos(attr.mtime, attr.mtimeNanos)
    local ctimLo, ctimHi = toU64Nanos(attr.ctime, attr.ctimeNanos)

    local size = attr.size
    local sizeLo = size % U32_MASK
    local sizeHi = math.floor(size / U32_MASK)

    assert(structWriter.u64(attr.dev, 0))
    assert(structWriter.u64(attr.ino, 0))
    assert(structWriter.u8(lfsModeToWasiType(attr.mode)))
    assert(structWriter.u64(attr.nlink, 0))
    assert(structWriter.u64(sizeLo, sizeHi))
    assert(structWriter.u64(atimLo, atimHi))
    assert(structWriter.u64(mtimLo, mtimHi))
    assert(structWriter.u64(ctimLo, ctimHi))

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
    elseif dir.type ~= WASI_FILETYPE_DIRECTORY then
      return ERR_EINVAL
    end

    local ops = {
      createFile = band(oFlags, WASI_OFLAGS_CREAT) ~= 0,
      enforceDirectory = band(oFlags, WASI_OFLAGS_DIRECTORY) ~= 0,
      failIfExists = band(oFlags, WASI_OFLAGS_EXCL) ~= 0,
      truncate = band(oFlags, WASI_OFLAGS_TRUNC) ~= 0,

      read = band(fsRightsBase_l, WASI_RIGHTS_FD_READ) ~= 0,
      write = band(fsRightsBase_l, WASI_RIGHTS_FD_WRITE) ~= 0
    }

    local path = readLenString(memory, pathPtr, pathLen)
    local handle, err = dir.handle.open(path, ops)
    if not handle then
      return err
    end

    local newFd = 0
    while fds[newFd + 1] ~= nil do
      newFd = newFd + 1
    end

    fds[newFd + 1] = wasiFS.wrapHandle(handle)

    assert(memory.writeU32(fd, newFd))
    return 0
  end

  function wasi.imports.fd_fdstat_set_flags(fd)
    return ERR_ENOSYS
  end

  function wasi.imports.fd_read(fd, iovsPtr, iovsLen, nreadPtr)
    local file = fds[fd + 1]
    if not file then
      return ERR_EBADF
    end

    if
      file.type ~= WASI_FILETYPE_REGULAR_FILE
      and file.type ~= WASI_FILETYPE_CHARACTER_DEVICE
    then
      return ERR_EINVAL
    end

    if band(file.rights0, WASI_RIGHTS_FD_READ) == 0 then
      return ERR_EBADF
    end

    local totalRead = 0

    for i = 0, iovsLen - 1 do
      local iovecPtr = iovsPtr + (i * 8)
      local bufPtr = assert(memory.u32(iovecPtr))
      local bufLen = assert(memory.u32(iovecPtr + 4))

      if bufLen > 0 then
        local data, err = file.handle.read(bufLen)
        if not data then
          return err
        end

        local len = #data

        if len > 0 then
          assert(memutils.writeString(memory, bufPtr, data))
          totalRead = totalRead + len
        end

        if len < bufLen then
          break
        end
      end
    end

    assert(memory.writeU32(nreadPtr, totalRead))
    return 0
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
      return ERR_EINVAL
    end

    if band(file.rights0, WASI_RIGHTS_FD_WRITE) == 0 then
      return ERR_EBADF
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

  function wasi.imports.fd_seek(fd, offsetLo, offsetHi, whence, newoffsetPtr)
    local file = fds[fd + 1]
    if not file then
      return ERR_EBADF
    end

    if
      file.type ~= WASI_FILETYPE_REGULAR_FILE
      and file.type ~= WASI_FILETYPE_CHARACTER_DEVICE
    then
      return ERR_EINVAL
    end

    if band(file.rights0, WASI_RIGHTS_FD_READ) == 0
      and band(file.rights0, WASI_RIGHTS_FD_WRITE) == 0
    then
      return ERR_EBADF
    end

    local whenceName
    if whence == 0 then
      whenceName = "set"
    elseif whence == 1 then
      whenceName = "cur"
    elseif whence == 2 then
      whenceName = "end"
    else
      return ERR_EINVAL
    end

    local offset = offsetLo + offsetHi * 0x100000000

    if offsetHi >= 0x80000000 then
      offset = offset - 0x10000000000000000
    end

    local newOffset = file.handle.seek(offset, whenceName)
    if not newOffset then
      return ERR_EIO
    end

    local TWO_32 = 4294967296
    local newLo = newOffset % TWO_32
    local newHi = math.floor(newOffset / TWO_32)

    assert(memory.writeU64(newoffsetPtr, newLo, newHi))
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

    local lo, hi = toU64Nanos(nowSeconds)
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