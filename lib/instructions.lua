local streamutils = localRequire("lib/streamutils")
local numbers = localRequire("lib/numbers")
local valparser = localRequire("lib/valparser")

local readInt = streamutils.readInt
local readBlockType, readFuncIdx, readLocalIdx, readLabelIdx
  = valparser.readBlockType, valparser.readFuncIdx, valparser.readLocalIdx,
  valparser.readLabelIdx

local STACK_EMPTY = "Stack is empty"
local NO_JUMP_POS = "No recorded jump pos"

local SYMBOL_BR = {}

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

local function relop32(op)
  return binop32(function(a, b)
    local val, err = op(a, b)
    if val == nil then return nil, err end
    return val and 1 or 0
  end)
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

instr.unreachable = {}
instr.unreachable.evaluate = function()
  return nil, "Unreachable instruction reached"
end
instr.unreachable.skip = function()
  return true
end

instr.nop = {}
instr.nop.evaluate = function()
  return true
end
instr.nop.skip = function()
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
  local depth = readLabelIdx(stream)
  if not depth then return nil, "Failed to read depth" end
  return nil, { symbol = SYMBOL_BR, depth = depth }
end
instr.br.skip = function(stream)
  return readLabelIdx(stream)
end

instr.br_if = {}
instr.br_if.evaluate = function(stream, context)
  local depth = readLabelIdx(stream)
  if not depth then return nil, "Failed to read depth" end
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

instr.ref = {}
instr.ref.func = {}
instr.ref.func.write = function(tbl, pos, idx)
  tbl[pos] = 0xD2
  return writeInt(tbl, pos + 1, 32, idx)
end

instr.i32 = {}
instr.i32.const = {}
instr.i32.const.evaluate = function(stream, context)
  local stack = context.stack
  local val, err = readInt(stream, 32)
  if not val then return nil, err end
  stack[#stack + 1] = val
  return true
end
instr.i32.const.skip = function(stream, context)
  return readInt(stream, 32)
end

instr.i32.lt_s = relop32(numbers.i32.lt_s)
instr.i32.gt_s = relop32(numbers.i32.gt_s)

instr.i32.add = binop32(numbers.i32.add)
instr.i32.sub = binop32(numbers.i32.sub)

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
  [0x10] = instr.call,
  [0x20] = instr["local"].get,
  [0x21] = instr["local"].set,
  [0x41] = instr.i32.const,
  [0x48] = instr.i32.lt_s,
  [0x4A] = instr.i32.gt_s,
  [0x6A] = instr.i32.add,
  [0x6B] = instr.i32.sub
}

instr.SYMBOL_BR = SYMBOL_BR

return instr