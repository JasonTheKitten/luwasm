local streamutils = localRequire("lib/streamutils")
local instr = localRequire("lib/instructions")
local types = localRequire("lib/types")

local readU8, readU32, readInt, readArr, wrap_stream, readList
  = streamutils.readU8, streamutils.readU32, streamutils.readInt,
  streamutils.readArr, streamutils.wrapStream, streamutils.readList
local COMP_TYPE_FUNC, COMP_TYPE_MEM, VTYPE_F64, VTYPE_F32, VTYPE_I64, VTYPE_I32
  = types.COMP_TYPE_FUNC, types.COMP_TYPE_MEM, types.VTYPE_F64,
  types.VTYPE_F32, types.VTYPE_I64, types.VTYPE_I32

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

-- TODO: More types
local HEAP_TYPES = {
  [0x70] = COMP_TYPE_FUNC
}

-- TODO: Other types
local VAL_TYPES = MERGE_TABLES(NUM_TYPES)

-- Compress to a u32 block to save memory
local function u8BlockToU32Block(block)
  local compressed = {}
  for i = 1, #block, 4 do
    local b1 = block[i] or 0
    local b2 = block[i + 1] or 0
    local b3 = block[i + 2] or 0
    local b4 = block[i + 3] or 0
    local u4 = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
    table.insert(compressed, u4)
  end

  return compressed
end

local function readName(stream)
  local bytes, err = readList(stream, readU8)
  if not bytes then return nil, err end
  return string.char(table.unpack(bytes))
end

local function readExpr(stream)
  local val, err = readU8(stream)
  if not val then return nil, err end
  -- TODO: Other stuff (esp. since need to balance nested 0x0B)
  local bytes = {}
  while val ~= 0x0B do
    table.insert(bytes, val)
    val, err = readU8(stream)
    if not val then return nil, err end
  end

  return {
    data = u8BlockToU32Block(bytes),
    len = #bytes
  }
end

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

local function readResultType(stream)
  return readList(stream, readValType)
end

local function readComptype(stream)
  local subop = readU8(stream)
  -- TODO: Support other options
  if subop ~= 0x60 then
    return false, "Only func is supported at this time"
  end

  local params, err = readResultType(stream)
  if not params then return nil, err end

  local rtn, err = readResultType(stream)
  if not rtn then return nil, err end

  return {
    type = COMP_TYPE_FUNC,
    params = params,
    rtn = rtn
  }
end

local readRectype
function readRectype(stream)
  -- TODO: Support other options
  local comptype, err = readComptype(stream)
  if not comptype then return err end
  return {
    types = {{
      comptype
    }}
  }
end

local function readIdx(stream)
  return readInt(stream, 32)
end

local readTypeIdx = readIdx
local readFuncIdx = readIdx
local readMemIdx = readIdx

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

local function readImport(stream)
  local moduleName, err = readName(stream)
  if not moduleName then return nil, err end
  local itemName, err = readName(stream)
  if not itemName then return nil, err end
  local externIdx, err = readExternIdx(stream)
  if not externIdx then return nil, err end

  return {
    moduleName = moduleName,
    itemName = itemName,
    externType = externIdx
  }
end

local function readHeapType(stream)
  local subop, err = readU8(stream)
  if not subop then return nil, err end

  local type = HEAP_TYPES[subop]
  if not type then
    return false, "Only func is supported at this time"
  end

  return type
end

local function readLimits(stream)
  local subop, err = readU8(stream)
  if not subop then return nil, err end
  local min, err = readInt(stream, 64)
  local max, isExtended = nil, false
  if subop == 0x00 then
    -- Do nothing
  elseif subop == 0x01 then
    max, err = readInt(stream, 64)
    if not max then return nil, err end
  elseif subop == 0x04 then
    isExtended = true
  elseif subop == 0x01 then
    isExtended = true
    max, err = readInt(stream, 64)
    if not max then return nil, err end
  end

  return {
    isExtended = isExtended,
    min = min,
    max = max
  }
end

-- TODO: Properly implement this
local readRefType = readHeapType

local function readTable(stream)
  local type, err = readRefType(stream)
  if not type then return nil, err end
  local limit, err = readLimits(stream)
  if not limit then return nil, err end

  return {
    type = type,
    limit = limit
  }
end

local function readMemType(stream)
  local limit, err = readLimits(stream)
  if not limit then return nil, err end

  return {
    limit = limit
  }
end

local function readMut(stream)
  local val, err = readU8(stream)
  if not val then return nil, false, err end
  if val == 0 then
    return false, true
  elseif val == 1 then
    return true, true
  else
    return nil, false, "Invalid mut subop"
  end
end

local function readGlobalType(stream)
  local type, err = readValType(stream)
  if not type then return nil, err end
  local mutable, ok, err = readMut(stream)
  if not ok then return nil, err end

  return {
    type = type,
    mutable = mutable
  }
end

local function readGlobal(stream)
  local type, err = readGlobalType(stream)
  if not type then return nil, err end
  local expr, err = readExpr(stream)
  if not expr then return nil, err end

  return {
    type = type,
    expr = expr
  }
end

local function readExport(stream)
  local exportName, err = readName(stream)
  if not exportName then return nil, err end
  local externIdx, err = readExternIdx(stream)
  if not externIdx then return nil, err end

  return {
    name = exportName,
    type = externIdx
  }
end

local function readElem(stream)
  local subop, err = readInt(stream, 32)
  if not subop then return nil, err end
  
  if subop == 0 then
    local expr = readExpr(stream)
    local idxs = readList(stream, readFuncIdx)

    -- TODO: Is this the right way to handle this?
    local funcExpr = {}
    local funcExprPos = 1
    for _, idx in ipairs(idxs) do
      funcExprPos, err = instr.ref.func.write(funcExpr, funcExprPos, idx)
      if not funcExprPos then return nil, err end
    end

    return {
      type = COMP_TYPE_FUNC,
      active = true,
      elemExprs = funcExpr,
      tableidx = 0,
      modeExpr = expr
    }
  else
    return false, "Only func is supported at this time"
  end
end

local function readCode(stream)
  local code, err = readList(stream, readU8)
  if not code then return nil, err end
  local compressed = u8BlockToU32Block(code)

  return {
    codelen = #code,
    code = compressed
  }
end

local function readData(stream)
  local subop, err = readInt(stream, 32)
  if not subop then return nil, err end

  local active, memidx, expr, err = true, 0, nil, nil
  if subop == 0 then
    expr, err = readExpr(stream)
    if not expr then return nil, err end
  elseif subop == 1 then
    active = false
  elseif subop == 2 then
    memidx, err = readMemIdx(stream)
    if not memidx then return nil, err end
    expr, err = readExpr(stream)
    if not expr then return nil, err end
  else
    return false, "Invalid readData subop"
  end

  local data, err = readList(stream, readU8)
  if not data then return nil, err end
  local compressed = u8BlockToU32Block(data)

  return {
    active = active,
    memidx = memidx,
    expr = expr,
    datalen = #data,
    data = compressed
  }
end

local function readTagType(stream)
  local subop, err = readU8(stream)
  if not subop then return nil, err end
  if subop ~= 0 then
    return false, "Invalid tag type"
  end
  local typeidx, err = readTypeIdx(stream)
  if not typeidx then return nil, err end

  return {
    typeidx = typeidx
  }
end

local function skipSection(stream, len)
  local ok, err = readArr(stream, readU8, len)
  if not ok then return nil, err end
  return {}
end

local function readTypeSection(stream)
  local types, err = readList(stream, readRectype)
  if not types then return nil, err end
  return {
    types = types
  }
end

local function readImportSection(stream)
  local imports, err = readList(stream, readImport)
  if not imports then return nil, err end
  return {
    imports = imports
  }
end

local function readFunctionSection(stream)
  local funcs, err = readList(stream, readTypeIdx)
  if not funcs then return nil, err end
  return {
    funcs = funcs
  }
end

local function readTableSection(stream)
  local tables, err = readList(stream, readTable)
  if not tables then return nil, err end

  -- TODO: Support 0x40 0x00

  return {
    tables = tables
  }
end

local function readMemorySection(stream)
  local memories, err = readList(stream, readMemType)
  if not memories then return nil, err end
  return {
    memories = memories
  }
end

local function readGlobalSection(stream)
  local globals, err = readList(stream, readGlobal)
  if not globals then return nil, err end
  return {
    globals = globals
  }
end

local function readExportSection(stream)
  local exports, err = readList(stream, readExport)
  if not exports then return nil, err end
  return {
    exports = exports
  }
end

local function readElementSection(stream)
  local elems, err = readList(stream, readElem)
  if not elems then return nil, err end
  return {
    elements = elems
  }
end

local function readCodeSection(stream)
  local codes, err = readList(stream, readCode)
  if not codes then return nil, err end
  return {
    codes = codes
  }
end

local function readDataSection(stream)
  local dataSegments, err = readList(stream, readData)
  if not dataSegments then return nil, err end
  return {
    dataSegments = dataSegments
  }
end

local function readTagSection(stream)
  local tags, err = readList(stream, readTagType)
  if not tags then return nil, err end
  return {
    tags = tags
  }
end

local sectionReaders = {
  [0] = skipSection,
  [1] = readTypeSection,
  [2] = readImportSection,
  [3] = readFunctionSection,
  [4] = readTableSection,
  [5] = readMemorySection,
  [6] = readGlobalSection,
  [7] = readExportSection,
  [9] = readElementSection,
  [10] = readCodeSection,
  [11] = readDataSection,
  [13] = readTagSection
}

local function readSection(stream)
  local type, err = readU8(stream)
  if not type then return nil, err end
  local len, err = readInt(stream, 32)
  if not len then return nil, err end

  local reader = sectionReaders[type]
  if not reader then reader = sectionReaders[0] end
  local section, err = reader(stream, len)
  if not section then return nil, err end

  section.type = type
  return section
end

local function readNextSection(stream, sections, expected)
  local section, err = readSection(stream)
  if not section then return nil, err end
  while section.type == 0 do
    table.insert(sections, section)
    section, err = readSection(stream)
    if not section then return nil, err end
  end
  table.insert(sections, section)
  if expected ~= nil and expected ~= section.type then
    return false, "Expected section type " .. expected .. ", got " .. section.type
  end
  return section
end

local function maybeReadNextSection(stream, sections, expected)
  local pk = stream:peek()
  while pk == 0 do
    local section, err = readSection(stream)
    if not section then return nil, false, err end
    table.insert(sections, section)

    pk = stream:peek()
  end

  pk = stream:peek()
  if (pk ~= expected) then
    return nil, true
  end

  local section, err = readSection(stream)
  if not section then return nil, err end
  table.insert(sections, section)
  assert(expected == section.type)
  return section, true
end

local function readModule(stream)
  stream = wrap_stream(stream)

  local magic, err = readU32(stream)
  if not magic then return nil, err end
  if magic ~= 0x0061736D then
    return false, "Magic signature does not match"
  end

  local version, err = readU32(stream)
  if not version then return nil, err end
  if version ~= 0x01000000 then
    return false, "Only version 1 is supported"
  end

  local sections = {}
  local typeSection, err = readNextSection(stream, sections, 1)
  if not typeSection then return nil, err end
  local importSection, err = readNextSection(stream, sections, 2)
  if not importSection then return nil, err end
  local funcSection, err = readNextSection(stream, sections, 3)
  if not funcSection then return nil, err end
  local tableSection, err = readNextSection(stream, sections, 4)
  if not tableSection then return nil, err end
  local memorySection, err = readNextSection(stream, sections, 5)
  if not memorySection then return nil, err end
  local tagSection, err = readNextSection(stream, sections, 13)
  if not tagSection then return nil, err end
  local globalSection, err = readNextSection(stream, sections, 6)
  if not globalSection then return nil, err end
  local exportSection, err = readNextSection(stream, sections, 7)
  if not exportSection then return nil, err end
  local startSection, ok, err = maybeReadNextSection(stream, sections, 8)
  if not ok then return nil, err end
  local elemSection, err = readNextSection(stream, sections, 9)
  if not elemSection then return nil, err end
  local dataCntSection, ok, err = maybeReadNextSection(stream, sections, 12)
  if not ok then return nil, err end
  local codeSection, err = readNextSection(stream, sections, 10)
  if not codeSection then return nil, err end
  local dataSection, err = readNextSection(stream, sections, 11)
  if not dataSection then return nil, err end
  local _, ok, err = maybeReadNextSection(stream, sections, 0)
  if not ok then return err end

  return {
    sections = sections,
    typeSection = typeSection,
    importSection = importSection,
    funcSection = funcSection,
    tableSection = tableSection,
    memorySection = memorySection,
    tagSection = tagSection,
    globalSection = globalSection,
    exportSection = exportSection,
    startSection = startSection,
    elemSection = elemSection,
    dataCntSection = dataCntSection,
    codeSection = codeSection,
    dataSection = dataSection
  }
end

return {
  readModule = readModule
}