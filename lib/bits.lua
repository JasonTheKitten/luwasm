local function evalOp(code)
  return assert(load("return function(a, b) return a " .. code .. " b end"))()
end

local shl, shr, sar32, band, bor, bxor, bnot32, rotl32, rotr32

if bit32 then
  shl = bit32.lshift
  shr = bit32.rshift
  sar32 = bit32.arshift
  band = bit32.band
  bor = bit32.bor
  bxor = bit32.bxor
  ---@diagnostic disable: undefined-field
  bnot32 = bit32.bnot32
  ---@diagnostic disable: undefined-field
  rotl32 = bit32.lrotate32
  ---@diagnostic disable: undefined-field
  rotr32 = bit32.rrotate32
elseif bit then
  shl = bit.lshift
  shr = bit.rshift
  sar32 = bit.arshift
  band = bit.band
  bor = bit.bor
  bxor = bit.bxor
  bnot32 = bit.bnot
  rotl32 = bit.rol
  rotr32 = bit.ror
else
  shl = evalOp("<<")
  shr = evalOp(">>")
  band = evalOp("&")
  bor = evalOp("|")
  bxor = evalOp("~")
  bnot32 = assert(load("return function(a) return ~a end"))()

  sar32 = assert(load([[
    return function(a, b)
      if (a & 0xFFFFFFFF) >= 0x80000000 then
        return ((a | ~0xFFFFFFFF) >> b) & 0xFFFFFFFF
      else
        return (a >> b) & 0xFFFFFFFF
      end
    end
  ]]))()
  rotl32 = assert(load([[
    return function(a, b)
      b = b % 32
      if b == 0 then return a & 0xFFFFFFFF end
      return ((a << b) | ((a & 0xFFFFFFFF) >> (32 - b))) & 0xFFFFFFFF
    end
  ]]))()
  rotr32 = assert(load([[
    return function(a, b)
      b = b % 32
      if b == 0 then return a & 0xFFFFFFFF end
      return (((a & 0xFFFFFFFF) >> b) | (a << (32 - b))) & 0xFFFFFFFF
    end
  ]]))()
end

return {
  shl = shl,
  shr = shr,
  sar32 = sar32,
  band = band,
  bor = bor,
  bxor = bxor,
  bnot32 = bnot32,
  rotl32 = rotl32,
  rotr32 = rotr32
}