local types = localRequire("lib/types")
local memoryLib = localRequire("lib/memory")
local codeLib = localRequire("lib/code")
local COMP_TYPE_FUNC, COMP_TYPE_MEM
  = types.COMP_TYPE_FUNC, types.COMP_TYPE_MEM

local function evaluateConstantExpr(expr)
  local memory = memoryLib.createBackedU32Memory(expr.data, expr.len)
  local reader = memoryLib.createMemoryReader(memory)
  return codeLib.evaluateConstant(reader)
end

local function createVM(module)
  local memories = {}
  for k, v in ipairs(module.memorySection.memories) do
    -- TODO: Track max
    memories[k] = memoryLib.createNewU32Memory(v.limit.min)
  end

  for _, v in ipairs(module.dataSection.dataSegments) do
    local err
    local memidx = 0
    local offset = 0
    if v.active then
      memidx = v.memidx
      offset, err = evaluateConstantExpr(v.expr)
      if not offset then return nil, err end
    end

    local memory = memories[memidx + 1]
    local ok, err = memory.writeU32Bytes(v.data, 0, offset, v.datalen)
    if not ok then return nil, err end
  end

  local functions = {}
  local function runInterpretedFunction(idx, ...)
    print("Run function " .. idx)
  end

  for k in ipairs(module.codeSection.codes) do
    functions[k] = function(...)
      runInterpretedFunction(k, ...)
    end
  end

  local exports = {}
  for _, v in ipairs(module.exportSection.exports) do
    if v.type.type == COMP_TYPE_FUNC then
      exports[v.name] = function(...)
        functions[v.type.idx + 1](...)
      end
    elseif v.type.type == COMP_TYPE_MEM then
      exports[v.name] = memories[v.type.idx + 1]
    end
  end

  return {
    exports = exports
  }
end

return {
  createVM = createVM
}