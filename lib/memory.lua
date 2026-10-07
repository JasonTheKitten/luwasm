local bits = localRequire("lib/bits")

local PAGE_SIZE = 65536
local MEM_OOB = "Memory access out-of-bounds"
local MAX_PAGES = 65536

local function createBackedU32Memory(backingArr, u8Size)
  local memory = {
    u8Size = u8Size
  }

  function memory.u8(idx)
    if idx < 0 or idx >= u8Size then
      return nil, MEM_OOB
    end

    local refByte = backingArr[math.floor(idx / 4) + 1] or 0
    local refIndex = idx % 4
    local shift = refIndex * 8
    return bits.band(bits.shr(refByte, shift), 0xFF)
  end

  function memory.writeU8(pos, val)
    if pos < 0 or pos >= u8Size then
      return nil, MEM_OOB
    end

    local wordIdx = math.floor(pos / 4) + 1
    local refIndex = pos % 4
    local shift = refIndex * 8

    local currentWord = backingArr[wordIdx] or 0
    local mask = bits.bnot32(bits.shl(0xFF, shift))
    local cleared = bits.band(currentWord, mask)
    local shiftedVal = bits.shl(bits.band(val, 0xFF), shift)

    backingArr[wordIdx] = bits.bor(cleared, shiftedVal)
    return true
  end

  function memory.u16(idx)
    local lh, err = memory.u8(idx)
    if not lh then return nil, err end
    local hh, err = memory.u8(idx + 1)
    if not hh then return nil, err end
    return hh * 0x100 + lh
  end

  function memory.writeU16(pos, val)
    memory.writeU8(pos, bits.band(val, 0xFF))
    memory.writeU8(pos + 1, bits.band(bits.shr(val, 8), 0xFF))
    return true
  end

  function memory.u32(idx)
    if idx < 0 or idx + 3 >= u8Size then
      print("OOB", string.format("0x%02X", idx))
      return nil, MEM_OOB
    end

    if idx % 4 == 0 then
      return backingArr[math.floor(idx / 4) + 1]
    else
      local low, err = memory.u16(idx)
      if not low then return nil, err end
      local high, err = memory.u16(idx + 2)
      if not high then return nil, err end
      return high * 0x10000 + low
    end
  end

  function memory.writeU32(pos, val)
    if pos < 0 or pos + 3 >= u8Size then
      print("OOB", string.format("0x%02X", pos))
      return nil, MEM_OOB
    end

    if pos % 4 == 0 then
      backingArr[math.floor(pos / 4) + 1] = val
    else
      memory.writeU16(pos, bits.band(val, 0xFFFF))
      memory.writeU16(pos + 2, bits.band(bits.shr(val, 16), 0xFFFF))
    end
    return true
  end

  function memory.u64(idx)
    local lh, err = memory.u32(idx)
    if not lh then return nil, err end
    local hh, err = memory.u32(idx + 4)
    if not hh then return nil, err end
    return lh, hh
  end

  function memory.writeU64(pos, lval, hval)
    local ok, err = memory.writeU32(pos, lval)
    if not ok then return nil, err end
    local ok, err = memory.writeU32(pos + 4, hval or 0)
    if not ok then return nil, err end
    return true
  end

  function memory.fillMemBytes(destpos, val, len)
    if len < 0 or destpos < 0 or destpos + len > u8Size then
      return nil, MEM_OOB
    end

    local b = bits.band(val, 0xFF)
    local val32 = b + bits.shl(b, 8) + bits.shl(b, 16) + bits.shl(b, 24)

    local i = 0
    while i < len and (destpos + i) % 4 ~= 0 do
      memory.writeU8(destpos + i, b)
      i = i + 1
    end

    while len - i >= 4 do
      memory.writeU32(destpos + i, val32)
      i = i + 4
    end

    while i < len do
      memory.writeU8(destpos + i, b)
      i = i + 1
    end
    return true
  end

  function memory.copyMemBytes(srcMem, srcpos, destpos, len)
    local srcSize = srcMem.u8Size
    if
      len < 0
      or srcpos < 0 or srcpos + len > srcSize
      or destpos < 0 or destpos + len > u8Size
    then
      return nil, MEM_OOB
    end

    if srcMem == memory and destpos > srcpos then
      local i = len - 1
      while i >= 0 do
        local byteVal, err = srcMem.u8(srcpos + i)
        if byteVal == nil then return nil, err end
        memory.writeU8(destpos + i, byteVal)
        i = i - 1
      end
    else
      local i = 0
      while i < len do
        local currSrc = srcpos + i
        local currDest = destpos + i
        local rem = len - i

        if rem >= 4 and currSrc % 4 == 0 and currDest % 4 == 0 then
          local val32, err = srcMem.u32(currSrc)
          if val32 == nil then return nil, err end
          memory.writeU32(currDest, val32)
          i = i + 4
        else
          local byteVal, err = srcMem.u8(currSrc)
          if byteVal == nil then return nil, err end
          memory.writeU8(currDest, byteVal)
          i = i + 1
        end
      end
    end
    return true
  end

  function memory.writeU32Bytes(src, srcpos, destpos, len)
    if
      len < 0
      or srcpos < 1 or (srcpos - 1) + len > #src * 4
      or destpos < 0 or destpos + len > u8Size
    then
      return nil, MEM_OOB
    end

    local i = 0
    while i < len do
      local currSrc = (srcpos + i) - 1
      local currDest = destpos + i
      local rem = len - i

      if rem >= 4 then
        local val
        if currSrc % 4 == 0 then
          local wordIdx = math.floor(currSrc / 4) + 1
          val = src[wordIdx] or 0
        else
          local wordIdx = math.floor(currSrc / 4) + 1
          local refIndex = currSrc % 4
          local w1 = src[wordIdx] or 0
          local w2 = src[wordIdx + 1] or 0
          val = bits.bor(
            bits.shr(w1, refIndex * 8),
            bits.shl(w2, (4 - refIndex) * 8)
          )
        end

        memory.writeU32(currDest, val)
        i = i + 4
      else
        local wordIdx = math.floor(currSrc / 4) + 1
        local refIndex = currSrc % 4
        local word = src[wordIdx] or 0
        local byteVal = bits.band(bits.shr(word, refIndex * 8), 0xFF)
        memory.writeU8(currDest, byteVal)
        i = i + 1
      end
    end
    return true
  end

  function memory.raw()
    return backingArr
  end

  function memory.sizeBytes()
    return math.floor(u8Size)
  end

  function memory.sizePages()
    return math.floor(u8Size / PAGE_SIZE)
  end

  function memory.growPages(deltaPages, maxPages)
    local oldPages = math.floor(u8Size / PAGE_SIZE)
    if deltaPages == 0 then return oldPages end

    local newPages = oldPages + deltaPages
    local cap = maxPages or MAX_PAGES
    if newPages > cap or newPages > MAX_PAGES then
      return -1
    end

    local newU8Size = newPages * PAGE_SIZE
    local newU32Size = math.ceil(newU8Size / 4)

    for i = #backingArr + 1, newU32Size do
      backingArr[i] = 0
    end

    u8Size = newU8Size
    memory.u8Size = u8Size
    return oldPages
  end

  return memory
end

local function createNewU32Memory(pages)
  local u8Size = pages * PAGE_SIZE
  local u32Size = math.ceil(u8Size / 4)

  local backingArr = {}
  for i=1, u32Size do
    backingArr[i] = 0
  end

  return createBackedU32Memory(backingArr, u8Size)
end

local function createMemoryReader(memory)
  local reader = {}
  local pos = 0

  function reader:read(n)
    assert(n == 1)
    local b, err = memory.u8(pos)
    if not b then return nil, err end
    local val = string.char(b)
    pos = pos + n
    return val
  end
  function reader:peek(n)
    assert(n == 1)
    local b = memory.u8(pos)
    if not b then return nil end
    return b
  end
  function reader:seek(idx)
    pos = idx
  end
  function reader:pos()
    return pos
  end

  return reader
end

return {
  createBackedU32Memory = createBackedU32Memory,
  createNewU32Memory = createNewU32Memory,
  createMemoryReader = createMemoryReader
}