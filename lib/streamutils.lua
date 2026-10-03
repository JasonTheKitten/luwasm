local bits = localRequire("lib/bits")

local REACHED_EOF = "Reached end-of-file marker"

local function readU1(stream)
  local v = stream:read(1)
  if not v then return false, REACHED_EOF end
  return v:byte()
end

local function readU2(stream)
  local b1, err = readU1(stream)
  if not b1 then return false, err end
  local b2, err = readU1(stream)
  if not b2 then return false, err end
  return bits.shl(b1, 8) + b2
end

local function readU4(stream)
  local b1, err = readU2(stream)
  if not b1 then return false, err end
  local b2, err = readU2(stream)
  if not b2 then return false, err end
  return bits.shl(b1, 16) + b2
end

-- TODO: This may be wrong for 64 bit values due to Lua quirks
-- Need to refactor to return low and high halves
local function readInt(stream, n)
  local value = 0
  local mul = 1
  for i = 1, n / 7 do
    local byte = readU1(stream)
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
  if not len then return false, err end
  return readArr(stream, func, len)
end

return {
  readU1 = readU1,
  readU2 = readU2,
  readU4 = readU4,
  readInt = readInt,
  readArr = readArr,
  wrapStream = wrapStream,
  readList = readList
}