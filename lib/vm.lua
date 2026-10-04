local types = localRequire("lib/types")
local memoryLib = localRequire("lib/memory")
local codeLib = localRequire("lib/code")
local COMP_TYPE_FUNC, COMP_TYPE_MEM, VTYPE_F64, VTYPE_F32, VTYPE_I64, VTYPE_I32
  = types.COMP_TYPE_FUNC, types.COMP_TYPE_MEM,
  types.VTYPE_F64, types.VTYPE_F32, types.VTYPE_I64, types.VTYPE_I32

local function evaluateConstantExpr(expr)
  local memory = memoryLib.createBackedU32Memory(expr.data, expr.len)
  local reader = memoryLib.createMemoryReader(memory)
  local context = codeLib.newContext()
  return codeLib.evaluateExpr(reader, context)
end

local function createVM(module)
  local memories = {}
  
  local memoriesList = module.memorySection and module.memorySection.memories or {}
  for k, v in ipairs(memoriesList) do
    -- TODO: Track max
    memories[k] = memoryLib.createNewU32Memory(v.limit.min)
  end

  local dataSegmentList = module.dataSection and module.dataSection.dataSegments or {}
  for _, v in ipairs(dataSegmentList) do
    local err
    local memidx = 0
    local offset = 0
    if v.active then
      memidx = v.memidx
      offset, err = evaluateConstantExpr(v.expr)
      if not offset then return nil, err end
    end

    local memory = memories[memidx + 1]
    local ok, err = memory.writeU32Bytes(v.data, 1, offset, v.datalen)
    if not ok then return nil, err end
  end

  local function sumArgCount(params)
    local argCount = 0
    for _, v in ipairs(params) do
      if v == VTYPE_F64 or v == VTYPE_I64 then
        argCount = argCount + 2
      elseif v == VTYPE_F32 or v == VTYPE_I32 then
        argCount = argCount + 1
      else
        return nil, "Unsupported type"
      end
    end

    return argCount
  end

  local types = {}
  local typesList = module.typeSection and module.typeSection.types or {}
  for _, v in ipairs(typesList) do
    for _, v2 in ipairs(v.types) do
      for _, v3 in ipairs(v2) do
        if v3.type == COMP_TYPE_FUNC then
          local argCount, err = sumArgCount(v3.params)
          if not argCount then return err end
          table.insert(types, { numArgs = argCount })
        end
      end
    end
  end

  local codesList = module.codeSection and module.codeSection.codes or {}

  local functions = {}
  local functionsData = {}
  local function runInterpretedFunction(idx, context)
    -- TODO: Setup context
    local functionData = functionsData[idx]
    if functionData.reader == nil then
      local code = codesList[idx]
      local memory = memoryLib.createBackedU32Memory(code.code, code.codelen)
      functionData.reader = memoryLib.createMemoryReader(memory)

      local type = types[module.funcSection.funcs[idx] + 1]
      if not type then
        return nil, "Type does not exist"
      end
      functionData.numArgs = type.numArgs
    end
    local functionReader = functionData.reader
    functionReader:seek(0)
    
    local ok, frameIndex = codeLib.evaluateFunc(
      functionReader, context, functionData.numArgs)
    if not ok then return false, frameIndex end
    
    return true, table.unpack(context.stack, frameIndex)
  end

  for k in ipairs(codesList) do
    functions[k] = function(context)
      return runInterpretedFunction(k, context)
    end
    functionsData[k] = {}
  end

  local exports = {}
  local exportsList = module.exportSection and module.exportSection.exports or {}
  for _, v in ipairs(exportsList) do
    if v.type.type == COMP_TYPE_FUNC then
      exports[v.name] = function(...)
        local args = {...}
        local context = codeLib.newContext()
        context.stack = args
        context.frameIndex = #args + 1
        return functions[v.type.idx + 1](context)
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