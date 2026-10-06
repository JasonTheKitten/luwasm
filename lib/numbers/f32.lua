---@diagnostic disable: deprecated
local conversions = localRequire("lib/numbers/conversions")

local struct = localRequire("third_party/struct_modded")

local function isNegative(x)
  return x < 0 or (x == 0 and 1 / x < 0)
end

local hasNativePack = pcall(function()
  return string.pack("<I4", 0)
end)

local function toF32(x)
  if hasNativePack then
    return (string.unpack("<f", string.pack("<f", x)))
  end

  if x ~= x or x == 0 or math.abs(x) == math.huge then
    return x
  end

  local m, e = struct.frexp(x)

  if e > 128 then
    return (x > 0) and math.huge or -math.huge
  end

  if e < -149 then
    return (x > 0) and 0.0 or -0.0
  end

  local shift
  if e < -125 then
    shift = 24 + (e + 125)
    e = -125
  else
    shift = 24
  end

  local scaled = m * (2 ^ shift)
  local floor = math.floor(scaled)
  local diff = scaled - floor
  local rounded

  if diff > 0.5 then
    rounded = floor + 1
  elseif diff < 0.5 then
    rounded = floor
  else
    if floor % 2 == 0 then
      rounded = floor
    else
      rounded = floor + 1
    end
  end

  local result = struct.ldexp(rounded / (2 ^ shift), e)
  if result == 0 and isNegative(x) then
    return -0.0
  end
  return result
end

local function trunc(x)
  return (x < 0) and math.ceil(x) or math.floor(x)
end

local function nearest(x)
  if x ~= x or math.abs(x) == math.huge then
    return x
  end
  if x == 0 then return x end

  local floor = math.floor(x)
  local diff = x - floor

  local res
  if diff < 0.5 then
    res = floor
  elseif diff > 0.5 then
    res = floor + 1
  else
    if floor % 2 == 0 then
      res = floor
    else
      res = floor + 1
    end
  end

  if res == 0 and isNegative(x) then
    return -0.0
  end
  return res
end

local numbersF32 = {}

numbersF32.toF32 = toF32

numbersF32.eq = function(a, b)
  return a == b
end

numbersF32.ne = function(a, b)
  return a ~= b
end

numbersF32.lt = function(a, b)
  return a < b
end

numbersF32.gt = function(a, b)
  return a > b
end

numbersF32.le = function(a, b)
  return a <= b
end

numbersF32.ge = function(a, b)
  return a >= b
end

numbersF32.abs = function(a)
  return math.abs(a)
end

numbersF32.neg = function(a)
  return -a
end

numbersF32.ceil = function(a)
  return toF32(math.ceil(a))
end

numbersF32.floor = function(a)
  return toF32(math.floor(a))
end

numbersF32.trunc = function(a)
  return toF32(trunc(a))
end

numbersF32.nearest = function(a)
  return toF32(nearest(a))
end

numbersF32.sqrt = function(a)
  return toF32(math.sqrt(a))
end

numbersF32.add = function(a, b)
  return toF32(a + b)
end

numbersF32.sub = function(a, b)
  return toF32(a - b)
end

numbersF32.mul = function(a, b)
  return toF32(a * b)
end

numbersF32.div = function(a, b)
  return toF32(a / b)
end

numbersF32.min = function(a, b)
  if a ~= a then return a end
  if b ~= b then return b end
  if a == 0 and b == 0 then
    if isNegative(a) or isNegative(b) then
      return -0.0
    end
    return 0.0
  end
  return toF32(a < b and a or b)
end

numbersF32.max = function(a, b)
  if a ~= a then return a end
  if b ~= b then return b end
  if a == 0 and b == 0 then
    if isNegative(a) and isNegative(b) then
      return -0.0
    end
    return 0.0
  end
  return toF32(a > b and a or b)
end

numbersF32.copysign = function(a, b)
  if isNegative(a) == isNegative(b) then
    return a
  else
    return -a
  end
end

numbersF32.convert_i32_s = function(val)
  local s = (val >= 0x80000000) and (val - 0x100000000) or val
  return toF32(s)
end

numbersF32.convert_i32_u = function(val)
  return toF32(val)
end

numbersF32.convert_i64_s = function(low, high)
  local s = (high >= 0x80000000) 
    and ((high - 0x100000000) * 0x100000000 + low) 
    or (high * 0x100000000 + low)
  return toF32(s)
end

numbersF32.convert_i64_u = function(low, high)
  local u = high * 0x100000000 + low
  return toF32(u)
end

numbersF32.demote_f64 = function(f)
  return toF32(f)
end

numbersF32.reinterpret_i32 = function(val)
  return conversions.u32ToF32(val)
end

return numbersF32