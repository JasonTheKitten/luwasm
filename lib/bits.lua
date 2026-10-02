local computer = pcall(require, "computer")

local function evalOp(code)
  if computer then
    return assert(load("return function(a, b) return math.floor(a) " .. code .. " math.floor(b) end"))()
  else
    return assert(load("return function(a, b) return a " .. code .. " b end"))()
  end
end

local shl, shr, band, bor, bnot
if bit32 then
  shl = bit32.lshift
  shr = bit32.rshift
  band = bit32.band
  bor = bit32.bor
  bnot = bit32.bnot
elseif bit then
  shl = bit.lshift
  shr = bit.rshift
  band = bit.band
  bor = bit.bor
  bnot = bit.bnot
else
  shl = evalOp("<<")
  shr = evalOp(">>")
  band = evalOp("&")
  bor = evalOp("|")
  bnot = assert(load("return function(a) return ~a end"))()
end

return {
  shl = shl,
  shr = shr,
  band = band,
  bor = bor,
  bnot = bnot
}