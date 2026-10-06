local streamutils = localRequire("lib/streamutils")
local codeparser = localRequire("lib/codeparser")
local instructions = localRequire("lib/instructions")
local types = localRequire("lib/types")
local stackLib = localRequire("lib/stack")

local readU8, readInt = streamutils.readU8, streamutils.readInt
local readNumLocals = codeparser.readNumLocals
local SYMBOL_BR, SYMBOL_RETURN, SYMBOL_THROW
  = instructions.SYMBOL_BR, instructions.SYMBOL_RETURN, instructions.SYMBOL_THROW

local function lookupInstr(stream)
  local opcode = readU8(stream)
  local instr = instructions._lookup[opcode]
  if not instr then
    return nil, "Unsupported instruction: " .. string.format("0x%02X", opcode)
  end
  if instr._subop then
    local subopcode = readInt(stream, 32)
    instr = instr[subopcode]
    if not instr then
      return nil, "Unsupported sub-instruction: " .. subopcode
    end
  end
  return instr
end

local function evaluateNext(stream, context)
  local instr, err = lookupInstr(stream)
  if not instr then return nil, err end
  return instr.evaluate(stream, context, instr.collectArgs(stream))
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
    local type = context.types[blockType2 + 1]
    if not type then
      return nil, "Type not defined"
    end

    inputs, outputs = #type.params, #type.rtn
  elseif blockType1 ~= types.BLOCK_TYPE_EMPTY then
    inputs, outputs = 0, 1
  end
  return inputs, outputs
end

local function evaluateBlock(stream, context, blockType1, blockType2, allowElse, isLoop)
  local inputs, outputs = determineBlockIO(context, blockType1, blockType2)
  if not inputs then return nil, outputs end
  local stack = context.stack
  local stackArity = stack.size() - inputs
  local startPos = stream:pos()
  local ok, err = evaluate(stream, context, allowElse)
  
  local isErrTable = not ok and type(err) == "table"
  -- Editor is not smart enough to realize err is non-nil when isErrTable
  if err ~= nil and isErrTable and err.symbol == SYMBOL_BR then
    if err.depth == 0 then
      local jumpPos = context.frame.jumpMap[startPos]
      if not jumpPos then
        return false, "No recorded jump pos"
      end
      stream:seek(jumpPos + 1)

      local expectedResults = isLoop and inputs or outputs

      ok, err = stack.unwind(stackArity, expectedResults)
      if not ok then return nil, err end
      return true, true
    else
      err.depth = err.depth - 1
      return nil, err
    end
  elseif err ~= nil then
    return nil, err
  end

  ok, err = stack.unwind(stackArity, outputs)
  if not ok then return nil, err end
  return true, false
end

local function evaluateConstExpr(stream, context)
  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  return true, context.stack.unpack(1)
end

local function evaluateFunc(stream, context, functionData)
  local numLocals = readNumLocals(stream)

  local oldFrame = context.frame
  local frame = {
    locals = {},
    jumpMap = functionData.jumpMap
  }
  context.frame = frame

  local stack = context.stack
  local numArgs = functionData.numArgs

  for i = numArgs, 1, -1 do
    local loc, err = stack.popLocal()
    if not loc then return nil, err end
    frame.locals[i] = loc
  end

  for i = 1, numLocals do
    local localType = (functionData.localTypes and functionData.localTypes[i]) or types.VTYPE_I32
    if localType == types.VTYPE_I64 then
      table.insert(frame.locals, { type = types.VTYPE_I64, value = 0, value2 = 0 })
    else
      table.insert(frame.locals, { type = localType, value = 0 })
    end
  end

  local frameIndex = stack.size() + 1
  frame.frameIndex = frameIndex
  local ok, err = evaluate(stream, context)

  context.frame = oldFrame

  local isErrTable = not ok and type(err) == "table"
  if err ~= nil and isErrTable then
    if err.symbol == SYMBOL_THROW then
      stack.unwind(frameIndex, 1)
      return nil, err
    elseif err.symbol == SYMBOL_RETURN then
      return true, frameIndex
    elseif err.symbol == SYMBOL_BR then
      return true, frameIndex
    end
    return nil, err
  elseif not ok then
    return nil, err
  end

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
    instr.collectArgs(stream)

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
    stack = stackLib.createStack(),
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