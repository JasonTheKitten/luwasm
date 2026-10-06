---@diagnostic disable: deprecated
local struct = localRequire("third_party/struct_modded")

local has_native_pack = pcall(function()
  return string.pack("<I4", 0)
end)

local function u32ToF32(u32)
  if has_native_pack then
    return (string.unpack("<f", string.pack("<I4", u32)))
  else
    local bytes = struct.packint(u32, 4, true)
    return struct.unpackfloat(bytes, 1, true)
  end
end

local function f32ToU32(f32)
  if has_native_pack then
    return (string.unpack("<I4", string.pack("<f", f32)))
  else
    local bytes = struct.packfloat(f32, true)
    return struct.unpackint(bytes, 1, 4, true, false)
  end
end

local function u64ToF64(low, high)
  if not high then error("A") end
  if has_native_pack then
    return (string.unpack("<d", string.pack("<I4I4", low, high)))
  else
    local bytes = struct.packint(low, 4, true) .. struct.packint(high, 4, true)
    return struct.unpackdouble(bytes, 1, true)
  end
end

local function f64ToU64(f64)
  if has_native_pack then
    local low, high = string.unpack("<I4I4", string.pack("<d", f64))
    return low, high
  else
    local bytes = struct.packdouble(f64, true)
    local low = struct.unpackint(bytes, 1, 4, true, false)
    local high = struct.unpackint(bytes, 5, 4, true, false)
    return low, high
  end
end

return {
  u32ToF32 = u32ToF32,
  f32ToU32 = f32ToU32,
  u64ToF64 = u64ToF64,
  f64ToU64 = f64ToU64,
}