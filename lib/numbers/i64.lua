local bits = localRequire("lib/bits")
local conversions = localRequire("lib/numbers/conversions")
local numbersI32 = localRequire("lib/numbers/i32")
local struct = localRequire("third_party/struct_modded")

local b_band = bits.band
local b_bor = bits.bor
local b_bxor = bits.bxor
local b_shl = bits.shl
local b_shr = bits.shr
local b_sar32 = bits.sar32

local i32_lt_s = numbersI32.lt_s
local i32_lt_u = numbersI32.lt_u
local i32_gt_s = numbersI32.gt_s
local i32_gt_u = numbersI32.gt_u
local i32_le_u = numbersI32.le_u
local i32_ge_u = numbersI32.ge_u
local i32_clz = numbersI32.clz
local i32_ctz = numbersI32.ctz
local i32_popcnt = numbersI32.popcnt

local ERR_DIV_ZERO = "integer divide by zero"
local ERR_OVERFLOW = "integer overflow"
local ERR_INVALID_CONV = "invalid conversion to integer"

local U32_BASE = 0x100000000
local U32_MASK = 0xFFFFFFFF
local U32_SIGN = 0x80000000

local U16_BASE = 0x10000
local U16_SIGN = 0x80
local U16_EXT = 0xFFFF0000

local U8_SIGN = 0x80
local U8_EXT = 0xFFFFFF00

local INT64_MAX_F_PLUS_1 = struct.ldexp(1, 63)
local INT64_MIN_F = -struct.ldexp(1, 63)
local UINT64_MAX_F_PLUS_1 = struct.ldexp(1, 64)

local numbersI64 = {}

local i64_sub, i64_neg, i64_shl, i64_shr_u, i64_rotr, i64_ge_u, i64_lt_u
local i64_trunc_f64_s, i64_trunc_f64_u

i64_sub = function(la, ha, lb, hb)
  local l = la - lb
  local borrow = 0
  if l < 0 then
    l = l + U32_BASE
    borrow = 1
  end
  local h = (ha - hb - borrow) % U32_BASE
  return l, h
end

i64_neg = function(l, h)
  return i64_sub(0, 0, l, h)
end

i64_shl = function(la, ha, s)
  s = s % 64
  if s == 0 then
    return la, ha
  elseif s < 32 then
    local low = b_shl(la, s)
    local high = b_bor(b_shl(ha, s), b_shr(la, 32 - s))
    return low, high
  else
    return 0, b_shl(la, s - 32)
  end
end

i64_shr_u = function(la, ha, s)
  s = s % 64
  if s == 0 then
    return la, ha
  elseif s < 32 then
    local low = b_bor(b_shr(la, s), b_shl(ha, 32 - s))
    local high = b_shr(ha, s)
    return low, high
  else
    return b_shr(ha, s - 32), 0
  end
end

i64_lt_u = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_lt_u(ha, hb)
  end
  return i32_lt_u(la, lb)
end

i64_ge_u = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_gt_u(ha, hb)
  end
  return i32_ge_u(la, lb)
end

i64_rotr = function(la, ha, s)
  s = s % 64
  if s == 0 then
    return la, ha
  elseif s < 32 then
    local low = b_bor(b_shr(la, s), b_band(b_shl(ha, 32 - s), U32_MASK))
    local high = b_bor(b_shr(ha, s), b_band(b_shl(la, 32 - s), U32_MASK))
    return low, high
  elseif s == 32 then
    return ha, la
  else
    local k = s - 32
    local low = b_bor(b_shr(ha, k), b_band(b_shl(la, 32 - k), U32_MASK))
    local high = b_bor(b_shr(la, k), b_band(b_shl(ha, 32 - k), U32_MASK))
    return low, high
  end
end

numbersI64.new = function(low, high)
  return low % U32_BASE, (high or 0) % U32_BASE
end

numbersI64.from_i32_s = function(v)
  v = v % U32_BASE
  if v >= U32_SIGN then
    return v, U32_MASK
  end
  return v, 0
end

numbersI64.from_i32_u = function(v)
  return v % U32_BASE, 0
end

numbersI64.to_i32 = function(l, h)
  return l
end

numbersI64.eqz = function(l, h)
  return l == 0 and h == 0
end

numbersI64.eq = function(la, ha, lb, hb)
  return la == lb and ha == hb
end

numbersI64.ne = function(la, ha, lb, hb)
  return la ~= lb or ha ~= hb
end

numbersI64.lt_u = i64_lt_u

numbersI64.gt_u = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_gt_u(ha, hb)
  end
  return i32_gt_u(la, lb)
end

numbersI64.le_u = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_lt_u(ha, hb)
  end
  return i32_le_u(la, lb)
end

numbersI64.ge_u = i64_ge_u

numbersI64.lt_s = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_lt_s(ha, hb)
  end
  return i32_lt_u(la, lb)
end

numbersI64.gt_s = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_gt_s(ha, hb)
  end
  return i32_gt_u(la, lb)
end

numbersI64.le_s = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_lt_s(ha, hb)
  end
  return i32_le_u(la, lb)
end

numbersI64.ge_s = function(la, ha, lb, hb)
  if ha ~= hb then
    return i32_gt_s(ha, hb)
  end
  return i32_ge_u(la, lb)
end

numbersI64.clz = function(l, h)
  if h ~= 0 then
    return i32_clz(h), 0
  end
  return i32_clz(l) + 32, 0
end

numbersI64.ctz = function(l, h)
  if l ~= 0 then
    return i32_ctz(l), 0
  end
  return i32_ctz(h) + 32, 0
end

numbersI64.popcnt = function(l, h)
  return i32_popcnt(l) + i32_popcnt(h), 0
end

numbersI64.add = function(la, ha, lb, hb)
  local l = la + lb
  local carry = math.floor(l / U32_BASE)
  local h = (ha + hb + carry) % U32_BASE
  return l % U32_BASE, h
end

numbersI64.sub = i64_sub
numbersI64.neg = i64_neg

numbersI64.mul = function(la, ha, lb, hb)
  local a0 = la % U16_BASE
  local a1 = math.floor(la / U16_BASE)
  local a2 = ha % U16_BASE
  local a3 = math.floor(ha / U16_BASE)

  local b0 = lb % U16_BASE
  local b1 = math.floor(lb / U16_BASE)
  local b2 = hb % U16_BASE
  local b3 = math.floor(hb / U16_BASE)

  local c0 = a0 * b0
  local c1 = a0 * b1 + a1 * b0
  local c2 = a0 * b2 + a1 * b1 + a2 * b0
  local c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0

  c1 = c1 + math.floor(c0 / U16_BASE)
  c0 = c0 % U16_BASE

  c2 = c2 + math.floor(c1 / U16_BASE)
  c1 = c1 % U16_BASE

  c3 = c3 + math.floor(c2 / U16_BASE)
  c2 = c2 % U16_BASE

  c3 = c3 % U16_BASE

  local low = c0 + c1 * U16_BASE
  local high = c2 + c3 * U16_BASE
  return low, high
end

numbersI64["and"] = function(la, ha, lb, hb)
  return b_band(la, lb), b_band(ha, hb)
end

numbersI64["or"] = function(la, ha, lb, hb)
  return b_bor(la, lb), b_bor(ha, hb)
end

numbersI64.xor = function(la, ha, lb, hb)
  return b_bxor(la, lb), b_bxor(ha, hb)
end

numbersI64.shl = i64_shl
numbersI64.shr_u = i64_shr_u

numbersI64.shr_s = function(la, ha, s)
  s = s % 64
  if s == 0 then
    return la, ha
  elseif s < 32 then
    local low = b_bor(b_shr(la, s), b_shl(ha, 32 - s))
    local high = b_sar32(ha, s)
    return low, high
  elseif s == 32 then
    local fill = (ha >= U32_SIGN) and U32_MASK or 0
    return ha, fill
  else
    local low = b_sar32(ha, s - 32)
    local fill = (ha >= U32_SIGN) and U32_MASK or 0
    return low, fill
  end
end

numbersI64.rotl = function(la, ha, s)
  return i64_rotr(la, ha, (64 - (s % 64)) % 64)
end
numbersI64.rotr = i64_rotr

local function divrem_u(la, ha, lb, hb)
  if lb == 0 and hb == 0 then
    return nil, ERR_DIV_ZERO
  end

  if ha == 0 and hb == 0 then
    return la % lb, 0, math.floor(la / lb), 0
  end

  if i64_lt_u(la, ha, lb, hb) then
    return la, ha, 0, 0
  end

  local rem_l, rem_h = 0, 0
  local q_l, q_h = 0, 0

  for i = 63, 0, -1 do
    rem_l, rem_h = i64_shl(rem_l, rem_h, 1)
    local bit
    if i >= 32 then
      bit = b_band(b_shr(ha, i - 32), 1)
    else
      bit = b_band(b_shr(la, i), 1)
    end
    rem_l = b_bor(rem_l, bit)

    if i64_ge_u(rem_l, rem_h, lb, hb) then
      rem_l, rem_h = i64_sub(rem_l, rem_h, lb, hb)
      if i >= 32 then
        q_h = b_bor(q_h, b_shl(1, i - 32))
      else
        q_l = b_bor(q_l, b_shl(1, i))
      end
    end
  end

  return rem_l, rem_h, q_l, q_h
end

numbersI64.div_u = function(la, ha, lb, hb)
  local rem_l, rem_h, q_l, q_h = divrem_u(la, ha, lb, hb)
  if rem_l == nil then
    return nil, rem_h
  end
  return q_l, q_h
end

numbersI64.rem_u = function(la, ha, lb, hb)
  local rem_l, rem_h = divrem_u(la, ha, lb, hb)
  if rem_l == nil then
    return nil, rem_h
  end
  return rem_l, rem_h
end

numbersI64.div_s = function(la, ha, lb, hb)
  if lb == 0 and hb == 0 then
    return nil, ERR_DIV_ZERO
  end

  if la == 0 and ha == U32_SIGN and lb == U32_MASK and hb == U32_MASK then
    return nil, ERR_OVERFLOW
  end

  local sign_a = ha >= U32_SIGN
  local sign_b = hb >= U32_SIGN

  local ua_l, ua_h = la, ha
  if sign_a then
    ua_l, ua_h = i64_neg(la, ha)
  end

  local ub_l, ub_h = lb, hb
  if sign_b then
    ub_l, ub_h = i64_neg(lb, hb)
  end

  local _, _, q_l, q_h = divrem_u(ua_l, ua_h, ub_l, ub_h)

  if sign_a ~= sign_b then
    q_l, q_h = i64_neg(q_l, q_h)
  end

  return q_l, q_h
end

numbersI64.rem_s = function(la, ha, lb, hb)
  if lb == 0 and hb == 0 then
    return nil, ERR_DIV_ZERO
  end

  if la == 0 and ha == U32_SIGN and lb == U32_MASK and hb == U32_MASK then
    return 0, 0
  end

  local sign_a = ha >= U32_SIGN
  local sign_b = hb >= U32_SIGN

  local ua_l, ua_h = la, ha
  if sign_a then
    ua_l, ua_h = i64_neg(la, ha)
  end

  local ub_l, ub_h = lb, hb
  if sign_b then
    ub_l, ub_h = i64_neg(lb, hb)
  end

  local r_l, r_h = divrem_u(ua_l, ua_h, ub_l, ub_h)

  if sign_a then
    r_l, r_h = i64_neg(r_l, r_h)
  end

  return r_l, r_h
end

numbersI64.extend8_s = function(l, h)
  local byte = l % 256
  if byte >= U8_SIGN then
    return byte + U8_EXT, U32_MASK
  end
  return byte, 0
end

numbersI64.extend16_s = function(l, h)
  local short = l % U16_BASE
  if short >= U16_SIGN then
    return short + U16_EXT, U32_MASK
  end
  return short, 0
end

numbersI64.extend_i32_s = function(l, h)
  if l >= U32_SIGN then
    return l, U32_MASK
  end
  return l, 0
end

numbersI64.extend_i32_u = function(l, h)
  return l, 0
end

numbersI64.convert_i64_s = function(l, h)
  if h >= U32_SIGN then
    local abs_l, abs_h = i64_neg(l, h)
    return -(abs_l + abs_h * U32_BASE)
  end
  return l + h * U32_BASE
end

numbersI64.convert_i64_u = function(l, h)
  return l + h * U32_BASE
end

numbersI64.reinterpret_f64 = function(v)
  return conversions.f64ToU64(v)
end

i64_trunc_f64_s = function(val)
  if val ~= val then
    return nil, ERR_INVALID_CONV
  end

  local trunc_val = val < 0 and math.ceil(val) or math.floor(val)
  if trunc_val < INT64_MIN_F or trunc_val >= INT64_MAX_F_PLUS_1 then
    return nil, ERR_OVERFLOW
  end

  local sign = trunc_val < 0
  local abs_val = math.abs(trunc_val)

  local high = math.floor(abs_val / U32_BASE)
  local low = math.floor(abs_val % U32_BASE)

  if sign then
    low, high = i64_neg(low, high)
  end

  return low, high
end

i64_trunc_f64_u = function(val)
  if val ~= val then
    return nil, ERR_INVALID_CONV
  end

  local trunc_val = val < 0 and math.ceil(val) or math.floor(val)
  if trunc_val < 0 or trunc_val >= UINT64_MAX_F_PLUS_1 then
    return nil, ERR_OVERFLOW
  end

  local high = math.floor(trunc_val / U32_BASE)
  local low = math.floor(trunc_val % U32_BASE)

  return low, high
end

numbersI64.trunc_f64_s = i64_trunc_f64_s
numbersI64.trunc_f64_u = i64_trunc_f64_u
numbersI64.trunc_f32_s = i64_trunc_f64_s
numbersI64.trunc_f32_u = i64_trunc_f64_u

numbersI64.trunc_sat_f64_s = function(val)
  if val ~= val then
    return 0, 0
  end
  local trunc_val = val < 0 and math.ceil(val) or math.floor(val)
  if trunc_val < INT64_MIN_F then
    return 0, U32_SIGN
  elseif trunc_val >= INT64_MAX_F_PLUS_1 then
    return U32_MASK, 0x7FFFFFFF
  end
  return i64_trunc_f64_s(val)
end

numbersI64.trunc_sat_f64_u = function(val)
  if val ~= val or val < 0 then
    return 0, 0
  end
  local trunc_val = math.floor(val)
  if trunc_val >= UINT64_MAX_F_PLUS_1 then
    return U32_MASK, U32_MASK
  end
  return i64_trunc_f64_u(val)
end

numbersI64.trunc_sat_f32_s = numbersI64.trunc_sat_f64_s
numbersI64.trunc_sat_f32_u = numbersI64.trunc_sat_f64_u

return numbersI64