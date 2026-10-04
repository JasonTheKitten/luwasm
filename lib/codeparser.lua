local streamutils = localRequire("lib/streamutils")
local valparser = localRequire("lib/valparser")

local readU8, readInt, readList
  = streamutils.readU8, streamutils.readInt, streamutils.readList
local readValType, readMemIdx = valparser.readValType, valparser.readMemIdx

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

return {
  readNumLocals = readNumLocals,
  readMemArg = readMemArg
}