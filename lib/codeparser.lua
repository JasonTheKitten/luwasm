local streamutils = localRequire("lib/streamutils")
local valparser = localRequire("lib/valparser")
local types = localRequire("lib/types")

local readU8, readInt, readList
  = streamutils.readU8, streamutils.readInt, streamutils.readList
local readValType, readMemIdx, readTagIdx, readLabelIdx
  = valparser.readValType, valparser.readMemIdx, valparser.readTagIdx, valparser.readLabelIdx

local function readLocals(stream)
  local locals, err = readU8(stream)
  if not locals then return nil, err end

  local loc, err = readValType(stream)
  if not loc then return nil, err end

  return locals
end

local function readNumLocals(stream)
  local localsList, err = readList(stream, readLocals)
  if not localsList then return nil, err end

  local numLocals = 0
  for _, v in ipairs(localsList) do
    numLocals = numLocals + v
  end

  return numLocals
end

local function readMemArg(stream)
  local align = readInt(stream, 32)
  local memidx = 0
  if align >= 64 then
    align = align - 64
    memidx = readMemIdx(stream)
  end
  -- TODO: Split bytes in the future
  local m = readInt(stream, 64)
  return align, memidx, m
end

local function readCatch(stream)
  local subop, err = readU8(stream)
  if not subop then return nil, err end

  local type, tagidx
  if subop == 0 then
    type = types.CTYPE_CATCH
    tagidx, err = readTagIdx(stream)
    if not tagidx then return nil, err end
  elseif subop == 1 then
    type = types.CTYPE_CATCH_REF
    tagidx, err = readTagIdx(stream)
    if not tagidx then return nil, err end
  elseif subop == 2 then
    type = types.CTYPE_CATCH_ALL
  elseif subop == 3 then
    type = types.CTYPE_CATCH_ALL_REF
  else
    return nil, "Unknown catch type"
  end

  local labelidx, err = readLabelIdx(stream)
  if not labelidx then return nil, err end

  return {
    type = type,
    tagidx = tagidx,
    labelidx = labelidx
  }
end

local function readCatches(stream)
  return readList(stream, readCatch)
end

return {
  readNumLocals = readNumLocals,
  readMemArg = readMemArg,
  readCatches = readCatches
}