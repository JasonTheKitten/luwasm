-- Modified to strip out unneeded logic and keep just conversions

--[[
 * Copyright (c) 2015-2026 Iryont <https://github.com/iryont/lua-struct>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
]]

local floor, huge, log = math.floor, math.huge, math.log
local byte, char, sub = string.byte, string.char, string.sub
local reverse = string.reverse

local struct = {}

struct._VERSION = '1.0.0'

-- math.ldexp and math.frexp are deprecated since Lua 5.3 and missing from
-- builds without LUA_COMPAT_MATHLIB, so provide replacements for those
---@diagnostic disable-next-line: deprecated
local ldexp = math.ldexp or function(m, e)
  -- scale in two steps, 2 ^ e on its own could overflow or underflow
  local half = floor(e / 2)
  return m * 2 ^ half * 2 ^ (e - half)
end

---@diagnostic disable-next-line: deprecated
local frexp = math.frexp or function(x)
  -- x is always finite and greater than zero in here
  local e = floor(log(x) / log(2)) + 1
  local m = ldexp(x, -e)

  -- math.log may be off by one around powers of two
  while m >= 1 do
    m = m / 2
    e = e + 1
  end
  while m < 0.5 do
    m = m * 2
    e = e - 1
  end

  return m, e
end

-- The value is split into 32 bit halves before it gets cut into bytes. That
-- keeps every step exact both for doubles and for the 64 bit integers of
-- Lua 5.3+ (where '/' would otherwise round anything above 2 ^ 53).
local function packint(val, size, little)
  if size == 1 then
    return char(val % 256)
  end

  local low = val % 4294967296
  local high = (val - low) / 4294967296
  local b1 = low % 256
  low = (low - b1) / 256
  local b2 = low % 256
  low = (low - b2) / 256
  local b3 = low % 256
  local b4 = (low - b3) / 256

  local str
  if size <= 4 then
    str = char(b1, b2, b3, b4)
  else
    high = high % 4294967296
    local b5 = high % 256
    high = (high - b5) / 256
    local b6 = high % 256
    high = (high - b6) / 256
    local b7 = high % 256
    local b8 = (high - b7) / 256
    str = char(b1, b2, b3, b4, b5, b6, b7, b8)
  end

  if size ~= 4 and size ~= 8 then
    str = sub(str, 1, size)
  end

  return little and str or reverse(str)
end

local function unpackint(stream, pos, size, little, issigned)
  if size == 1 then
    local val = byte(stream, pos)
    if issigned and val >= 128 then
      val = val - 256
    end
    return val
  elseif size == 2 then
    local b1, b2 = byte(stream, pos, pos + 1)
    local val = little and b2 * 256 + b1 or b1 * 256 + b2
    if issigned and val >= 32768 then
      val = val - 65536
    end
    return val
  elseif size == 4 then
    local b1, b2, b3, b4 = byte(stream, pos, pos + 3)
    if little then
      b1, b2, b3, b4 = b4, b3, b2, b1
    end
    local val = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    if issigned and val >= 2147483648 then
      val = val - 4294967296
    end
    return val
  end

  -- walk from the most significant byte down
  local first, last, step = pos, pos + size - 1, 1
  if little then
    first, last, step = last, first, -1
  end

  -- Negative numbers are read as their complement, so they stay small and
  -- exact in a double instead of being rounded somewhere around 2 ^ 64.
  local negative = issigned and byte(stream, first) >= 128
  local high, low = 0, 0
  local count = size - 4
  for i = first, last, step do
    local b = byte(stream, i)
    if negative then
      b = 255 - b
    end
    if count > 0 then
      high = high * 256 + b
    else
      low = low * 256 + b
    end
    count = count - 1
  end

  -- high and low are added just once, this way a value which does not fit
  -- into a double is rounded a single time
  if negative then
    return -(high * 4294967296 + (low + 1))
  end

  local val = high * 4294967296 + low
  if val < 0 then
    -- Lua 5.3+: an unsigned value above the integer range wrapped around
    val = high * 4294967296.0 + low
  end
  return val
end

-- splits a number into the sign, exponent and mantissa of an IEEE 754 value
-- with the given amount of exponent (ebits) and mantissa (mbits) bits
local function splitfloat(val, ebits, mbits)
  local sign, exponent, mantissa = 0, 0, 0
  local emax = 2 ^ ebits - 1
  local bias = (emax - 1) / 2

  -- turns an integer of Lua 5.3+ into a float, unlike '+ 0.0' keeps the sign of -0.0
  val = val * 1.0
  if val < 0 or (val == 0 and 1 / val < 0) then
    sign = 1
    val = -val
  end

  if val ~= val then
    exponent, mantissa = emax, 2 ^ (mbits - 1)
  elseif val == huge then
    exponent = emax
  elseif val ~= 0 then
    local m, e = frexp(val)
    exponent = e + bias - 1
    if exponent > 0 then
      mantissa = (m * 2 - 1) * 2 ^ mbits
    else
      -- subnormal
      mantissa = ldexp(val, bias - 1 + mbits)
      exponent = 0
    end

    -- round to nearest, ties to even, exactly like a cast in C does
    local rounded = floor(mantissa)
    local rest = mantissa - rounded
    if rest > 0.5 or (rest == 0.5 and rounded % 2 == 1) then
      rounded = rounded + 1
    end
    mantissa = rounded

    if mantissa == 2 ^ mbits then
      -- rounding carried over into the exponent
      mantissa = 0
      exponent = exponent + 1
    end
    if exponent >= emax then
      -- too large, becomes infinity
      exponent, mantissa = emax, 0
    end
  end

  return sign, exponent, mantissa
end

local function joinfloat(sign, exponent, mantissa, ebits, mbits)
  local emax = 2 ^ ebits - 1
  local bias = (emax - 1) / 2

  if exponent == emax then
    if mantissa ~= 0 then
      return 0 / 0
    end
    return sign * huge
  elseif exponent == 0 then
    -- zero or subnormal
    return sign * ldexp(mantissa, 1 - bias - mbits)
  end

  return sign * ldexp(mantissa + 2 ^ mbits, exponent - bias - mbits)
end

local function packfloat(val, little)
  local sign, exponent, mantissa = splitfloat(val, 8, 23)

  local b1 = mantissa % 256
  mantissa = (mantissa - b1) / 256
  local b2 = mantissa % 256
  local b3 = (mantissa - b2) / 256 + exponent % 2 * 128
  local b4 = sign * 128 + (exponent - exponent % 2) / 2

  if little then
    return char(b1, b2, b3, b4)
  end
  return char(b4, b3, b2, b1)
end

local function packdouble(val, little)
  local sign, exponent, mantissa = splitfloat(val, 11, 52)

  local low = mantissa % 4294967296
  local high = (mantissa - low) / 4294967296
  local b1 = low % 256
  low = (low - b1) / 256
  local b2 = low % 256
  low = (low - b2) / 256
  local b3 = low % 256
  local b4 = (low - b3) / 256
  local b5 = high % 256
  high = (high - b5) / 256
  local b6 = high % 256
  local b7 = (high - b6) / 256 + exponent % 16 * 16
  local b8 = sign * 128 + (exponent - exponent % 16) / 16

  if little then
    return char(b1, b2, b3, b4, b5, b6, b7, b8)
  end
  return char(b8, b7, b6, b5, b4, b3, b2, b1)
end

local function unpackfloat(stream, pos, little)
  local b1, b2, b3, b4 = byte(stream, pos, pos + 3)
  if not little then
    b1, b2, b3, b4 = b4, b3, b2, b1
  end

  local sign = b4 >= 128 and -1 or 1
  local exponent = b4 % 128 * 2 + floor(b3 / 128)
  local mantissa = (b3 % 128 * 256 + b2) * 256 + b1

  return joinfloat(sign, exponent, mantissa, 8, 23)
end

local function unpackdouble(stream, pos, little)
  local b1, b2, b3, b4, b5, b6, b7, b8 = byte(stream, pos, pos + 7)
  if not little then
    b1, b2, b3, b4, b5, b6, b7, b8 = b8, b7, b6, b5, b4, b3, b2, b1
  end

  local sign = b8 >= 128 and -1 or 1
  local exponent = b8 % 128 * 16 + floor(b7 / 16)
  local mantissa = (b7 % 16 * 256 + b6) * 256 + b5
  mantissa = (((mantissa * 256 + b4) * 256 + b3) * 256 + b2) * 256 + b1

  return joinfloat(sign, exponent, mantissa, 11, 52)
end

struct.packint = packint
struct.unpackint = unpackint
struct.packfloat = packfloat
struct.unpackfloat = unpackfloat
struct.packdouble = packdouble
struct.unpackdouble = unpackdouble
struct.splitfloat = splitfloat
struct.joinfloat = joinfloat
struct.ldexp = ldexp
struct.frexp = frexp

return struct