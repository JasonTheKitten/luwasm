local types = localRequire("lib/types")

local STACK_EMPTY = "Stack is empty"

local DEBUG_VALIDATE = true

local function create()
  local stack = {}
  -- TODO: How does the parallel type stack affect memory?
  local typeStack = {}
  local handle = {}

  local function pop1Typed(type, name)
    if #stack < 1 then
      return nil, STACK_EMPTY
    end
    if not handle.isType(type) then
      return nil, "Type Mismatch (Expected " .. name ..")"
    end
    table.remove(typeStack)
    return table.remove(stack)
  end

  function handle.pushI32(v)
  if DEBUG_VALIDATE and type(v) ~= "number" then
    error(
      "pushI32 received " .. type(v) ..
      " (" .. tostring(v) .. ")",
      2
    )
  end

  table.insert(stack, v)
  table.insert(typeStack, types.VTYPE_I32)
end

function handle.pushI64(lv, hv)
  if DEBUG_VALIDATE and type(lv) ~= "number" then
    error(
      "pushI64 low received " .. type(lv) ..
      " (" .. tostring(lv) .. ")",
      2
    )
  end

  if DEBUG_VALIDATE and type(hv) ~= "number" then
    error(
      "pushI64 high received " .. type(hv) ..
      " (" .. tostring(hv) .. ")",
      2
    )
  end

  table.insert(stack, lv)
  table.insert(stack, hv)
  table.insert(typeStack, types.VTYPE_I64)
end

function handle.pushF32(v)
  if DEBUG_VALIDATE and type(v) ~= "number" then
    error(
      "pushF32 received " .. type(v) ..
      " (" .. tostring(v) .. ")",
      2
    )
  end

  table.insert(stack, v)
  table.insert(typeStack, types.VTYPE_F32)
end

function handle.pushF64(v)
  if DEBUG_VALIDATE and type(v) ~= "number" then
    error(
      "pushF64 received " .. type(v) ..
      " (" .. tostring(v) .. ")",
      2
    )
  end

  table.insert(stack, v)
  table.insert(typeStack, types.VTYPE_F64)
end

  function handle.pushExn(v)
    table.insert(stack, v)
    table.insert(typeStack, types.HTYPE_EXN)
  end

  function handle.popI32()
    return pop1Typed(types.VTYPE_I32, "i32")
  end

  function handle.popI64()
    if #stack < 2 then
      return nil, STACK_EMPTY
    end
    if not handle.isType(types.VTYPE_I64) then
      return nil, "Type Mismatch (Expected i64)"
    end
    local hv = table.remove(stack)
    local lv = table.remove(stack)
    table.remove(typeStack)
    return lv, hv
  end

  function handle.popF32()
    return pop1Typed(types.VTYPE_F32, "f32")
  end

  function handle.popF64()
    return pop1Typed(types.VTYPE_F64, "f64")
  end

  function handle.popExn()
    return pop1Typed(types.HTYPE_EXN, "Exn")
  end

  function handle.isType(vtype)
    return typeStack[#typeStack] == vtype
  end

  function handle.drop()
    if #typeStack == 0 then
      return nil, STACK_EMPTY
    end
    if handle.isType(types.VTYPE_I64) then
      table.remove(stack)
      table.remove(stack)
    else
      table.remove(stack)
    end
    table.remove(typeStack)
    return true
  end

  function handle.toLocal()
    if #stack < 1 then
      return nil, STACK_EMPTY
    end

    local value, value2 = stack[#stack], nil
    if handle.isType(types.VTYPE_I64) then
      value2 = stack[#stack - 1]
    end

    -- TODO: table alloc is not great
    return {
      type = typeStack[#typeStack],
      value = value,
      value2 = value2
    }
  end

  function handle.popLocal()
    local loc, err = handle.toLocal()
    if not loc then return nil, err end
    local ok, err = handle.drop()
    if not ok then return err end
    return loc
  end

  function handle.pushLocal(loc)
    if loc.type == types.VTYPE_I64 then
      table.insert(stack, loc.value2)
    end
    table.insert(stack, loc.value)
    table.insert(typeStack, loc.type)
  end
  
  function handle.pushTyped(vtype, val1, val2)
    if DEBUG_VALIDATE then
      if vtype == types.VTYPE_I64 then
        if type(val1) ~= "number" then
          error(
            "pushTyped i64 low received " ..
            type(val1) .. " (" .. tostring(val1) .. ")",
            2
          )
        end

        if type(val2) ~= "number" then
          error(
            "pushTyped i64 high received " ..
            type(val2) .. " (" .. tostring(val2) .. ")",
            2
          )
        end
      elseif vtype == types.VTYPE_I32 or
            vtype == types.VTYPE_F32 or
            vtype == types.VTYPE_F64 then

        if type(val1) ~= "number" then
          error(
            "pushTyped " .. tostring(vtype) ..
            " received " .. type(val1) ..
            " (" .. tostring(val1) .. ")",
            2
          )
        end
      end
    end

    if vtype == types.VTYPE_I64 then
      table.insert(stack, val1)
      table.insert(stack, val2)
      table.insert(typeStack, vtype)
    else
      table.insert(stack, val1)
      table.insert(typeStack, vtype)
    end
  end

  function handle.unwind(startSize, outputs)
    outputs = outputs or 0
    local curSize = #typeStack
    if curSize < startSize + outputs then
      return nil, STACK_EMPTY
    end

    local typeStart = startSize + 1
    local typeEnd = curSize - outputs

    local adjustedStart = 1
    for i = 1, typeStart - 1 do
      adjustedStart = adjustedStart + (typeStack[i] == types.VTYPE_I64 and 2 or 1)
    end

    local adjustedCount = 0
    for i = typeStart, typeEnd do
      adjustedCount = adjustedCount + (typeStack[i] == types.VTYPE_I64 and 2 or 1)
    end

    for _ = 1, adjustedCount do
      table.remove(stack, adjustedStart)
    end

    for _ = typeStart, typeEnd do
      table.remove(typeStack, typeStart)
    end

    return true
  end

  ---@diagnostic disable-next-line: deprecated
  local unpack = unpack or table.unpack
  function handle.unpack(startTypeIdx)
    startTypeIdx = startTypeIdx or 1
    local rawStart = 1
    for i = 1, startTypeIdx - 1 do
      local t = typeStack[i]
      if t == types.VTYPE_I64 then
        rawStart = rawStart + 2
      else
        rawStart = rawStart + 1
      end
    end
    return unpack(stack, rawStart)
  end

  function handle.pushTypedValues(args, vtypes)
    local argIdx = 1
    for _, paramType in ipairs(vtypes) do
      if paramType == types.VTYPE_I64 then
        local lv = args[argIdx] or 0
        local hv = args[argIdx + 1] or 0
        handle.pushTyped(paramType, lv, hv)
        argIdx = argIdx + 2
      else
        local v = args[argIdx] or 0
        handle.pushTyped(paramType, v)
        argIdx = argIdx + 1
      end
    end
  end

  function handle.popTypedValues(vtypes)
    local numTypes = #vtypes
    local typeCount = #typeStack

    if typeCount < numTypes then
      return nil, STACK_EMPTY
    end

    local totalRaw = 0
    local typeStart = typeCount - numTypes
    for i = 1, numTypes do
      local expectedType = vtypes[i]
      if typeStack[typeStart + i] ~= expectedType then
        return nil, "Type Mismatch (Expected " .. tostring(expectedType) .. ")"
      end

      if expectedType == types.VTYPE_I64 then
        totalRaw = totalRaw + 2
      else
        totalRaw = totalRaw + 1
      end
    end

    local stackCount = #stack
    if stackCount < totalRaw then
      return nil, STACK_EMPTY
    end

    local args = {}
    local stackStart = stackCount - totalRaw
    for i = 1, totalRaw do
      args[i] = stack[stackStart + i]
    end

    for i = stackCount, stackStart + 1, -1 do
      stack[i] = nil
    end

    for i = typeCount, typeStart + 1, -1 do
      typeStack[i] = nil
    end

    return args
  end

  function handle.size()
    return #typeStack
  end

  return handle
end

return {
  createStack = create
}