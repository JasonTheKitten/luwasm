local bits = localRequire("lib/bits")
local conversions = localRequire("lib/numbers/conversions")

local DIV_ZERO = "integer division by zero"

local U32_MASK = 0x100000000
local U32_MAX = 0xFFFFFFFF

local INT32_MIN = -0x80000000  -- or -U32_SIGN
local INT32_MAX = 0x7FFFFFFF

local U16_BASE = 0x10000
local U16_SIGN = 0x8000       -- Fixed from 0x80 if 16-bit sign bit intended
local U16_EXT = 0xFFFF0000

local U8_SIGN = 0x80
local U8_EXT = 0xFFFFFF00

local function toSigned32(a)
  a = a % U32_MASK
  if a >= 0x80000000 then
    a = a - U32_MASK
  end
  return a
end

local function toUnsigned32(a)
  return a % U32_MASK
end

local function trunc(x)
  return (x < 0) and math.ceil(x) or math.floor(x)
end

local numbersI32 = {}

numbersI32.eqz = function(a)
  return a == 0
end

numbersI32.eq = function(a, b)
  return (a % U32_MASK) == (b % U32_MASK)
end

numbersI32.ne = function(a, b)
  return (a % U32_MASK) ~= (b % U32_MASK)
end

numbersI32.lt_s = function(a, b)
  return toSigned32(a) < toSigned32(b)
end

numbersI32.lt_u = function(a, b)
  return toUnsigned32(a) < toUnsigned32(b)
end

numbersI32.gt_s = function(a, b)
  return toSigned32(a) > toSigned32(b)
end

numbersI32.gt_u = function(a, b)
  return toUnsigned32(a) > toUnsigned32(b)
end

numbersI32.le_s = function(a, b)
  return toSigned32(a) <= toSigned32(b)
end

numbersI32.le_u = function(a, b)
  return toUnsigned32(a) <= toUnsigned32(b)
end

numbersI32.ge_s = function(a, b)
  return toSigned32(a) >= toSigned32(b)
end

numbersI32.ge_u = function(a, b)
  return toUnsigned32(a) >= toUnsigned32(b)
end

numbersI32.clz = function(a)
  a = a % U32_MASK
  if a == 0 then return 32 end
  local n = 0
  if a < 0x00010000 then
    n = n + 16
    a = bits.shl(a, 16)
  end
  if a < 0x01000000 then
    n = n + 8
    a = bits.shl(a, 8)
  end
  if a < 0x10000000 then
    n = n + 4
    a = bits.shl(a, 4)
  end
  if a < 0x40000000 then
    n = n + 2
    a = bits.shl(a, 2)
  end
  if a < 0x80000000 then
    n = n + 1
  end

  return n
end

numbersI32.ctz = function(a)
  a = a % U32_MASK
  if a == 0 then return 32 end
  local n = 0
  if (a % 0x00010000) == 0 then
    n = n + 16
    a = bits.shr(a, 16)
  end
  if (a % 0x00000100) == 0 then
    n = n + 8
    a = bits.shr(a, 8)
  end
  if (a % 0x00000010) == 0 then
    n = n + 4
    a = bits.shr(a, 4)
  end
  if (a % 0x00000004) == 0 then
    n = n + 2
    a = bits.shr(a, 2)
  end
  if (a % 0x00000002) == 0 then
    n = n + 1
  end

  return n
end

numbersI32.popcnt = function(a)
  a = a % U32_MASK
  local count = 0
  while a > 0 do
    if a % 2 == 1 then count = count + 1 end
    a = math.floor(a / 2)
  end
  return count
end

numbersI32.add = function(a, b)
  return (a + b) % U32_MASK
end

numbersI32.sub = function(a, b)
  return (a - b) % U32_MASK
end

numbersI32.mul = function(a, b)
  a = a % U32_MASK
  b = b % U32_MASK
  local a_low, a_high = a % 0x10000, math.floor(a / 0x10000)
  local b_low, b_high = b % 0x10000, math.floor(b / 0x10000)
  local low = a_low * b_low
  local mid = a_low * b_high + a_high * b_low
  return (low + (mid % 0x10000) * 0x10000) % U32_MASK
end

numbersI32.div_s = function(a, b)
  local sa = toSigned32(a)
  local sb = toSigned32(b)
  if sb == 0 then return nil, DIV_ZERO end
  if sa == -0x80000000 and sb == -1 then
    return 0x80000000
  end
  return trunc(sa / sb) % U32_MASK
end

numbersI32.div_u = function(a, b)
  local ua = a % U32_MASK
  local ub = b % U32_MASK
  if ub == 0 then return nil, DIV_ZERO end
  return math.floor(ua / ub)
end

numbersI32.rem_s = function(a, b)
  local sa = toSigned32(a)
  local sb = toSigned32(b)
  if sb == 0 then return nil, DIV_ZERO end
  if sa == -0x80000000 and sb == -1 then
    return 0
  end
  local q = trunc(sa / sb)
  local r = sa - sb * q
  return r % U32_MASK
end

numbersI32.rem_u = function(a, b)
  local ua = a % U32_MASK
  local ub = b % U32_MASK
  if ub == 0 then return nil, DIV_ZERO end
  return ua % ub
end

numbersI32["and"] = function(a, b)
  return bits.band(a, b)
end

numbersI32["or"] = function(a, b)
  return bits.bor(a, b)
end

numbersI32.xor = function(a, b)
  return bits.bxor(a, b)
end

numbersI32.shl = function(a, b)
  return bits.shl(a, b % 32)
end

numbersI32.shr_s = function(a, b)
  return bits.sar32(a, b % 32)
end

numbersI32.shr_u = function(a, b)
  return bits.shr(a, b % 32)
end

numbersI32.rotl = function(a, b)
  return bits.rotl32(a, b % 32)
end

numbersI32.rotr = function(a, b)
  return bits.rotr32(a, b % 32)
end

numbersI32.wrap_i64 = function(low, high)
  return low
end

numbersI32.trunc_f32_s = function(f)
  if f ~= f then return nil, "invalid conversion to integer" end
  local t = (f >= 0) and math.floor(f) or math.ceil(f)
  if t < -0x80000000 or t > 0x7FFFFFFF then
    return nil, "integer overflow"
  end
  return (t < 0) and (t + 0x100000000) or t
end

numbersI32.trunc_f32_u = function(f)
  if f ~= f then return nil, "invalid conversion to integer" end
  local t = (f >= 0) and math.floor(f) or math.ceil(f)
  if t < 0 or t > 0xFFFFFFFF then
    return nil, "integer overflow"
  end
  return t
end

numbersI32.trunc_f64_s = numbersI32.trunc_f32_s
numbersI32.trunc_f64_u = numbersI32.trunc_f32_u

numbersI32.reinterpret_f32 = function(f)
  return conversions.f32ToU32(f)
end

numbersI32.extend8_s = function(val)
  local byte = val % 256
  if byte >= U8_SIGN then
    return byte + U8_EXT
  end
  return byte
end

numbersI32.extend16_s = function(val)
  local short = val % U16_BASE
  if short >= U16_SIGN then
    return short + U16_EXT
  end
  return short
end

local i32_trunc_f64_s = numbersI32.trunc_f64_s
local i32_trunc_f64_u = numbersI32.trunc_f64_u

numbersI32.trunc_sat_f64_s = function(val)
  if val ~= val then
    return 0
  end
  local trunc_val = val < 0 and math.ceil(val) or math.floor(val)
  if trunc_val <= INT32_MIN then
    return INT32_MIN
  elseif trunc_val >= INT32_MAX then
    return INT32_MAX
  end
  return i32_trunc_f64_s(val)
end

numbersI32.trunc_sat_f64_u = function(val)
  if val ~= val or val <= 0 then
    return 0
  end
  local trunc_val = math.floor(val)
  if trunc_val >= U32_MAX then
    return U32_MAX
  end
  return i32_trunc_f64_u(val)
end

numbersI32.trunc_sat_f32_s = numbersI32.trunc_sat_f64_s
numbersI32.trunc_sat_f32_u = numbersI32.trunc_sat_f64_u

return numbersI32