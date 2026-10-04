local streamutils = localRequire("lib/streamutils")
local numbers = localRequire("lib/numbers")
local valparser = localRequire("lib/valparser")

local readInt = streamutils.readInt
local readLocalIdx = valparser.readLocalIdx

local STACK_EMPTY = "Stack is empty"

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
    if not res then return nil, err end
    stack[#stack+1] = res
    return true
  end
  return inst
end

instr["local"] = {}
instr["local"].get = {}
instr["local"].get.evaluate = function(stream, context)
  local localIdx = readLocalIdx(stream)
  local val = context.locals[localIdx + 1]
  if not val then
    return nil, "Local not defined"
  end
  table.insert(context.stack, val)
  return true
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

instr.i32.add = {}
instr.i32.add = binop32(numbers.i32.add)

instr._lookup = {
  [0x20] = instr["local"].get,
  [0x41] = instr.i32.const,
  [0x6A] = instr.i32.add
}

return instr