local streamutils = localRequire("lib/streamutils")
local codeparser = localRequire("lib/codeparser")
local numbers = localRequire("lib/numbers")
local valparser = localRequire("lib/valparser")
local types = localRequire("lib/types")
local instructionsls = localRequire("lib/instructionsls")

local readU32, readSInt = streamutils.readU32, streamutils.readSInt
local readCatches = codeparser.readCatches
local readBlockType, readTypeIdx, readFuncIdx, readMemIdx, readGlobalIdx, readTableIdx,
  readTagIdx, readDataIdx, readLocalIdx, readLabelIdx
  = valparser.readBlockType, valparser.readTypeIdx, valparser.readFuncIdx, valparser.readMemIdx, valparser.readGlobalIdx,
  valparser.readTableIdx, valparser.readTagIdx, valparser.readDataIdx, valparser.readLocalIdx, valparser.readLabelIdx
local load32, load64, store32, store64, loadF32, storeF32, loadF64, storeF64
  = instructionsls.load32, instructionsls.load64, instructionsls.store32, instructionsls.store64,
  instructionsls.loadF32, instructionsls.storeF32, instructionsls.loadF64, instructionsls.storeF64

local NO_JUMP_POS = "No recorded jump pos"

local SYMBOL_BR = {}
local SYMBOL_RETURN = {}
local SYMBOL_THROW = {}

local I33 = 0x100000000

local instr = {}

local function unop(op, f1, f2)
  if op == nil then error("A") end
  local inst = {}
  function inst.evaluate(_, context)
    local stack = context.stack
    local c1, c2 = stack[f1]()
    if not c1 then return nil, c2 end
    local v1, v2 = op(c1, c2)
    if v1 == nil then return nil, v2 end
    stack[f2](v1, v2)
    return true
  end
  function inst.collectArgs()
    return true
  end
  return inst
end

local function binop1(op, f1, f2)
  local inst = {}
  function inst.evaluate(_, context)
    local stack = context.stack
    local c2, err = stack[f1]()
    if not c2 then return nil, err end
    local c1, err = stack[f1]()
    if not c1 then return nil, err end
    local res, err = op(c1, c2)
    if res == nil then return nil, err end
    stack[f2](res)
    return true
  end
  function inst.collectArgs()
    return true
  end
  return inst
end

local function binop2(op, f1, f2)
  local inst = {}
  function inst.evaluate(_, context)
    local stack = context.stack
    local c2l, c2h = stack[f1]()
    if not c2l then return nil, c2h end
    local c1l, c1h = stack[f1]()
    if not c1l then return nil, c1h end
    local vl, vh = op(c1l, c1h, c2l, c2h)
    if vl == nil then return nil, vh end
    stack[f2](vl, vh)
    return true
  end
  function inst.collectArgs()
    return true
  end
  return inst
end

local function unopI32(op)
  return unop(op, "popI32", "pushI32")
end

local function binopI32(op)
  return binop1(op, "popI32", "pushI32")
end

local function testopI32(op)
  return unopI32(function(a)
    local val, err = op(a)
    if val == nil then return nil, err end
    return val and 1 or 0
  end)
end

local function relopI32(op)
  return binopI32(function(a, b)
    local val, err = op(a, b)
    if val == nil then return nil, err end
    return val and 1 or 0
  end)
end

local function unopI64(op)
  return unop(op, "popI64", "pushI64")
end

local function binopI64(op)
  return binop2(op, "popI64", "pushI64")
end

local function testopI64(op)
  return unop(function(al, ah)
    local val, err = op(al, ah)
    if val == nil then return nil, err end
    return val and 1 or 0
  end, "popI64", "pushI32")
end

local function relopI64(op)
  return binop2(function(al, ah, bl, bh)
    local val, err = op(al, ah, bl, bh)
    if val == nil then return nil, err end
    return val and 1 or 0
  end, "popI64", "pushI32")
end

local function unopF32(op)
  return unop(op, "popF32", "pushF32")
end

local function binopF32(op)
  return binop1(op, "popF32", "pushF32")
end

local function relopF32(op)
  return binop1(function(a, b)
    local val, err = op(a, b)
    if val == nil then return nil, err end
    return val and 1 or 0
  end, "popF32", "pushI32")
end

local function unopF64(op)
  return unop(op, "popF64", "pushF64")
end

local function binopF64(op)
  return binop1(op, "popF64", "pushF64")
end

local function relopF64(op)
  return binop1(function(a, b)
    local val, err = op(a, b)
    if val == nil then return nil, err end
    return val and 1 or 0
  end, "popF64", "pushI32")
end

instr._ = {}
instr._.block_end = {}
instr._.block_end.evaluate = function()
  return nil, "Block end should be skipped"
end
instr._.block_end.collectArgs = function()
  return true
end

instr._["else"] = {}
instr._["else"].evaluate = function()
  return nil, "Block end should be skipped"
end
instr._["else"].collectArgs = function()
  return true
end
instr._["else"].blockEnds = { 0x0B }

instr.nop = {}
instr.nop.evaluate = function()
  return true
end
instr.nop.collectArgs = function()
  return true
end

instr.unreachable = {}
instr.unreachable.evaluate = function()
  return nil, "Unreachable instruction reached"
end
instr.unreachable.collectArgs = function()
  return true
end

instr.drop = {}
instr.drop.evaluate = function(_, context)
  local stack = context.stack
  stack.drop()
  return true
end
instr.drop.collectArgs = function()
  return true
end

instr.select = {}
instr.select.evaluate = function(_, context)
  local stack = context.stack
  local c, err = stack.popI32()
  if not c then return nil, err end
  local v2, err = stack.popLocal()
  if not v2 then return nil, err end
  local v1, err = stack.popLocal()
  if not v1 then return nil, err end
  if c ~= 0 then
    stack.pushLocal(v1)
  else
    stack.pushLocal(v2)
  end

  return true
end
instr.select.collectArgs = function()
  return true
end

instr.select_t = {}
instr.select_t.evaluate = instr.select.evaluate
instr.select_t.collectArgs = function(stream)
  return codeparser.readValTypeList(stream)
end

instr.block = {}
instr.block.evaluate = function(stream, context, blockType1, blockType2)
  if not blockType1 then return nil, blockType2 end
  local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
  if not ok then return nil, err end
  return true
end
instr.block.collectArgs = function(stream)
  return readBlockType(stream)
end
instr.block.blockEnds = { 0x0B }

instr.loop = {}
instr.loop.evaluate = function(stream, context, blockType1, blockType2)
  if not blockType1 then return nil, blockType2 end
  local startPos = stream:pos()
  while true do
    local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2, false, true)
    if not ok then return nil, err end
    if err == false then return true end
    stream:seek(startPos)
  end
end
instr.loop.collectArgs = function(stream)
  return readBlockType(stream)
end
instr.loop.blockEnds = { 0x0B }

instr["if"] = {}
instr["if"].evaluate = function(stream, context, blockType1, blockType2)
  if not blockType1 then return nil, blockType2 end
  
  local stack = context.stack
  local c, err = stack.popI32()
  if not c then return nil, err end
  if c ~= 0 then
    local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2, true)
    if not ok then return nil, err end
    local jumpPos = context.frame.jumpMap[stream:pos()]
    if jumpPos then
      stream:seek(jumpPos + 1)
    end
  else
    local jumpPos = context.frame.jumpMap[stream:pos()]
    if not jumpPos then return nil, NO_JUMP_POS end
    stream:seek(jumpPos)
    local elseOp, err = stream:read(1)
    if not elseOp then return nil, err end

    if elseOp:byte() == 0x05 then
      local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
      if not ok then return nil, err end
    end
  end

  return true
end
instr["if"].collectArgs = function(stream)
  return readBlockType(stream)
end
instr["if"].blockEnds = { 0x05, 0x0B }

local throwRef

instr.throw = {}
instr.throw.evaluate = function(_, context, tagidx, err)
  if not tagidx then return nil, err end
  local tag = context.tags[tagidx + 1]
  if not tag then
    return nil, "Tag not defined"
  end

  local stack = context.stack
  local values = { stack.unpack(stack.size() + 1 - #tag.type) }
  -- TODO: Assert types equal
  local exn = { tag = tag, tagidx = tagidx, values = values }
  stack.pushExn(exn)

  return throwRef()
end
instr.throw.collectArgs = function(stream)
  return readTagIdx(stream)
end

instr.throw_ref = {}
instr.throw_ref.evaluate = function()
  return nil, { symbol = SYMBOL_THROW }
end
instr.throw_ref.collectArgs = function()
  return true
end
throwRef = instr.throw_ref.evaluate

instr.br = {}
instr.br.evaluate = function(_, _, depth, err)
  if not depth then return nil, err end
  return nil, { symbol = SYMBOL_BR, depth = depth }
end
instr.br.collectArgs = function(stream)
  return readLabelIdx(stream)
end

instr.br_if = {}
instr.br_if.evaluate = function(_, context, depth, err)
  if not depth then return nil, err end
  local stack = context.stack
  local c, err = stack.popI32()
  if not c then return nil, err end
  if c ~= 0 then
    return nil, { symbol = SYMBOL_BR, depth = depth }
  end
  return true
end
instr.br_if.collectArgs = function(stream)
  return readLabelIdx(stream)
end

instr["return"] = {}
instr["return"].evaluate = function()
  return nil, { symbol = SYMBOL_RETURN }
end
instr["return"].collectArgs = function()
  return true
end

instr.call = {}
instr.call.evaluate = function(_, context, funcidx, err)
  if not funcidx then return nil, err end
  local func = context.functions[funcidx + 1]
  if not func then
    return nil, "Function not defined"
  end
  return func(context)
end
instr.call.collectArgs = function(stream)
  return readFuncIdx(stream)
end

instr.call_indirect = {}
instr.call_indirect.evaluate = function(stream, context, typeidx, tableidx)
  -- TODO: Call local copy of instructions
  if not typeidx then return nil, tableidx end
  local ok, err = instr.table.get.evaluate(stream, context, tableidx)
  if not ok then return nil, err end
  -- TODO: Do the cast and stuff
  return instr.call_ref.evaluate(stream, context, typeidx)
end
instr.call_indirect.collectArgs = function(stream)
  local typeIdx, err = readTypeIdx(stream)
  if not typeIdx then return nil, err end
  local tableIdx, err = readTableIdx(stream)
  if not tableIdx then return nil, err end
  return typeIdx, tableIdx
end

instr.call_ref = {}
instr.call_ref.evaluate = function(stream, context, typeidx, err)
  -- TODO: Properly handle types
  if not typeidx then return nil, err end
  local ref, err = context.stack.popLocal()
  if not ref then return nil, err end
  if ref.type == types.RTYPE_NULL then
    return nil, "Null reference"
  end
  if ref.type ~= types.RTYPE_FUNC then
    return nil, "Expected function reference"
  end
  return instr.call.evaluate(stream, context, ref.value)
end
instr.call_ref.collectArgs = function(stream)
  return readTypeIdx(stream)
end

-- TODO: This almost certainly isn't proper
local function handleException(context, catches)
  local stack = context.stack
  if stack.isType(types.RTYPE_NULL) then
    return nil, "Exception cannot be null"
  elseif stack.isType(types.HTYPE_EXN) then
    local exn = stack.popExn()
    for _, v in ipairs(catches) do
      if v.type == types.CTYPE_CATCH and v.tagidx == exn.tagidx then
        stack.pushTypedValues(exn.values, exn.tag.type)
        return nil, { symbol = SYMBOL_BR, depth = v.labelidx }
      elseif v.type == types.CTYPE_CATCH_ALL then
        return nil, { symbol = SYMBOL_BR, depth = v.labelidx }
      elseif v.type == types.CTYPE_CATCH_REF and v.tagidx == exn.tagidx then
        stack.pushTypedValues(exn.values, exn.tag.type)
        stack.pushExn(exn)
        return nil, { symbol = SYMBOL_BR, depth = v.labelidx }
      elseif v.type == types.CTYPE_CATCH_ALL_REF then
        stack.pushExn(exn)
        return nil, { symbol = SYMBOL_BR, depth = v.labelidx }
      end
    end

    stack.pushExn(exn)
    return nil, { symbol = SYMBOL_THROW }
  else
    -- TODO: Handle this elsewhere
    return nil, { symbol = SYMBOL_THROW }
  end
end

instr.try_table = {}
instr.try_table.evaluate = function(stream, context, blockType1, blockType2, catches)
  if not blockType1 then return nil, blockType2 end
  local ok, err = context.evaluateBlock(stream, context, blockType1, blockType2)
  if not ok and type(err) == "table" and err.symbol == SYMBOL_THROW then
    return handleException(context, catches)
  end

  return ok, err
end
instr.try_table.collectArgs = function(stream)
  local blockType1, blockType2 = readBlockType(stream)
  if not blockType1 then return nil, blockType2 end
  local catches, err = readCatches(stream)
  if not catches then return nil, err end
  return blockType1, blockType2, catches
end
instr.try_table.blockEnds = { 0x0B }

instr["local"] = {}
instr["local"].get = {}
instr["local"].get.evaluate = function(_, context, localIdx, err)
  if not localIdx then return nil, err end
  local loc = context.frame.locals[localIdx + 1]
  if not loc then
    return nil, "Local not defined"
  end
  context.stack.pushLocal(loc)
  return true
end
instr["local"].get.collectArgs = function(stream)
  return readLocalIdx(stream)
end

instr["local"].set = {}
instr["local"].set.evaluate = function(_, context, localIdx, err)
  if not localIdx then return nil, err end
  local stack = context.stack
  local loc, err = stack.popLocal()
  if not loc then return nil, err end
  context.frame.locals[localIdx + 1] = loc
  return true
end
instr["local"].set.collectArgs = function(stream)
  return readLocalIdx(stream)
end

instr["local"].tee = {}
instr["local"].tee.evaluate = function(_, context, localIdx, err)
  if not localIdx then return nil, err end
  local stack = context.stack
  local loc, err = stack.toLocal()
  if not loc then return nil, err end
  context.frame.locals[localIdx + 1] = loc
  return true
end
instr["local"].tee.collectArgs = function(stream)
  return readLocalIdx(stream)
end

instr.global = {}
instr.global.get = {}
instr.global.get.evaluate = function(_, context, globalidx, err)
  if not globalidx then return nil, err end
  local global = context.globals[globalidx + 1]
  if not global then
    return nil, "Global not defined"
  end
  context.stack.pushLocal(global)
  return true
end
instr.global.get.collectArgs = function(stream)
  return readGlobalIdx(stream)
end

instr.global.set = {}
instr.global.set.evaluate = function(_, context, globalidx, err)
  if not globalidx then return nil, err end
  local global = context.globals[globalidx + 1]
  if not global then
    return nil, "Global not defined"
  end
  if not global.mutable then
    return nil, "Global is not mutable"
  end

  local newGlobal, err = context.stack.popLocal(global)
  if not newGlobal then return nil, err end

  if newGlobal.type ~= global.type then
    return nil, "Global type mismatch"
  end
  global.value = newGlobal.value
  global.value2 = newGlobal.value2

  return true
end
instr.global.set.collectArgs = function(stream)
  return readGlobalIdx(stream)
end

instr.table = {}
instr.table.get = {}
instr.table.get.evaluate = function(_, context, tableidx, err)
  if not tableidx then return nil, err end
  local stack = context.stack
  local iL, err = stack.popLocal()
  if not iL then return nil, err end
  local i = iL.value
  local tables = context.tables
  if tableidx >= #tables then
    return nil, "Table not defined"
  end
  local mtbl = tables[tableidx + 1]
  if i >= #mtbl.refs then
    return nil, "Invalid table index"
  end
  stack.pushLocal(mtbl.refs[i + 1])
  return true
end
instr.table.get.collectArgs = function(stream)
  return readTableIdx(stream)
end

instr.ref = {}
instr.ref.func = {}
instr.ref.func.new = function(funcidx)
  return {
    type = types.RTYPE_FUNC,
    value = funcidx
  }
end

instr.i32 = {}
instr.i32.load = load32("u32", false)
instr.i32.load8_s = load32("u8", true)
instr.i32.load8_u = load32("u8", false)
instr.i32.load16_s = load32("u16", true)
instr.i32.load16_u = load32("u16", false)
instr.i32.store = store32("writeU32")
instr.i32.store8 = store32("writeU8")
instr.i32.store16 = store32("writeU16")

instr.i64 = {}
instr.i64.load = load64("u64", false)
instr.i64.load8_s = load64("u8", true)
instr.i64.load8_u = load64("u8", false)
instr.i64.load16_s = load64("u16", true)
instr.i64.load16_u = load64("u16", false)
instr.i64.load32_s = load64("u32", true)
instr.i64.load32_u = load64("u32", false)
instr.i64.store = store64("writeU64")
instr.i64.store8 = store64("writeU8")
instr.i64.store16 = store64("writeU16")
instr.i64.store32 = store64("writeU32")

instr.f32 = {}
instr.f32.load = loadF32()
instr.f32.store = storeF32()

instr.f64 = {}
instr.f64.load = loadF64()
instr.f64.store = storeF64()

instr.memory = {}
instr.memory.init = {}
instr.memory.init.evaluate = function(_, context, dataidx, memidx)
  if not dataidx then return nil, memidx end

  local stack = context.stack
  local len, err = stack.popI32()
  if not len then return nil, err end
  local dataOffset, err = stack.popI32()
  if not dataOffset then return nil, err end
  local memOffset, err = stack.popI32()
  if not memOffset then return nil, err end

  local memory = context.memories[memidx + 1]
  local data = context.data[dataidx + 1]
  if dataOffset + len > data.datalen then
    return nil, "Data access out-of-bounds"
  end

  local ok, err = memory.writeU32Bytes(data.data, dataOffset + 1, memOffset, len)
  if not ok then return false, err end

  return true
end
instr.memory.init.collectArgs = function(stream)
  local dataidx, err = readDataIdx(stream)
  if not dataidx then return nil, err end
  local memidx, err = readMemIdx(stream)
  if not memidx then return nil, err end
  return dataidx, memidx
end

instr.memory.size = {}
instr.memory.size.evaluate = function(_, context, memidx, err)
  if not memidx then return nil, err end

  local memory = context.memories[memidx + 1]
  context.stack.pushI32(memory.sizePages())
  return true
end
instr.memory.size.collectArgs = function(stream)
  return readMemIdx(stream)
end

instr.memory.grow = {}
instr.memory.grow.evaluate = function(_, context, memidx, err)
  if not memidx then return nil, err end

  local deltaPages, err = context.stack.popI32()
  if not deltaPages then return nil, err end

  local memory = context.memories[memidx + 1]
  local oldPages = memory.growPages(deltaPages, memory.maxPages)
  context.stack.pushI32(oldPages)
  return true
end
instr.memory.collectArgs = function(stream)
  return readMemIdx(stream)
end

instr.memory.copy = {}
instr.memory.copy.evaluate = function(_, context, destMemIdx, srcMemIdx)
  if not destMemIdx then return nil, srcMemIdx end

  local len, err = context.stack.popI32()
  if not len then return nil, err end
  local srcOffset, err = context.stack.popI32()
  if not srcOffset then return nil, err end
  local destOffset, err = context.stack.popI32()
  if not destOffset then return nil, err end

  local destMem = context.memories[destMemIdx + 1]
  local srcMem = context.memories[srcMemIdx + 1]

  local ok, err = destMem.copyMemBytes(srcMem, srcOffset, destOffset, len)
  if not ok then return nil, err end
  return true
end
instr.memory.copy.collectArgs = function(stream)
  local destMemIdx, err = readMemIdx(stream)
  if not destMemIdx then return nil, err end
  local srcMemIdx, err = readMemIdx(stream)
  if not srcMemIdx then return nil, err end
  return destMemIdx, srcMemIdx
end

instr.memory.fill = {}
instr.memory.fill.evaluate = function(_, context, memidx, err)
  if not memidx then return nil, err end

  local len, err = context.stack.popI32()
  if not len then return nil, err end
  local val, err = context.stack.popI32()
  if not val then return nil, err end
  local destOffset, err = context.stack.popI32()
  if not destOffset then return nil, err end

  local memory = context.memories[memidx + 1]
  local ok, err = memory.fillMemBytes(destOffset, val, len)
  if not ok then return nil, err end
  return true
end
instr.memory.fill.collectArgs = function(stream)
  return readMemIdx(stream)
end

instr.data = {}
instr.data.drop = {}
instr.data.drop.evaluate = function(_, context, dataidx, err)
  if not dataidx then return nil, err end
  local dataSegment = context.data[dataidx + 1]
  if dataSegment then
    dataSegment.data = {}
    dataSegment.datalen = 0
  end
  return true
end
instr.data.drop.collectArgs = function(stream)
  return readDataIdx(stream)
end

instr.i32.const = {}
instr.i32.const.evaluate = function(_, context, val, err)
  if not val then return nil, err end
  local stack = context.stack
  stack.pushI32(val)
  return true
end
instr.i32.const.collectArgs = function(stream)
  return readSInt(stream, 32) % I33
end

instr.i32.eqz = testopI32(numbers.i32.eqz)
instr.i32.eq = relopI32(numbers.i32.eq)
instr.i32.ne = relopI32(numbers.i32.ne)
instr.i32.lt_s = relopI32(numbers.i32.lt_s)
instr.i32.lt_u = relopI32(numbers.i32.lt_u)
instr.i32.gt_s = relopI32(numbers.i32.gt_s)
instr.i32.gt_u = relopI32(numbers.i32.gt_u)
instr.i32.le_s = relopI32(numbers.i32.le_s)
instr.i32.le_u = relopI32(numbers.i32.le_u)
instr.i32.ge_s = relopI32(numbers.i32.ge_s)
instr.i32.ge_u = relopI32(numbers.i32.ge_u)

instr.i32.clz = unopI32(numbers.i32.ctz)
instr.i32.ctz = unopI32(numbers.i32.ctz)
instr.i32.popcnt = unopI32(numbers.i32.popcnt)

instr.i32.add = binopI32(numbers.i32.add)
instr.i32.sub = binopI32(numbers.i32.sub)
instr.i32.mul = binopI32(numbers.i32.mul)
instr.i32.div_s = binopI32(numbers.i32.div_s)
instr.i32.div_u = binopI32(numbers.i32.div_u)
instr.i32.rem_s = binopI32(numbers.i32.rem_s)
instr.i32.rem_u = binopI32(numbers.i32.rem_u)

instr.i32["and"] = binopI32(numbers.i32["and"])
instr.i32["or"] = binopI32(numbers.i32["or"])
instr.i32.xor = binopI32(numbers.i32.xor)
instr.i32.shl = binopI32(numbers.i32.shl)
instr.i32.shr_s = binopI32(numbers.i32.shr_s)
instr.i32.shr_u = binopI32(numbers.i32.shr_u)
instr.i32.rotl = binopI32(numbers.i32.rotl)
instr.i32.rotr = binopI32(numbers.i32.rotr)

instr.i32.wrap_i64 = unop(numbers.i32.wrap_i64, "popI64", "pushI32")
instr.i32.trunc_f32_s = unop(numbers.i32.trunc_f32_s, "popF32", "pushI32")
instr.i32.trunc_f32_u = unop(numbers.i32.trunc_f32_u, "popF32", "pushI32")
instr.i32.trunc_f64_s = unop(numbers.i32.trunc_f64_s, "popF64", "pushI32")
instr.i32.trunc_f64_u = unop(numbers.i32.trunc_f64_u, "popF64", "pushI32")
instr.i32.reinterpret_f32 = unop(numbers.i32.reinterpret_f32, "popF32", "pushI32")

instr.i32.extend8_s = unopI32(numbers.i32.extend8_s)
instr.i32.extend16_s = unopI32(numbers.i32.extend16_s)

instr.i32.trunc_sat_f32_s = unop(numbers.i32.trunc_sat_f32_s, "popF32", "pushI32")
instr.i32.trunc_sat_f32_u = unop(numbers.i32.trunc_sat_f32_u, "popF32", "pushI32")
instr.i32.trunc_sat_f64_s = unop(numbers.i32.trunc_sat_f64_s, "popF64", "pushI32")
instr.i32.trunc_sat_f64_u = unop(numbers.i32.trunc_sat_f64_u, "popF64", "pushI32")

instr.i64.const = {}
instr.i64.const.evaluate = function(_, context, lh, hh)
  if not lh then return nil, hh end
  local stack = context.stack
  stack.pushI64(lh, hh)
  return true
end
instr.i64.const.collectArgs = function(stream)
  local lh, hh = readSInt(stream, 64)
  if not lh then return nil, hh end
  return lh % I33, hh % I33
end

instr.i64.eqz = testopI64(numbers.i64.eqz)
instr.i64.eq = relopI64(numbers.i64.eq)
instr.i64.ne = relopI64(numbers.i64.ne)
instr.i64.lt_s = relopI64(numbers.i64.lt_s)
instr.i64.lt_u = relopI64(numbers.i64.lt_u)
instr.i64.gt_s = relopI64(numbers.i64.gt_s)
instr.i64.gt_u = relopI64(numbers.i64.gt_u)
instr.i64.le_s = relopI64(numbers.i64.le_s)
instr.i64.le_u = relopI64(numbers.i64.le_u)
instr.i64.ge_s = relopI64(numbers.i64.ge_s)
instr.i64.ge_u = relopI64(numbers.i64.ge_u)

instr.i64.clz = unopI64(numbers.i64.clz)
instr.i64.ctz = unopI64(numbers.i64.ctz)
instr.i64.popcnt = unopI64(numbers.i64.popcnt)

instr.i64.add = binopI64(numbers.i64.add)
instr.i64.sub = binopI64(numbers.i64.sub)
instr.i64.mul = binopI64(numbers.i64.mul)
instr.i64.div_s = binopI64(numbers.i64.div_s)
instr.i64.div_u = binopI64(numbers.i64.div_u)
instr.i64.rem_s = binopI64(numbers.i64.rem_s)
instr.i64.rem_u = binopI64(numbers.i64.rem_u)

instr.i64["and"] = binopI64(numbers.i64["and"])
instr.i64["or"] = binopI64(numbers.i64["or"])
instr.i64.xor = binopI64(numbers.i64.xor)
instr.i64.shl = binopI64(numbers.i64.shl)
instr.i64.shr_s = binopI64(numbers.i64.shr_s)
instr.i64.shr_u = binopI64(numbers.i64.shr_u)
instr.i64.rotl = binopI64(numbers.i64.rotl)
instr.i64.rotr = binopI64(numbers.i64.rotr)

instr.i64.extend_i32_s = unop(numbers.i64.extend_i32_s, "popI32", "pushI64")
instr.i64.extend_i32_u = unop(numbers.i64.extend_i32_u, "popI32", "pushI64")
instr.i64.trunc_f32_s = unop(numbers.i64.trunc_f32_s, "popF32", "pushI64")
instr.i64.trunc_f32_u = unop(numbers.i64.trunc_f32_u, "popF32", "pushI64")
instr.i64.trunc_f64_s = unop(numbers.i64.trunc_f64_s, "popF64", "pushI64")
instr.i64.trunc_f64_u = unop(numbers.i64.trunc_f64_u, "popF64", "pushI64")
instr.i64.reinterpret_f64 = unop(numbers.i64.reinterpret_f64, "popF64", "pushI64")

instr.i64.extend8_s = unopI64(numbers.i64.extend8_s)
instr.i64.extend16_s = unopI64(numbers.i64.extend16_s)
instr.i64.extend32_s = unopI64(numbers.i64.extend_i32_s)

instr.i64.trunc_sat_f32_s = unop(numbers.i64.trunc_sat_f32_s, "popF32", "pushI64")
instr.i64.trunc_sat_f32_u = unop(numbers.i64.trunc_sat_f32_u, "popF32", "pushI64")
instr.i64.trunc_sat_f64_s = unop(numbers.i64.trunc_sat_f64_s, "popF64", "pushI64")
instr.i64.trunc_sat_f64_u = unop(numbers.i64.trunc_sat_f64_u, "popF64", "pushI64")

instr.f32.const = {}
instr.f32.const.evaluate = function(_, context, val, err)
  if not val then return nil, err end
  local stack = context.stack
  stack.pushF32(val)
  return true
end
instr.f32.const.collectArgs = function(stream)
  local bits, err = readU32(stream)
  if not bits then return nil, err end
  return numbers.f32.reinterpret_i32(bits)
end

instr.f32.eq = relopF32(numbers.f32.eq)
instr.f32.ne = relopF32(numbers.f32.ne)
instr.f32.lt = relopF32(numbers.f32.lt)
instr.f32.gt = relopF32(numbers.f32.gt)
instr.f32.le = relopF32(numbers.f32.le)
instr.f32.ge = relopF32(numbers.f32.ge)

instr.f32.abs = unopF32(numbers.f32.abs)
instr.f32.neg = unopF32(numbers.f32.neg)
instr.f32.ceil = unopF32(numbers.f32.ceil)
instr.f32.floor = unopF32(numbers.f32.floor)
instr.f32.trunc = unopF32(numbers.f32.trunc)
instr.f32.nearest = unopF32(numbers.f32.nearest)
instr.f32.sqrt = unopF32(numbers.f32.sqrt)

instr.f32.add = binopF32(numbers.f32.add)
instr.f32.sub = binopF32(numbers.f32.sub)
instr.f32.mul = binopF32(numbers.f32.mul)
instr.f32.div = binopF32(numbers.f32.div)
instr.f32.min = binopF32(numbers.f32.min)
instr.f32.max = binopF32(numbers.f32.max)
instr.f32.copysign = binopF32(numbers.f32.copysign)

instr.f32.convert_i32_s = unop(numbers.f32.convert_i32_s, "popI32", "pushF32")
instr.f32.convert_i32_u = unop(numbers.f32.convert_i32_u, "popI32", "pushF32")
instr.f32.convert_i64_s = unop(numbers.f32.convert_i64_s, "popI64", "pushF32")
instr.f32.convert_i64_u = unop(numbers.f32.convert_i64_u, "popI64", "pushF32")
instr.f32.demote_f64 = unop(numbers.f32.demote_f64, "popF64", "pushF32")
instr.f32.reinterpret_i32 = unop(numbers.f32.reinterpret_i32, "popI32", "pushF32")

instr.f64.const = {}
instr.f64.const.evaluate = function(_, context, val, err)
  if not val then return nil, err end
  local stack = context.stack
  stack.pushF64(val)
  return true
end
instr.f64.const.collectArgs = function(stream)
  local low, err = readU32(stream)
  if not low then return nil, err end

  local high, err2 = readU32(stream)
  if not high then return nil, err2 end

  return numbers.f64.reinterpret_i64(low, high)
end

-- Float64 uses the xop32 functions despite being 64 bit
instr.f64.eq = relopF64(numbers.f64.eq)
instr.f64.ne = relopF64(numbers.f64.ne)
instr.f64.lt = relopF64(numbers.f64.lt)
instr.f64.gt = relopF64(numbers.f64.gt)
instr.f64.le = relopF64(numbers.f64.le)
instr.f64.ge = relopF64(numbers.f64.ge)

instr.f64.abs = unopF64(numbers.f64.abs)
instr.f64.neg = unopF64(numbers.f64.neg)
instr.f64.ceil = unopF64(numbers.f64.ceil)
instr.f64.floor = unopF64(numbers.f64.floor)
instr.f64.trunc = unopF64(numbers.f64.trunc)
instr.f64.nearest = unopF64(numbers.f64.nearest)
instr.f64.sqrt = unopF64(numbers.f64.sqrt)

instr.f64.add = binopF64(numbers.f64.add)
instr.f64.sub = binopF64(numbers.f64.sub)
instr.f64.mul = binopF64(numbers.f64.mul)
instr.f64.div = binopF64(numbers.f64.div)
instr.f64.min = binopF64(numbers.f64.min)
instr.f64.max = binopF64(numbers.f64.max)
instr.f64.copysign = binopF64(numbers.f64.copysign)

instr.f64.convert_i32_s = unop(numbers.f64.convert_i32_s, "popI32", "pushF64")
instr.f64.convert_i32_u = unop(numbers.f64.convert_i32_u, "popI32", "pushF64")
instr.f64.convert_i64_s = unop(numbers.f64.convert_i64_s, "popI64", "pushF64")
instr.f64.convert_i64_u = unop(numbers.f64.convert_i64_u, "popI64", "pushF64")
instr.f64.promote_f32 = unop(numbers.f64.promote_f32, "popF32", "pushF64")
instr.f64.reinterpret_i64 = unop(numbers.f64.reinterpret_i64, "popI64", "pushF64")

local fcSubOps = {
  _subop = true,
  [0] = instr.i32.trunc_sat_f32_s,
  [1] = instr.i32.trunc_sat_f32_u,
  [2] = instr.i32.trunc_sat_f64_s,
  [3] = instr.i32.trunc_sat_f64_u,
  [4] = instr.i64.trunc_sat_f32_s,
  [5] = instr.i64.trunc_sat_f32_u,
  [6] = instr.i64.trunc_sat_f64_s,
  [7] = instr.i64.trunc_sat_f64_u,
  [8] = instr.memory.init,
  [10] = instr.memory.copy,
  [11] = instr.memory.fill
}

instr._lookup = {
  [0x00] = instr.unreachable,
  [0x01] = instr.nop,
  [0x02] = instr.block,
  [0x03] = instr.loop,
  [0x04] = instr["if"],
  [0x05] = instr._["else"],
  [0x08] = instr.throw,
  [0x0A] = instr.throw_ref,
  [0x0B] = instr._.block_end,
  [0x0C] = instr.br,
  [0x0D] = instr.br_if,
  [0x0F] = instr["return"],
  [0x10] = instr.call,
  [0x11] = instr.call_indirect,
  [0x14] = instr.call_ref,
  [0x1A] = instr.drop,
  [0x1B] = instr.select,
  [0x1C] = instr.select_t,
  [0x1F] = instr.try_table,
  [0x20] = instr["local"].get,
  [0x21] = instr["local"].set,
  [0x22] = instr["local"].tee,
  [0x23] = instr.global.get,
  [0x24] = instr.global.set,
  [0x25] = instr.table.get,
  [0x28] = instr.i32.load,
  [0x29] = instr.i64.load,
  [0x2A] = instr.f32.load,
  [0x2B] = instr.f64.load,
  [0x2C] = instr.i32.load8_s,
  [0x2D] = instr.i32.load8_u,
  [0x2E] = instr.i32.load16_s,
  [0x2F] = instr.i32.load16_u,
  [0x30] = instr.i64.load8_s,
  [0x31] = instr.i64.load8_u,
  [0x32] = instr.i64.load16_s,
  [0x33] = instr.i64.load16_u,
  [0x34] = instr.i64.load32_s,
  [0x35] = instr.i64.load32_u,
  [0x36] = instr.i32.store,
  [0x37] = instr.i64.store,
  [0x38] = instr.f32.store,
  [0x39] = instr.f64.store,
  [0x3A] = instr.i32.store8,
  [0x3B] = instr.i32.store16,
  [0x3C] = instr.i64.store8,
  [0x3D] = instr.i64.store16,
  [0x3E] = instr.i64.store32,
  [0x3F] = instr.memory.size,
  [0x40] = instr.memory.grow,
  [0x41] = instr.i32.const,
  [0x42] = instr.i64.const,
  [0x43] = instr.f32.const,
  [0x44] = instr.f64.const,
  [0x45] = instr.i32.eqz,
  [0x46] = instr.i32.eq,
  [0x47] = instr.i32.ne,
  [0x48] = instr.i32.lt_s,
  [0x49] = instr.i32.lt_u,
  [0x4A] = instr.i32.gt_s,
  [0x4B] = instr.i32.gt_u,
  [0x4C] = instr.i32.le_s,
  [0x4D] = instr.i32.le_u,
  [0x4E] = instr.i32.ge_s,
  [0x4F] = instr.i32.ge_u,
  [0x50] = instr.i64.eqz,
  [0x51] = instr.i64.eq,
  [0x52] = instr.i64.ne,
  [0x53] = instr.i64.lt_s,
  [0x54] = instr.i64.lt_u,
  [0x55] = instr.i64.gt_s,
  [0x56] = instr.i64.gt_u,
  [0x57] = instr.i64.le_s,
  [0x58] = instr.i64.le_u,
  [0x59] = instr.i64.ge_s,
  [0x5A] = instr.i64.ge_u,
  [0x5B] = instr.f32.eq,
  [0x5C] = instr.f32.ne,
  [0x5D] = instr.f32.lt,
  [0x5E] = instr.f32.gt,
  [0x5F] = instr.f32.le,
  [0x60] = instr.f32.ge,
  [0x61] = instr.f64.eq,
  [0x62] = instr.f64.ne,
  [0x63] = instr.f64.lt,
  [0x64] = instr.f64.gt,
  [0x65] = instr.f64.le,
  [0x66] = instr.f64.ge,
  [0x67] = instr.i32.clz,
  [0x68] = instr.i32.ctz,
  [0x69] = instr.i32.popcnt,
  [0x6A] = instr.i32.add,
  [0x6B] = instr.i32.sub,
  [0x6C] = instr.i32.mul,
  [0x6D] = instr.i32.div_s,
  [0x6E] = instr.i32.div_u,
  [0x6F] = instr.i32.rem_s,
  [0x70] = instr.i32.rem_u,
  [0x71] = instr.i32["and"],
  [0x72] = instr.i32["or"],
  [0x73] = instr.i32.xor,
  [0x74] = instr.i32.shl,
  [0x75] = instr.i32.shr_s,
  [0x76] = instr.i32.shr_u,
  [0x77] = instr.i32.rotl,
  [0x78] = instr.i32.rotr,
  [0x79] = instr.i64.clz,
  [0x7A] = instr.i64.ctz,
  [0x7B] = instr.i64.popcnt,
  [0x7C] = instr.i64.add,
  [0x7D] = instr.i64.sub,
  [0x7E] = instr.i64.mul,
  [0x7F] = instr.i64.div_s,
  [0x80] = instr.i64.div_u,
  [0x81] = instr.i64.rem_s,
  [0x82] = instr.i64.rem_u,
  [0x83] = instr.i64["and"],
  [0x84] = instr.i64["or"],
  [0x85] = instr.i64.xor,
  [0x86] = instr.i64.shl,
  [0x87] = instr.i64.shr_s,
  [0x88] = instr.i64.shr_u,
  [0x89] = instr.i64.rotl,
  [0x8A] = instr.i64.rotr,
  [0xFC] = fcSubOps,
  [0x8B] = instr.f32.abs,
  [0x8C] = instr.f32.neg,
  [0x8D] = instr.f32.ceil,
  [0x8E] = instr.f32.floor,
  [0x8F] = instr.f32.trunc,
  [0x90] = instr.f32.nearest,
  [0x91] = instr.f32.sqrt,
  [0x92] = instr.f32.add,
  [0x93] = instr.f32.sub,
  [0x94] = instr.f32.mul,
  [0x95] = instr.f32.div,
  [0x96] = instr.f32.min,
  [0x97] = instr.f32.max,
  [0x98] = instr.f32.copysign,
  [0x99] = instr.f64.abs,
  [0x9A] = instr.f64.neg,
  [0x9B] = instr.f64.ceil,
  [0x9C] = instr.f64.floor,
  [0x9D] = instr.f64.trunc,
  [0x9E] = instr.f64.nearest,
  [0x9F] = instr.f64.sqrt,
  [0xA0] = instr.f64.add,
  [0xA1] = instr.f64.sub,
  [0xA2] = instr.f64.mul,
  [0xA3] = instr.f64.div,
  [0xA4] = instr.f64.min,
  [0xA5] = instr.f64.max,
  [0xA6] = instr.f64.copysign,
  [0xA7] = instr.i32.wrap_i64,
  [0xA8] = instr.i32.trunc_f32_s,
  [0xA9] = instr.i32.trunc_f32_u,
  [0xAA] = instr.i32.trunc_f64_s,
  [0xAB] = instr.i32.trunc_f64_u,
  [0xAC] = instr.i64.extend_i32_s,
  [0xAD] = instr.i64.extend_i32_u,
  [0xAE] = instr.i64.trunc_f32_s,
  [0xAF] = instr.i64.trunc_f32_u,
  [0xB0] = instr.i64.trunc_f64_s,
  [0xB1] = instr.i64.trunc_f64_u,
  [0xB2] = instr.f32.convert_i32_s,
  [0xB3] = instr.f32.convert_i32_u,
  [0xB4] = instr.f32.convert_i64_s,
  [0xB5] = instr.f32.convert_i64_u,
  [0xB6] = instr.f32.demote_f64,
  [0xB7] = instr.f64.convert_i32_s,
  [0xB8] = instr.f64.convert_i32_u,
  [0xB9] = instr.f64.convert_i64_s,
  [0xBA] = instr.f64.convert_i64_u,
  [0xBB] = instr.f64.promote_f32,
  [0xBC] = instr.i32.reinterpret_f32,
  [0xBD] = instr.i64.reinterpret_f64,
  [0xBE] = instr.f32.reinterpret_i32,
  [0xBF] = instr.f64.reinterpret_i64,
  [0xC0] = instr.i32.extend8_s,
  [0xC1] = instr.i32.extend16_s,
  [0xC2] = instr.i64.extend8_s,
  [0xC3] = instr.i64.extend16_s,
  [0xC4] = instr.i64.extend32_s,
}

instr.SYMBOL_BR = SYMBOL_BR
instr.SYMBOL_RETURN = SYMBOL_RETURN
instr.SYMBOL_THROW = SYMBOL_THROW

return instr