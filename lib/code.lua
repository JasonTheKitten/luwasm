local streamutils = localRequire("lib/streamutils")
local instructions = localRequire("lib/instructions")

local readU8 = streamutils.readU8

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

end

local function evaluateConstant(stream)
  local context = {}
  return evaluateNext(stream, context)
end

return {
  evaluate = evaluate,
  evaluateConstant = evaluateConstant
}