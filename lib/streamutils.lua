local bits = localRequire("lib/bits")

local REACHED_EOF = "Reached end-of-file marker"
local LARGE_INT = "Int value too large"

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

local function readLEB(stream, n)
  local low, high = 0, 0
  local shift = 0

  for _ = 1, math.ceil(n / 7) do
    local byte = readU8(stream)
    local payload = byte >= 128 and (byte - 128) or byte

    if n < 33 or shift < 28 then
      low = low + payload * (2 ^ shift)
    elseif shift == 28 then
      low = low + (payload % 16) * (2 ^ 28)
      high = high + math.floor(payload / 16)
    else
      high = high + payload * (2 ^ (shift - 32))
    end

    shift = shift + 7
    if byte < 128 then
      return low, high, byte, shift
    end
  end

  return false, LARGE_INT
end

local function readInt(stream, n)
  local low, high = readLEB(stream, n)
  if not low then return false, LARGE_INT end
  if n < 33 then return low end
  return low, high
end

local function readSInt(stream, n)
  local low, high, byte, shift = readLEB(stream, n)
  if not low then return false, LARGE_INT end

  if byte >= 64 then
    if n < 33 then
      low = low - (2 ^ shift)
    elseif shift <= 32 then
      low = low - (2 ^ shift)
      if low < 0 then
        low = low + 0x100000000
        high = (high - 1) % 0x100000000
      end
    else
      high = high - (2 ^ (shift - 32))
      if high < 0 then
        high = high + 0x100000000
      end
    end
  end

  if n < 33 then return low end
  return low, high
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
  readSInt = readSInt,
  readArr = readArr,
  wrapStream = wrapStream,
  readList = readList
}