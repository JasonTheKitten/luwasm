local function readLenString(memory, ptr, len)
  local bytes = {}
  for i = 0, len - 1 do
    local b, err = memory.u8(ptr + i)
    if not b then return nil, err end
    --if b == 0 then break end
    table.insert(bytes, string.char(b))
  end
  return table.concat(bytes)
end

local function readCString(memory, ptr)
  local bytes = {}
  local i = 0
  while true do
    local b, err = memory.u8(ptr + i)
    if not b then return nil, err end
    if b == 0 then break end
    table.insert(bytes, string.char(b))
    i = i + 1
  end
  return table.concat(bytes)
end

local function writeString(memory, ptr, val)
  local ok, err
  for i = 1, #val do
    ok, err = memory.writeU8(ptr + i - 1, val:byte(i))
    if not ok then return nil, err end
  end
  if not ok then return nil, err end

  return #val
end

local function newStructWriter(memory, pos)
  local align = true
  local structWriter = {}
  local function alignToB(i)
    local mod = pos % i
    if mod == 0 then return end
    local ok, err = memory.fillMemBytes(pos, 0, i - mod)
    pos = pos + i - mod
    return ok, err
  end
  local function alignTo(i)
    return alignToB(i / 8)
  end
  structWriter.alignTo = alignTo
  function structWriter.align(a)
    align = a
  end
  function structWriter.pos(p)
    if p then pos = p end
    return pos
  end
  function structWriter.u8(v)
    local ok, err = memory.writeU8(pos, v)
    pos = pos + 1
    return ok, err
  end
  function structWriter.u16(v)
    if align then
      alignToB(2)
    end
    local ok, err = memory.writeU16(pos, v)
    pos = pos + 2
    return ok, err
  end
  function structWriter.u32(v)
    if align then
      alignToB(4)
    end
    local ok, err = memory.writeU32(pos, v)
    pos = pos + 4
    return ok, err
  end
  function structWriter.u64(lv, hv)
    if align then
      alignToB(8)
    end
    local ok, err = memory.writeU64(pos, lv, hv)
    pos = pos + 8
    return ok, err
  end
  function structWriter.string(value)
    local len, err = writeString(memory, pos, value)
    if not len then return nil, err end
    pos = pos + len
  end

  return structWriter
end

return {
  readLenString = readLenString,
  readCString = readCString,
  writeString = writeString,
  newStructWriter = newStructWriter
}