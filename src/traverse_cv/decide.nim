## Run lua/entry/traverse.lua decide() on a projected frame.

import std/[json, os, osproc, strutils]

proc luaEscape(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c
  result.add "\""

proc toLua(n: JsonNode): string =
  if n.isNil: return "nil"
  case n.kind
  of JNull: "nil"
  of JBool: (if n.getBool: "true" else: "false")
  of JInt: $n.getInt
  of JFloat:
    let f = n.getFloat
    if f == f.int.float: $f.int & ".0"
    else: $f
  of JString: luaEscape(n.getStr)
  of JArray:
    var parts: seq[string]
    for x in n: parts.add toLua(x)
    "{" & parts.join(", ") & "}"
  of JObject:
    var parts: seq[string]
    for k, v in n.pairs:
      parts.add "[" & luaEscape(k) & "] = " & toLua(v)
    "{" & parts.join(", ") & "}"

proc findLua*(): string =
  result = findExe("lua5.3")
  if result.len == 0:
    result = findExe("lua")
  if result.len == 0:
    let (nixOut, nixCode) = execCmdEx(
      "nix shell nixpkgs#lua5_3 --command which lua"
    )
    if nixCode == 0:
      result = nixOut.strip().splitLines()[^1].strip()
  if result.len == 0:
    raise newException(IOError, "lua5.3/lua not found")

proc runTraverseDecide*(
  proj: JsonNode;
  repoRoot: string
): JsonNode =
  ## repoRoot is wow-shadow-army root (contains lua/).
  let packagePath =
    repoRoot & "/lua/?.lua;" & repoRoot & "/lua/entry/?.lua;" &
    repoRoot & "/lua/tools/?.lua;;"
  let script = (
    "package.path = [[" & packagePath & "]]\n" &
    "local frame = " & toLua(proj) & "\n" &
    "local entry = require(\"traverse\")\n" &
    "local intent = entry.decide(frame, {})\n" &
    """
local function enc(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return tostring(v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "table" then
    local isArr = true
    local n = 0
    for k,_ in pairs(v) do
      if type(k) ~= "number" then isArr = false break end
      if k > n then n = k end
    end
    if isArr then
      local p = {}
      for i=1,n do p[i] = enc(v[i]) end
      return "[" .. table.concat(p, ",") .. "]"
    else
      local p = {}
      for k,val in pairs(v) do
        p[#p+1] = string.format("%q", tostring(k)) .. ":" .. enc(val)
      end
      return "{" .. table.concat(p, ",") .. "}"
    end
  else return "null" end
end
if intent == nil then intent = { kind = "hold", reason = "nil_intent" } end
print(enc(intent))
"""
  )
  let tmp = getTempDir() / ("traverse_cv_decide_" & $getCurrentProcessId() & ".lua")
  writeFile(tmp, script)
  defer:
    try: removeFile(tmp)
    except CatchableError: discard
  let bin = findLua()
  let (outp, code) = execCmdEx(bin & " " & quoteShell(tmp))
  if code != 0:
    raise newException(IOError, "lua decide failed: " & outp)
  let line = outp.strip().splitLines()[^1]
  parseJson(line)
