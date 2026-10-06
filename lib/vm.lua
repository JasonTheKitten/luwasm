local types = localRequire("lib/types")
local memoryLib = localRequire("lib/memory")
local codeLib = localRequire("lib/code")
local stackLib = localRequire("lib/stack")
local instructions = localRequire("lib/instructions")

local COMP_TYPE_FUNC, COMP_TYPE_MEM = types.COMP_TYPE_FUNC, types.COMP_TYPE_MEM

local function evaluateConstantExpr(expr)
  local memory = memoryLib.createBackedU32Memory(expr.data, expr.len)
  local reader = memoryLib.createMemoryReader(memory)
  local context = codeLib.newContext()
  return codeLib.evaluateConstExpr(reader, context)
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
    if v.active then
      local memidx = v.memidx
      local ok, offset = evaluateConstantExpr(v.expr)
      if not ok then return nil, offset end
      local memory = memories[memidx + 1]
      local ok, err = memory.writeU32Bytes(v.data, 1, offset, v.datalen)
      if not ok then return nil, err end
    end
  end

  local types = {}
  local typesList = module.typeSection and module.typeSection.types or {}
  for _, v in ipairs(typesList) do
    for _, v2 in ipairs(v.types) do
      for _, v3 in ipairs(v2) do
        if v3.type == COMP_TYPE_FUNC then
          table.insert(types, { numArgs = #v3.params, params = v3.params, rtn = v3.rtn })
        end
      end
    end
  end

  local globals = {}
  local globalsList = module.globalSection and module.globalSection.globals or {}
  for k, v in ipairs(globalsList) do
    local ok, value, value2 = evaluateConstantExpr(v.expr)
    if not ok then return value end
    globals[k] = {
      type = v.type.type,
      mutable = v.type.mutable,
      value = value,
      value2 = value2
    }
  end

  local tags = {}
  local tagList = module.tagSection and module.tagSection.tags or {}
  for k, v in ipairs(tagList) do
    local type = types[v.typeidx + 1]
    if not type then
      return nil, "Type not defined"
    end
    tags[k] = {
      type = type
    }
  end

  local codesList = module.codeSection and module.codeSection.codes or {}

  local functions = {}
  local importsList = module.importSection and module.importSection.imports or {}
  for i=1, #importsList do
    functions[i] = function()
      return nil, "Import functions are not yet implemented"
    end
  end

  local functionsData = {}
  local function runInterpretedFunction(idx, context)
    print("Run", idx + #importsList - 1)
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
      
      local jumpMap, sourceMap = codeLib.generateJumpMap(functionData.reader)
      if not jumpMap then return nil, sourceMap end

      functionData.jumpMap = jumpMap
      functionData.sourceMap = sourceMap
    end
    local functionReader = functionData.reader
    -- Needed to avoid recursion from destroying the position
    local oldPos = functionReader:pos()
    functionReader:seek(0)
    
    local ok, frameIndex = codeLib.evaluateFunc(
      functionReader, context, functionData)
    functionReader:seek(oldPos)
    
    if not ok then return nil, frameIndex end
    
    return true, frameIndex
  end

  for k in ipairs(codesList) do
    local idx = #importsList + k
    functions[idx] = function(context)
      return runInterpretedFunction(k, context)
    end
    functionsData[k] = {}
  end

  local function getFuncType(funcIdx)
    if funcIdx >= #importsList then
      local codeIdx = funcIdx - #importsList + 1
      local typeIdx = module.funcSection.funcs[codeIdx]
      return types[typeIdx + 1]
    else
      return nil, "Import functions not implemented"
    end
  end

  local function createStack(funcIdx, args)
    local stack = stackLib.createStack()
    local funcType, err = getFuncType(funcIdx)
    if not funcType then return nil, err end

    stack.pushTypedValues(args, funcType.params)

    return stack
  end

  local exports = {}
  local exportsList = module.exportSection and module.exportSection.exports or {}
  for _, v in ipairs(exportsList) do
    if v.type.type == COMP_TYPE_FUNC then
      exports[v.name] = function(...)
        local context = codeLib.newContext()
        local stack, err = createStack(v.type.idx, {...})
        if not stack then return nil, err end
        context.stack = stack
        context.frame.frameIndex = stack.size() + 1
        context.memories = memories
        context.data = dataSegmentList
        context.globals = globals
        context.tags = tags
        context.functions = functions
        context.types = types

        local ok, frameIndex = functions[v.type.idx + 1](context)
        local err = frameIndex
        if not ok and type(err) == "table" then
          if err.symbol == instructions.SYMBOL_BR then
            return nil, "Control flow 'br' reached top (not implemented)"
          elseif err.symbol == instructions.SYMBOL_RETURN then
            return nil, "Control flow 'return' reached top (not implemented)"
          elseif err.symbol == instructions.SYMBOL_THROW then
            return nil, "Control flow 'throw' reached top (not implemented)"
          end
        end
        if not ok then return nil, err end

        return ok, stack.unpack(frameIndex)
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