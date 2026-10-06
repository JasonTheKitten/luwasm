local conversions = localRequire("lib/numbers/conversions")

local function isNegative(x)
  return x < 0 or (x == 0 and 1 / x < 0)
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

local numbersF64 = {}

numbersF64.eq = function(a, b)
  return a == b
end

numbersF64.ne = function(a, b)
  return a ~= b
end

numbersF64.lt = function(a, b)
  return a < b
end

numbersF64.gt = function(a, b)
  return a > b
end

numbersF64.le = function(a, b)
  return a <= b
end

numbersF64.ge = function(a, b)
  return a >= b
end

numbersF64.abs = function(a)
  return math.abs(a)
end

numbersF64.neg = function(a)
  return -a
end

numbersF64.ceil = function(a)
  return math.ceil(a)
end

numbersF64.floor = function(a)
  return math.floor(a)
end

numbersF64.trunc = function(a)
  return trunc(a)
end

numbersF64.nearest = function(a)
  return nearest(a)
end

numbersF64.sqrt = function(a)
  return math.sqrt(a)
end

numbersF64.add = function(a, b)
  return a + b
end

numbersF64.sub = function(a, b)
  return a - b
end

numbersF64.mul = function(a, b)
  return a * b
end

numbersF64.div = function(a, b)
  return a / b
end

numbersF64.min = function(a, b)
  if a ~= a then return a end
  if b ~= b then return b end
  if a == 0 and b == 0 then
    if isNegative(a) or isNegative(b) then
      return -0.0
    end
    return 0.0
  end
  return a < b and a or b
end

numbersF64.max = function(a, b)
  if a ~= a then return a end
  if b ~= b then return b end
  if a == 0 and b == 0 then
    if isNegative(a) and isNegative(b) then
      return -0.0
    end
    return 0.0
  end
  return a > b and a or b
end

numbersF64.copysign = function(a, b)
  if isNegative(a) == isNegative(b) then
    return a
  else
    return -a
  end
end

numbersF64.convert_i32_s = function(val)
  return (val >= 0x80000000) and (val - 0x100000000) or val
end

numbersF64.convert_i32_u = function(val)
  return val
end

numbersF64.convert_i64_s = function(low, high)
  return (high >= 0x80000000) 
    and ((high - 0x100000000) * 0x100000000 + low) 
    or (high * 0x100000000 + low)
end

numbersF64.convert_i64_u = function(low, high)
  return high * 0x100000000 + low
end

numbersF64.promote_f32 = function(f)
  return f
end

numbersF64.reinterpret_i64 = function(low, high)
  return conversions.u64ToF64(low, high)
end

return numbersF64