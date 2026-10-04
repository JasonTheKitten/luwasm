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

local function evaluate(stream, context)
  local b = stream:peek(1)
  while b and b ~= 0x0B do
    local ok, err = evaluateNext(stream, context)
    if not ok then return nil, err end
    b = stream:peek(1)
  end

  local val, err = stream:read(1):byte()
  if not val then return false, err end
  if val ~= 0x0B then
    return false, "Invalid block end"
  end
  
  return true
end

local function evaluateConstExpr(stream, context)
  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  return true, table.unpack(context.stack)
end

local function evaluateFunc(stream, context, numArgs)
  local locals, err = readU8(stream)
  if not locals then return nil, err end

  for i=1, locals do
    local loc, err = readValType(stream)
    if not loc then return nil, err end
  end

  local oldLocals = context.locals
  context.locals = {}

  local cpyStart = #context.stack - numArgs + 1
  for i=1, numArgs do
    context.locals[i] = table.remove(context.stack, cpyStart)
  end

  local oldFrameIndex = context.frameIndex
  local frameIndex = #context.stack + 1
  context.frameIndex = frameIndex

  local ok, err = evaluate(stream, context)
  if not ok then return nil, err end

  context.frameIndex = oldFrameIndex
  context.locals = oldLocals

  return true, frameIndex
end

local function newContext()
  return {
    stack = {},
    locals = {},
    frameIndex = 0,
    numArgs = 0
  }
end

return {
  evaluateFunc = evaluateFunc,
  evaluateConstExpr = evaluateConstExpr,
  newContext = newContext
}