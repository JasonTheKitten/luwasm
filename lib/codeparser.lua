local streamutils = localRequire("lib/streamutils")

local readU1 = streamutils.readU1

local function readExpr(stream)
  local val, err = readU1(stream)
  if not val then return false, err end
  -- TODO: Other stuff (esp. since need to balance nested 0x0B)
  while val ~= 0x0B do
    val, err = readU1(stream)
    if not val then return false, err end
  end

  return {} -- TODO
end

return {
  readExpr = readExpr
}