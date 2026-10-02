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

local function wrap_stream(stream)
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

local function readSection(stream)
  local type, err = readU1(stream)
  if not type then return false, err end
  local len, err = readInt(stream, 32)
  if not len then return false, err end

  print(type.." "..len)
  -- TODO
  readArr(stream, readU1, len)

  return {
    type = type
  }
end

local function readNextSection(stream, sections, expected)
  local section, err = readSection(stream)
  if not section then return false, err end
  while section.type == 0 do
    table.insert(sections, section)
    section, err = readSection(stream)
    if not section then return false, err end
  end
  table.insert(sections, section)
  if expected ~= nil and expected ~= section.type then
    return false, "Expected section type " .. expected .. ", got " .. section.type
  end
  return section
end

local function maybeReadNextSection(stream, sections, expected)
  while stream:peek() == 0 do
    local section, err = readSection(stream)
    if not section then return nil, false, err end
    table.insert(sections, section)
  end

  if (stream:peek() ~= expected) then
    return nil, true
  end

  local section, err = readSection(stream)
  if not section then return false, err end
  table.insert(sections, section)
  assert(expected == section.type)
  return section, true
end

local function readModule(stream)
  stream = wrap_stream(stream)

  local magic, err = readU4(stream)
  if not magic then return false, err end
  if magic ~= 0x0061736D then
    return false, "Magic signature does not match"
  end

  local version, err = readU4(stream)
  if not version then return false, err end
  if version ~= 0x01000000 then
    return false, "Only version 1 is supported"
  end

  -- TODO: Handle custom sections
  local sections = {}
  local typeSection, err = readNextSection(stream, sections, 1)
  if not typeSection then return false, err end
  local importSection, err = readNextSection(stream, sections, 2)
  if not importSection then return false, err end
  local funcSection, err = readNextSection(stream, sections, 3)
  if not funcSection then return false, err end
  local tableSection, err = readNextSection(stream, sections, 4)
  if not tableSection then return false, err end
  local memSection, err = readNextSection(stream, sections, 5)
  if not memSection then return false, err end
  local tagSection, err = readNextSection(stream, sections, 13)
  if not tagSection then return false, err end
  local globalSection, err = readNextSection(stream, sections, 6)
  if not globalSection then return false, err end
  local exportSection, err = readNextSection(stream, sections, 7)
  if not exportSection then return false, err end
  local startSection, ok, err = maybeReadNextSection(stream, sections, 8)
  if not ok then return false, err end
  local elemSection, err = readNextSection(stream, sections, 9)
  if not elemSection then return false, err end
  local dataCntSection, ok, err = maybeReadNextSection(stream, sections, 12)
  if not ok then return false, err end
  local codeSection, err = readNextSection(stream, sections, 10)
  if not codeSection then return false, err end
  local dataSection, err = readNextSection(stream, sections, 11)
  if not dataSection then return false, err end
  local _, ok, err = maybeReadNextSection(stream, sections, 0)
  if not ok then return err end

  return {
    sections = sections,
    typeSection = typeSection,
    importSection = importSection,
    funcSection = funcSection,
    tableSection = tableSection,
    memSection = memSection,
    tagSection = tagSection,
    globalSection = globalSection,
    exportSection = exportSection,
    startSection = startSection,
    elemSection = elemSection,
    dataCntSection = dataCntSection,
    codeSection = codeSection,
    dataSection = dataSection
  }
end

return {
  readModule = readModule
}