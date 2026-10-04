local I32_MASK = 0xFFFFFFFF

local numbers = {}

numbers.i32 = {}
numbers.i32.add = function(a, b)
  return (a + b) % I32_MASK
end

return numbers