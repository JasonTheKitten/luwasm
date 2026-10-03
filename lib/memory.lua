local bits = localRequire("lib/bits")

local PAGE_SIZE = 65536
local MEM_OOB = "Memory access out-of-bounds"

local function createBackedU32Memory(backingArr, u8Size)
  local memory = {
    u8Size = u8Size
  }
  
  function memory.u8(idx)
    if idx < 0 or idx >= u8Size then
      return false, MEM_OOB
    end

    local refByte = backingArr[math.floor(idx / 4) + 1] or 0
    local refIndex = idx % 4
    local shift = refIndex * 8
    return bits.band(bits.shr(refByte, shift), 0xFF)
  end

  function memory.writeU8(pos, val)
    if pos < 0 or pos >= u8Size then
      return false, MEM_OOB
    end

    local wordIdx = math.floor(pos / 4) + 1
    local refIndex = pos % 4
    local shift = refIndex * 8

    local currentWord = backingArr[wordIdx] or 0
    local mask = bits.bnot(bits.shl(0xFF, shift))
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
    return bits.shl(hh, 8) + lh
  end

  function memory.writeU16(pos, val)
    memory.writeU8(pos, bits.band(val, 0xFF))
    memory.writeU8(pos + 1, bits.band(bits.shr(val, 8), 0xFF))
    return true
  end

  function memory.u32(idx)
    if idx < 0 or idx + 3 >= u8Size then
      return false, MEM_OOB
    end

    if idx % 4 == 0 then
      return backingArr[math.floor(idx / 4) + 1]
    else
      local low, err = memory.u16(idx)
      if not low then return nil, err end
      local high, err = memory.u16(idx + 2)
      if not high then return nil, err end
      return bits.shl(high, 16) + low
    end
  end

  function memory.writeU32(pos, val)
    if pos < 0 or pos + 3 >= u8Size then
      return false, MEM_OOB
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
    if not ok then return err end
    local ok, err = memory.writeU32(pos + 4, hval)
    if not ok then return err end
    return true
  end

  function memory.writeU32Bytes(src, srcpos, destpos, len)
    if
      len < 0
      or srcpos < 0 or srcpos + len > #src * 4
      or destpos < 0 or destpos + len > u8Size then
      return false, MEM_OOB
    end

    local i = 0
    while i < len do
      local currSrc = srcpos + i
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

  function memory.copyMemBytes(srcMem, srcpos, destpos, len)
    local srcSize = srcMem.u8Size
    if
      len < 0
      or srcpos < 0 or (srcSize and srcpos + len > srcSize)
      or destpos < 0 or destpos + len > u8Size then
      return false, MEM_OOB
    end

    local i = 0
    while i < len do
      local currSrc = srcpos + i
      local currDest = destpos + i
      local rem = len - i

      if rem >= 4 then
        local val, err = srcMem.u32(currSrc)
        if val == false then return false, err end
        memory.writeU32(currDest, val)
        i = i + 4
      else
        local val, err = srcMem.u8(currSrc)
        if val == false then return false, err end
        memory.writeU8(currDest, val)
        i = i + 1
      end
    end
    return true
  end

  function memory.writeStringBytes(srcStr, srcpos, destpos, len)
    if
      len < 0
      or srcpos < 0 or srcpos + len > #srcStr
      or destpos < 0 or destpos + len > u8Size then
      return false, MEM_OOB
    end

    local i = 0
    while i < len do
      local currSrc = srcpos + i
      local currDest = destpos + i
      local rem = len - i

      if rem >= 4 then
        local b0, b1, b2, b3 = string.byte(srcStr, currSrc + 1, currSrc + 4)
        local val = (b0 or 0) + bits.shl(b1 or 0, 8) + bits.shl(b2 or 0, 16) + bits.shl(b3 or 0, 24)
        memory.writeU32(currDest, val)
        i = i + 4
      else
        local b = string.byte(srcStr, currSrc + 1) or 0
        memory.writeU8(currDest, b)
        i = i + 1
      end
    end
    return true
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
    -- TODO: Avoid the char and back conversion
    local val = string.char(memory.u8(pos))
    pos = pos + n
    return val
  end
  function reader:peek(n)
    assert(n == 1)
    return string.char(memory.u8(pos))
  end
  function reader:seek(idx)
    pos = idx
  end

  return reader
end

return {
  createBackedU32Memory = createBackedU32Memory,
  createNewU32Memory = createNewU32Memory,
  createMemoryReader = createMemoryReader
}