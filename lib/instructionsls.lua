local conversions = localRequire("lib/numbers/conversions")
local codeparser = localRequire("lib/codeparser")
local readMemArg = codeparser.readMemArg

local function load32(size, signed)
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i, err = stack.popI32()
    if not i then return nil, err end

    local val, err = memory[size](i + pos)
    if not val then return nil, err end

    if signed then
      if size == "u8" and val >= 0x80 then
        val = val + 0xFFFFFF00
      elseif size == "u16" and val >= 0x8000 then
        val = val + 0xFFFF0000
      end
    end

    stack.pushI32(val)
    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function store32(sizeMethod)
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local val, err = stack.popI32()
    if not val then return nil, err end
    local i, err = stack.popI32()
    if not i then return nil, err end
    memory[sizeMethod](i + pos, val)

    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function load64(size, signed)
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i, err = stack.popI32()
    if not i then return nil, err end

    local low, high
    if size == "u64" then
      low, high = memory["u64"](i + pos)
    else
      local val = memory[size](i + pos)
      low, high = val, 0
      if signed then
        if size == "u8" and val >= 0x80 then
          low = val + 0xFFFFFF00
          high = 0xFFFFFFFF
        elseif size == "u16" and val >= 0x8000 then
          low = val + 0xFFFF0000
          high = 0xFFFFFFFF
        elseif size == "u32" and val >= 0x80000000 then
          high = 0xFFFFFFFF
        end
      end
    end

    stack.pushI64(low, high)
    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function store64(sizeMethod)
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local low, high = stack.popI64()
    if not low then return nil, high end
    local i, err = stack.popI32()
    if not i then return nil, err end

    if sizeMethod == "writeU64" then
      memory["writeU64"](i + pos, low, high)
    else
      memory[sizeMethod](i + pos, low)
    end

    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function loadF32()
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i, err = stack.popI32()
    if not i then return nil, err end

    local bits = memory["u32"](i + pos)
    local val = conversions.u32ToF32(bits)

    stack.pushF32(val)
    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function storeF32()
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local val, err = stack.popF32()
    if not val then return nil, err end
    local i, err = stack.popI32()
    if not i then return nil, err end

    local bits = conversions.f32ToU32(val)
    memory["writeU32"](i + pos, bits)

    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function loadF64()
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i, err = stack.popI32()
    if not i then return nil, err end

    local low, high = memory["u64"](i + pos)
    local val = conversions.u64ToF64(low, high)

    stack.pushF64(val)
    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

local function storeF64()
  local inst = {}
  function inst.evaluate(_, context, align, memidx, pos)
    if not align then return nil, memidx end
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local val, err = stack.popF64()
    if not val then return nil, err end
    local i, err = stack.popI32()
    if not i then return nil, err end

    local low, high = conversions.f64ToU64(val)
    memory["writeU64"](i + pos, low, high)

    return true
  end

  function inst.collectArgs(stream)
    return readMemArg(stream)
  end

  return inst
end

return {
  load32 = load32,
  store32 = store32,
  load64 = load64,
  store64 = store64,
  loadF32 = loadF32,
  storeF32 = storeF32,
  loadF64 = loadF64,
  storeF64 = storeF64
}