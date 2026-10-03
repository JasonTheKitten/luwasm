local bits = localRequire("lib/bits")

local REACHED_EOF = "Reached end-of-file marker"

local function readU8(stream)
  local v = stream:read(1)
  if not v then return false, REACHED_EOF end
  return v:byte()
end

local function readU16(stream)
  local b1, err = readU8(stream)
  if not b1 then return nil, err end
  local b2, err = readU8(stream)
  if not b2 then return nil, err end
  return bits.shl(b1, 8) + b2
end

local function read32(stream)
  local b1, err = readU16(stream)
  if not b1 then return nil, err end
  local b2, err = readU16(stream)
  if not b2 then return nil, err end
  return bits.shl(b1, 16) + b2
end

-- TODO: This may be wrong for 64 bit values due to Lua quirks
-- Need to refactor to return low and high halves
local function readInt(stream, n)
  local value = 0
  local mul = 1
  for i = 1, n / 7 do
    local byte = readU8(stream)
    if byte >= 128 then
      value = value + (byte - 128) * mul
    else
      value = value + byte * mul
      return value
    end
    mul = mul * 128
  end

  return false, "Int value too large"
end

local function readArr(stream, f, num)
  local tbl = {}
  for _ = 1, num do
    local res, err = f(stream)
    if not res then return res, err end
    table.insert(tbl, res)
  end
  return tbl
end

local function wrapStream(stream)
  local wrapped = {
    _stream = stream,
    _pos = 0,
    _pushback = nil
  }

  function wrapped:read(n)
    assert(n == 1)
    self._pos = self._pos + n
    if self._pushback then
      local val = self._pushback
      self._pushback = nil
      return val
    end
    return self._stream:read(n)
  end

  function wrapped:peek()
    if self._pushback then
      return self._pushback:byte()
    end
    local val = self._stream:read(1)
    if not val then return nil end
    self._pushback = val
    return val:byte()
  end

  function wrapped:pos()
    return self._pos
  end

  return wrapped
end

local function readList(stream, func)
  local len, err = readInt(stream, 32)
  if not len then return nil, err end
  return readArr(stream, func, len)
end

return {
  readU8 = readU8,
  readU16 = readU16,
  readU32 = read32,
  readInt = readInt,
  readArr = readArr,
  wrapStream = wrapStream,
  readList = readList
}