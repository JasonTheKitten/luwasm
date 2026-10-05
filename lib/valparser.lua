local streamutils = localRequire("lib/streamutils")
local types = localRequire("lib/types")

local readU8, readInt, readSInt = streamutils.readU8, streamutils.readInt, streamutils.readSInt
local
  COMP_TYPE_FUNC, COMP_TYPE_MEM, BLOCK_TYPE_EMPTY,
  VTYPE_F64, VTYPE_F32, VTYPE_I64, VTYPE_I32, 
  HTYPE_EXN
  = types.COMP_TYPE_FUNC, types.COMP_TYPE_FUNC, types.BLOCK_TYPE_EMPTY,
  types.VTYPE_F64, types.VTYPE_F32, types.VTYPE_I64, types.VTYPE_I32,
  types.HTYPE_EXN

local function MERGE_TABLES(...)
  local new = {}
  for _, v in ipairs({...}) do
    for k, v2 in pairs(v) do
      new[k] = v2
    end
  end

  return new
end

local NUM_TYPES = {
  [VTYPE_F64] = VTYPE_F64,
  [VTYPE_F32] = VTYPE_F32,
  [VTYPE_I64] = VTYPE_I64,
  [VTYPE_I32] = VTYPE_I32
}

local HEAP_TYPES = {
  [HTYPE_EXN] = HTYPE_EXN
}

-- TODO: Other types
local VAL_TYPES = MERGE_TABLES(NUM_TYPES, HEAP_TYPES)

local function readValType(stream)
  -- TODO: Support other options
  local subop, err = readU8(stream)
  if not subop then return nil, err end
  local type = VAL_TYPES[subop]
  if not type then
    return false, "Only num types supported at this time"
  end

  return type
end

local function readBlockType(stream)
  local pk = stream:peek(1)
  if pk == 0x40 then
    stream:read(1)
    return BLOCK_TYPE_EMPTY
  elseif VAL_TYPES[pk] then
    return readValType(stream)
  else
    -- TODO: Ensure that it is signed
    local i, err = readSInt(stream, 33)
    if not i then return err end
    if i < 0 then
      return nil, "Block typeidx must be positive"
    end
    return true, i
  end
end

---

local function readIdx(stream)
  return readInt(stream, 32)
end

local readTypeIdx = readIdx
local readFuncIdx = readIdx
local readMemIdx = readIdx
local readGlobalIdx = readIdx
local readTagIdx = readIdx
local readDataIdx = readIdx
local readLocalIdx = readIdx
local readLabelIdx = readIdx

local function readExternIdx(stream)
  local subop, err = readU8(stream)
  if not subop then return nil, err end
  -- TODO: Support other options
  local type
  if subop == 0x00 then
    type = COMP_TYPE_FUNC
  elseif subop == 0x02 then
    type = COMP_TYPE_MEM
  else
    return false, "Only func is supported at this time"
  end

  local idx = readInt(stream, 32)

  return {
    type = type,
    idx = idx
  }
end

return {
  readValType = readValType,
  readBlockType = readBlockType,
  readTypeIdx = readTypeIdx,
  readFuncIdx = readFuncIdx,
  readMemIdx = readMemIdx,
  readGlobalIdx = readGlobalIdx,
  readTagIdx = readTagIdx,
  readDataIdx = readDataIdx,
  readExternIdx = readExternIdx,
  readLocalIdx = readLocalIdx,
  readLabelIdx = readLabelIdx
}