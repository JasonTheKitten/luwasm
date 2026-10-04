local streamutils = localRequire("lib/streamutils")
local valparser = localRequire("lib/valparser")
local instructions = localRequire("lib/instructions")

local readU8 = streamutils.readU8
local readValType = valparser.readValType

local function lookupInstr(stream)
  local opcode = readU8(stream)
  -- TODO: Subops
  local instr = instructions._lookup[opcode]
  if not instr then
    return nil, "Unsupported instruction: " .. opcode
  end
  return instr
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

local function evaluateConstExpr(stream, context)
  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  return true, table.unpack(context.stack)
end

local function evaluateFunc(stream, context, functionData)
  local locals, err = readU8(stream)
  if not locals then return nil, err end

  for i=1, locals do
    local loc, err = readValType(stream)
    if not loc then return nil, err end
  end

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

  local frameIndex = #context.stack + 1
  frame.frameIndex = frameIndex

  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  context.frame = oldFrame

  return true, frameIndex
end

local function generateJumpMap(stream)
  local locals, err = readU8(stream)
  if not locals then return nil, err end

  for i=1, locals do
    local loc, err = readValType(stream)
    if not loc then return nil, err end
  end

  --

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
    evaluate = evaluate,
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