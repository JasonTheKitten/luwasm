local streamutils = localRequire("lib/streamutils")
local valparser = localRequire("lib/valparser")
local instructions = localRequire("lib/instructions")
local types = localRequire("lib/types")

local readU8, readList = streamutils.readU8, streamutils.readList
local readValType = valparser.readValType
local SYMBOL_BR = instructions.SYMBOL_BR
local VTYPE_F64, VTYPE_F32, VTYPE_I64, VTYPE_I32, BLOCK_TYPE_EMPTY
  = types.VTYPE_F64, types.VTYPE_F32, types.VTYPE_I64, types.VTYPE_I32, types.BLOCK_TYPE_EMPTY

local function lookupInstr(stream)
  local opcode = readU8(stream)
  -- TODO: Subops
  local instr = instructions._lookup[opcode]
  if not instr then
    return nil, "Unsupported instruction: " .. string.format("0x%02X", opcode)
  end
  return instr
end

local function readLocals(stream)
  local locals, err = readU8(stream)
  if not locals then return nil, err end

  local loc, err = readValType(stream)
  if not loc then return nil, err end

  return locals
end

local function readNumLocals(stream)
  local localsList, err = readList(stream, readLocals)
  if not localsList then return nil, err end

  local numLocals = 0
  for _, v in ipairs(localsList) do
    numLocals = numLocals + v
  end

  return numLocals
end

local function evaluateNext(stream, context)
  local instr, err = lookupInstr(stream)
  if not instr then return nil, err end
  return instr.evaluate(stream, context)
end

local function evaluate(stream, context, allowElse)
  local b = stream:peek(1)
  while b and b ~= 0x0B and (b ~= 0x05 or not allowElse) do
    local ok, err = evaluateNext(stream, context)
    if not ok then return nil, err end
    b = stream:peek(1)
  end

  local val, err = stream:read(1)
  if not val then return false, err end
  if not (
    val:byte() == 0x0B
    or (allowElse and val:byte() == 0x05)
  ) then
    return false, "Invalid block end"
  end

  return true
end

local function determineBlockIO(context, blockType1, blockType2)
  local inputs, outputs = 0, 0
  if blockType1 == true then
    return nil, "blockidx type not implemented"
  elseif blockType1 == BLOCK_TYPE_EMPTY then
    inputs, outputs = 0, 0
  elseif blockType1 == VTYPE_I32 or blockType1 == VTYPE_F32 then
    inputs, outputs = 0, 1
  elseif blockType1 == VTYPE_I64 or blockType1 == VTYPE_F64 then
    inputs, outputs = 0, 2
  end
  return inputs, outputs
end

local function unwindStack(stack, startIdx, outputs)
  local numToRemove = #stack - startIdx - outputs + 1
  if numToRemove < 0 then
    return nil, "Stack underflow"
  end
  for _=1, numToRemove do
    table.remove(stack, startIdx)
  end
  return true
end

local function evaluateBlock(stream, context, blockType1, blockType2, allowElse)
  local inputs, outputs = determineBlockIO(context, blockType1, blockType2)
  local stackArity = #context.stack + 1 - inputs
  local startPos = stream:pos()
  local ok, err = evaluate(stream, context, allowElse)
  if not ok and type(err) == "table" and err.symbol == SYMBOL_BR then
    if err.depth == 0 then
      local jumpPos = context.frame.jumpMap[startPos]
      if not jumpPos then
        return false, "No recorded jump pos"
      end
      stream:seek(jumpPos + 1)
      ok, err = unwindStack(context.stack, stackArity, outputs)
      if not ok then return nil, err end
      return true, true
    else
      err.depth = err.depth - 1
      return nil, err
    end
  end
  if not ok then return nil, err end

  ok, err = unwindStack(context.stack, stackArity, outputs)
  if not ok then return nil, err end
  return true, false
end

local function evaluateConstExpr(stream, context)
  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  return true, table.unpack(context.stack)
end

local function evaluateFunc(stream, context, functionData)
  local numLocals = readNumLocals(stream)

  local oldFrame = context.frame
  local frame = {
    locals = {},
    jumpMap = functionData.jumpMap
  }
  context.frame = frame

  local numArgs = functionData.numArgs
  local cpyStart = #context.stack - numArgs + 1
  for i=1, numArgs do
    frame.locals[i] = table.remove(context.stack, cpyStart)
  end
  for i=1, numLocals do
    table.insert(frame.locals, 0)
  end

  local frameIndex = #context.stack + 1
  frame.frameIndex = frameIndex

  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  context.frame = oldFrame

  return true, frameIndex
end

local function generateJumpMap(stream)
  readNumLocals(stream)

  local jumpMap = {}
  local sourceMap = {}

  local activeSearch = { [0x0B] = true, pos = 0 }
  while activeSearch ~= nil do
    local nextByte = stream:peek(1)
    if activeSearch[nextByte] then
      local pos = stream:pos()
      jumpMap[activeSearch.pos] = pos
      sourceMap[pos] = activeSearch.pos
      activeSearch = activeSearch.parent
    end

    local instr, err = lookupInstr(stream)
    if not instr then return nil, err end
    instr.skip(stream)

    if instr.blockEnds ~= nil then
      local newSearch = {
        pos = stream:pos(),
        parent = activeSearch
      }
      for _, v in ipairs(instr.blockEnds) do
        newSearch[v] = true
      end
      activeSearch = newSearch
    end
  end

  return jumpMap, sourceMap
end

local function newContext()
  return {
    evaluateBlock = evaluateBlock,
    stack = {},
    functions = {},
    frame = {
      locals = {},
      frameIndex = 0,
      jumpMap = {}
    }
  }
end

return {
  evaluateFunc = evaluateFunc,
  evaluateConstExpr = evaluateConstExpr,
  generateJumpMap = generateJumpMap,
  newContext = newContext
}