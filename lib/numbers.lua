local U32_MASK = 0x100000000

local function toSigned32(a)
  if a >= 0x80000000 then
    a = a - 0x100000000
  end
  return a
end

local numbers = {}

numbers.i32 = {}
numbers.i32.eqz = function(a)
  return a == 0
end
numbers.i32.eq = function(a, b)
  return a == b
end
numbers.i32.ne = function(a, b)
  return a ~= b
end
numbers.i32.lt_s = function(a, b)
  return toSigned32(a) < toSigned32(b)
end
numbers.i32.gt_s = function(a, b)
  return toSigned32(a) > toSigned32(b)
end
numbers.i32.add = function(a, b)
  return (a + b) % U32_MASK
end
numbers.i32.sub = function(a, b)
  return (a - b) % U32_MASK
end

return numbers