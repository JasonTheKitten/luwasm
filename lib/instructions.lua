local streamutils = localRequire("lib/streamutils")
local codeparser = localRequire("lib/codeparser")
local numbers = localRequire("lib/numbers")
local valparser = localRequire("lib/valparser")

local readSInt = streamutils.readSInt
local readMemArg = codeparser.readMemArg
local readBlockType, readFuncIdx, readMemIdx, readGlobalIdx, readDataIdx, readLocalIdx, readLabelIdx
  = valparser.readBlockType, valparser.readFuncIdx, valparser.readMemIdx, valparser.readGlobalIdx,
  valparser.readDataIdx, valparser.readLocalIdx, valparser.readLabelIdx

local STACK_EMPTY = "Stack is empty"
local NO_JUMP_POS = "No recorded jump pos"

local SYMBOL_BR = {}
local SYMBOL_RETURN = {}

local instr = {}

local function writeInt(tbl, pos, bits, value)
  for i=1, bits / 7 do
    if value >= 128 then
      tbl[pos + i - 1] = value % 128
      -- TODO: Use // if newer Lua
      value = math.floor(value / 128)
    else
      tbl[pos + i - 1] = value
      return pos + i
    end
  end

  return false, "Int too large to fit in bits"
end

local function unop32(op)
  local inst = {}
  function inst.evaluate(_, context)
    local stack = context.stack
    local c = table.remove(stack, #stack)
    if not c then return nil, STACK_EMPTY end
    local res, err = op(c)
    if res == nil then return nil, err end
    stack[#stack+1] = res
    return true
  end
  function inst.skip()
    return true
  end
  return inst
end

local function binop32(op)
  local inst = {}
  function inst.evaluate(_, context)
    local stack = context.stack
    local c2 = table.remove(stack, #stack)
    if not c2 then return nil, STACK_EMPTY end
    local c1 = table.remove(stack, #stack)
    if not c1 then return nil, STACK_EMPTY end
    local res, err = op(c1, c2)
    if res == nil then return nil, err end
    stack[#stack+1] = res
    return true
  end
  function inst.skip()
    return true
  end
  return inst
end

local function testop32(op)
  return unop32(function(a)
    local val, err = op(a)
    if val == nil then return nil, err end
    return val and 1 or 0
  end)
end

local function relop32(op)
  return binop32(function(a, b)
    local val, err = op(a, b)
    if val == nil then return nil, err end
    return val and 1 or 0
  end)
end

local function load32(size, signed)
  local inst = {}
  function inst.evaluate(stream, context)
    local _, memidx, pos = readMemArg(stream)
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i = table.remove(stack, #stack)
    if not i then return nil, STACK_EMPTY end

    local val = memory[size](i + pos)

    if signed then
      if size == "u8" and val >= 0x80 then
        val = val + 0xFFFFFF00
      elseif size == "u16" and val >= 0x8000 then
        val = val + 0xFFFF0000
      end
    end

    stack[#stack + 1] = val
    return true
  end

  function inst.skip(stream)
    return readMemArg(stream)
  end

  return inst
end

local function store32(sizeMethod)
  local inst = {}
  function inst.evaluate(stream, context)
    local _, memidx, pos = readMemArg(stream)
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local val = table.remove(stack, #stack)
    if not val then return nil, STACK_EMPTY end
    local i = table.remove(stack, #stack)
    if not i then return nil, STACK_EMPTY end
    memory[sizeMethod](i + pos, val)

    return true
  end
  function inst.skip(stream)
    return readMemArg(stream)
  end

  return inst
end

local function load64(size, signed)
  local inst = {}
  function inst.evaluate(stream, context)
    local _, memidx, pos = readMemArg(stream)
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local i = table.remove(stack, #stack)
    if not i then return nil, STACK_EMPTY end

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

    stack[#stack + 1] = low
    stack[#stack + 1] = high
    return true
  end

  function inst.skip(stream)
    return readMemArg(stream)
  end

  return inst
end

local function store64(sizeMethod)
  local inst = {}
  function inst.evaluate(stream, context)
    local _, memidx, pos = readMemArg(stream)
    local memory = context.memories[memidx + 1]
    if not memory then
      return nil, "Memory not defined"
    end

    local stack = context.stack
    local high = table.remove(stack, #stack)
    if not high then return nil, STACK_EMPTY end
    local low = table.remove(stack, #stack)
    if not low then return nil, STACK_EMPTY end
    local i = table.remove(stack, #stack)
    if not i then return nil, STACK_EMPTY end

    if sizeMethod == "writeU64" then
      memory["writeU64"](i + pos, low, high)
    else
      memory[sizeMethod](i + pos, low)
    end

    return true
  end

  function inst.skip(stream)
    return readMemArg(stream)
  end

  return inst
end

instr._ = {}
instr._.block_end = {}
instr._.block_end.evaluate = function(_)
  return nil, "Block end should be skipped"
end
instr._.block_end.skip = function()
  return true
end

instr._["else"] = {}
instr._["else"].evaluate = function()
  return nil, "Block end should be skipped"
end
instr._["else"].skip = function(stream)
  return true
end
instr._["else"].blockEnds = { 0x0B }

instr.nop = {}
instr.nop.evaluate = function()
  return true
end
instr.nop.skip = function()
  return true
end

instr.unreachable = {}
instr.unreachable.evaluate = function()
  return nil, "Unreachable instruction reached"
end
instr.unreachable.skip = function()
  return true
end

-- TODO: Breaks for u64
instr.drop = {}
instr.drop.evaluate = function(context)
  local stack = context.stack
  local c = table.remove(stack, #stack)
  if not c then return nil, STACK_EMPTY end
  return true
end
instr.drop.skip = function()
  return true
end

instr.block = {}
instr.block.evaluate = function(stream, context)
  local blockType1, blockType2 = readBlockType(stream)
  if not blockType1 then return nil, blockType2 end
  local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
  if not ok then return nil, err end
  return true
end
instr.block.skip = function(stream)
  return readBlockType(stream)
end
instr.block.blockEnds = { 0x0B }

instr.loop = {}
instr.loop.evaluate = function(stream, context)
  local blockType1, blockType2 = readBlockType(stream)
  if not blockType1 then return nil, blockType2 end
  local startPos = stream:pos()
  while true do
    local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
    if not ok then return nil, err end
    if err == false then return true end
    stream:seek(startPos)
  end
end
instr.loop.skip = function(stream)
  return readBlockType(stream)
end
instr.loop.blockEnds = { 0x0B }

instr["if"] = {}
instr["if"].evaluate = function(stream, context)
  local blockType1, blockType2 = readBlockType(stream)
  if not blockType1 then return nil, blockType2 end
  
  local stack = context.stack
  local c = table.remove(stack, #stack)
  if not c then return nil, STACK_EMPTY end
  if c ~= 0 then
    local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2, true)
    if not ok then return nil, err end
    local jumpPos = context.frame.jumpMap[stream:pos()]
    if jumpPos then
      stream:seek(jumpPos + 1)
    end
  else
    local jumpPos = context.frame.jumpMap[stream:pos()]
    if not jumpPos then return nil, NO_JUMP_POS end
    stream:seek(jumpPos)
    local elseOp, err = stream:read(1)
    if not elseOp then return nil, err end

    if elseOp:byte() == 0x05 then
      local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
      if not ok then return nil, err end
    end
  end

  return true
end
instr["if"].skip = function(stream)
  return readBlockType(stream)
end
instr["if"].blockEnds = { 0x05, 0x0B }

instr.br = {}
instr.br.evaluate = function(stream, context)
  local depth, err = readLabelIdx(stream)
  if not depth then return nil, err end
  return nil, { symbol = SYMBOL_BR, depth = depth }
end
instr.br.skip = function(stream)
  return readLabelIdx(stream)
end

instr.br_if = {}
instr.br_if.evaluate = function(stream, context)
  local depth, err = readLabelIdx(stream)
  if not depth then return nil, err end
  local stack = context.stack
  local c = table.remove(stack, #stack)
  if not c then return nil, STACK_EMPTY end
  if c ~= 0 then
    return nil, { symbol = SYMBOL_BR, depth = depth }
  end
  return true
end
instr.br_if.skip = function(stream)
  return readLabelIdx(stream)
end

instr["return"] = {}
instr["return"].evaluate = function()
  return nil, { symbol = SYMBOL_RETURN }
end
instr["return"].skip = function()
  return true
end

instr.call = {}
instr.call.evaluate = function(stream, context)
  local funcidx = readFuncIdx(stream)
  -- TODO: This is not really the correct way to call a function
  local func = context.functions[funcidx + 1]
  if not func then
    return nil, "Function not defined"
  end
  return func(context)
end
instr.call.skip = function(stream)
  return readFuncIdx(stream)
end

instr["local"] = {}
instr["local"].get = {}
instr["local"].get.evaluate = function(stream, context)
  local localIdx = readLocalIdx(stream)
  local val = context.frame.locals[localIdx + 1]
  if not val then
    return nil, "Local not defined"
  end
  table.insert(context.stack, val)
  return true
end
instr["local"].get.skip = function(stream)
  return readLocalIdx(stream)
end

instr["local"].set = {}
instr["local"].set.evaluate = function(stream, context)
  local localIdx = readLocalIdx(stream)
  local stack = context.stack
  local val = table.remove(stack, #stack)
  if not val then return nil, STACK_EMPTY end
  context.frame.locals[localIdx + 1] = val
  return true
end
instr["local"].set.skip = function(stream)
  return readLocalIdx(stream)
end

instr["local"].tee = {}
instr["local"].tee.evaluate = function(stream, context)
  local localIdx = readLocalIdx(stream)
  local stack = context.stack
  local val = stack[#stack]
  if not val then return nil, STACK_EMPTY end
  context.frame.locals[localIdx + 1] = val
  return true
end
instr["local"].tee.skip = function(stream)
  return readLocalIdx(stream)
end

instr.global = {}
instr.global.get = {}
instr.global.get.evaluate = function(stream, context)
  local globalidx, err = readGlobalIdx(stream)
  if not globalidx then return nil, err end
  local global = context.globals[globalidx + 1]
  if not global then
    return nil, "Global not defined"
  end
  table.insert(context.stack, global)
  return true
end
instr.global.get.skip = function(stream)
  return readGlobalIdx(stream)
end

instr.ref = {}
instr.ref.func = {}
instr.ref.func.write = function(tbl, pos, idx)
  tbl[pos] = 0xD2
  return writeInt(tbl, pos + 1, 32, idx)
end

instr.i32 = {}
instr.i32.load = load32("u32", false)
instr.i32.load8_s = load32("u8", true)
instr.i32.load8_u = load32("u8", false)
instr.i32.load16_s = load32("u16", true)
instr.i32.load16_u = load32("u16", false)
instr.i32.store = store32("writeU32")
instr.i32.store8 = store32("writeU8")
instr.i32.store16 = store32("writeU16")

instr.i64 = {}
instr.i64.load = load64("u64", false)
instr.i64.load8_s = load64("u8", true)
instr.i64.load8_u = load64("u8", false)
instr.i64.load16_s = load64("u16", true)
instr.i64.load16_u = load64("u16", false)
instr.i64.load32_s = load64("u32", true)
instr.i64.load32_u = load64("u32", false)
instr.i64.store = store64("writeU64")
instr.i64.store8 = store64("writeU8")
instr.i64.store16 = store64("writeU16")
instr.i64.store32 = store64("writeU32")

instr.memory = {}
instr.memory.init = {}
instr.memory.init.evaluate = function(stream, context)
  local dataidx, err = readDataIdx(stream)
  if not dataidx then return nil, err end
  local memidx, err = readMemIdx(stream)
  if not memidx then return nil, err end

  local stack = context.stack
  local len = table.remove(stack, #stack)
  local dataOffset = table.remove(stack, #stack)
  local memOffset = table.remove(stack, #stack)

  local memory = context.memories[memidx + 1]
  local data = context.data[dataidx + 1]
  if dataOffset + len > data.datalen then
    return nil, "Data access out-of-bounds"
  end

  local ok, err = memory.writeU32Bytes(data.data, dataOffset + 1, memOffset, len)
  if not ok then return false, err end

  return true
end
instr.memory.init.skip = function(stream)
  local dataidx, err = readDataIdx(stream)
  if not dataidx then return nil, err end
  return readMemIdx(stream)
end

instr.i32.const = {}
instr.i32.const.evaluate = function(stream, context)
  local stack = context.stack
  local val, err = readSInt(stream, 32)
  if not val then return nil, err end
  stack[#stack + 1] = val % 0x100000000
  return true
end
instr.i32.const.skip = function(stream)
  return readSInt(stream, 32)
end

instr.i32.eqz = testop32(numbers.i32.eqz)
instr.i32.eq = relop32(numbers.i32.eq)
instr.i32.ne = relop32(numbers.i32.ne)
instr.i32.lt_s = relop32(numbers.i32.lt_s)
instr.i32.gt_s = relop32(numbers.i32.gt_s)

instr.i32.add = binop32(numbers.i32.add)
instr.i32.sub = binop32(numbers.i32.sub)

instr.i64.const = {}
instr.i64.const.evaluate = function(stream, context)
  local stack = context.stack
  local lh, hh = readSInt(stream, 64)
  if not lh then return nil, hh end
  stack[#stack + 1] = lh % 0x100000000
  stack[#stack + 1] = hh % 0x100000000
  return true
end
instr.i64.const.skip = function(stream)
  return readSInt(stream, 64)
end

local memtblSubOps = {
  _subop = true,
  [8] = instr.memory.init
}

instr._lookup = {
  [0x00] = instr.unreachable,
  [0x01] = instr.nop,
  [0x02] = instr.block,
  [0x03] = instr.loop,
  [0x04] = instr["if"],
  [0x05] = instr._["else"],
  [0x0B] = instr._.block_end,
  [0x0C] = instr.br,
  [0x0D] = instr.br_if,
  [0x0F] = instr["return"],
  [0x10] = instr.call,
  [0x1A] = instr.drop,
  [0x20] = instr["local"].get,
  [0x21] = instr["local"].set,
  [0x22] = instr["local"].tee,
  [0x23] = instr.global.get,
  [0x28] = instr.i32.load,
  [0x29] = instr.i64.load,
  [0x2C] = instr.i32.load8_s,
  [0x2D] = instr.i32.load8_u,
  [0x2E] = instr.i32.load16_s,
  [0x2F] = instr.i32.load16_u,
  [0x30] = instr.i64.load8_s,
  [0x31] = instr.i64.load8_u,
  [0x32] = instr.i64.load16_s,
  [0x33] = instr.i64.load16_u,
  [0x34] = instr.i64.load32_s,
  [0x35] = instr.i64.load32_u,
  [0x36] = instr.i32.store,
  [0x37] = instr.i64.store,
  [0x3A] = instr.i32.store8,
  [0x3B] = instr.i32.store16,
  [0x3C] = instr.i64.store8,
  [0x3D] = instr.i64.store16,
  [0x3E] = instr.i64.store32,
  [0x41] = instr.i32.const,
  [0x42] = instr.i64.const,
  [0x45] = instr.i32.eqz,
  [0x46] = instr.i32.eq,
  [0x47] = instr.i32.ne,
  [0x48] = instr.i32.lt_s,
  [0x4A] = instr.i32.gt_s,
  [0x6A] = instr.i32.add,
  [0x6B] = instr.i32.sub,
  [0xFC] = memtblSubOps
}

instr.SYMBOL_BR = SYMBOL_BR
instr.SYMBOL_RETURN = SYMBOL_RETURN

return instr