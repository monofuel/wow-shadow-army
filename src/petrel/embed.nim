## In-process Lua host for Petrel strategy (lua/entry/traverse.lua).
## No process spawn. Long-lived VM; decide() returns strategy JSON.

import std/[json, os, strutils, locks]
import ./lua53
import ../traverse_cv/project

type
  PetrelEmbed* = object
    L: PState
    repo: string
    ready: bool
    lastError: string

var
  gEmbed: PetrelEmbed
  gLock: Lock
  gLockInited: bool
  gLastProjection: JsonNode
  gLastIntent: JsonNode

proc initLockOnce() =
  if not gLockInited:
    initLock(gLock)
    gLockInited = true

proc luaQuote(s: string): string =
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

proc pushJson(L: PState; n: JsonNode) =
  if n.isNil:
    L.pushnil()
    return
  case n.kind
  of JNull:
    L.pushnil()
  of JBool:
    L.pushboolean(if n.getBool: 1 else: 0)
  of JInt:
    L.pushinteger(n.getInt.Integer)
  of JFloat:
    L.pushnumber(n.getFloat.Number)
  of JString:
    discard L.pushstring(n.getStr.cstring)
  of JArray:
    L.createtable(n.len.cint, 0)
    var i = 1
    for x in n:
      L.pushJson(x)
      L.rawseti(-2, i.Integer)
      inc i
  of JObject:
    L.createtable(0, n.len.cint)
    for k, v in n.pairs:
      discard L.pushstring(k.cstring)
      L.pushJson(v)
      L.settable(-3)

proc popJson(L: PState; idx: cint): JsonNode =
  case L.`type`(idx)
  of TNIL:
    result = newJNull()
  of TBOOLEAN:
    result = %*(L.toboolean(idx) != 0)
  of TNUMBER:
    var isnum: cint
    let f = L.tonumberx(idx, addr isnum)
    if isnum != 0:
      if f == float64(int(f)):
        result = %*(int(f))
      else:
        result = %*f
    else:
      result = newJNull()
  of TSTRING:
    let s = L.tostring(idx)
    result = %*(if s.isNil: "" else: $s)
  of TTABLE:
    var maxI = 0
    var isArr = true
    let absIdx =
      if idx < 0: L.gettop() + idx + 1
      else: idx
    L.pushnil()
    while L.next(absIdx) != 0:
      if L.`type`(-2) == TNUMBER:
        var isnum: cint
        let k = L.tointegerx(-2, addr isnum)
        if isnum == 0 or k < 1:
          isArr = false
        elif k.int > maxI:
          maxI = k.int
      else:
        isArr = false
      L.pop(1)
    if isArr and maxI > 0:
      result = newJArray()
      for i in 1..maxI:
        L.pushinteger(i.Integer)
        discard L.gettable(absIdx)
        result.add L.popJson(-1)
        L.pop(1)
    else:
      result = newJObject()
      L.pushnil()
      while L.next(absIdx) != 0:
        let key =
          if L.`type`(-2) == TSTRING: $L.tostring(-2)
          elif L.`type`(-2) == TNUMBER:
            var isnum: cint
            $L.tointegerx(-2, addr isnum)
          else:
            "k"
        let val = L.popJson(-1)
        L.pop(1)
        result[key] = val
  else:
    result = newJNull()

proc closeEmbed*(e: var PetrelEmbed) =
  if e.L != nil:
    e.L.close()
    e.L = nil
  e.ready = false

proc openEmbed*(e: var PetrelEmbed; repoRoot: string): bool =
  e.closeEmbed()
  e.repo = repoRoot
  e.L = newstate()
  if e.L.isNil:
    e.lastError = "luaL_newstate failed"
    return false
  e.L.openlibs()
  let packagePath =
    repoRoot / "lua" / "?.lua" & ";" &
    repoRoot / "lua" / "entry" / "?.lua" & ";" &
    repoRoot / "lua" / "tools" / "?.lua" & ";;"
  let boot =
    "package.path = " & luaQuote(packagePath) & "\n" &
    "local ok, entry = pcall(require, \"traverse\")\n" &
    "if not ok then error(tostring(entry)) end\n" &
    "if type(entry) ~= \"table\" or type(entry.decide) ~= \"function\" then\n" &
    "  error(\"traverse.decide missing\")\n" &
    "end\n" &
    "_G.__petrel_decide = entry.decide\n"
  let st = e.L.dostring(boot, "petrel_boot")
  if st != OK:
    e.lastError = "boot: " & (if e.L.tostring(-1).isNil: $st else: $e.L.tostring(-1))
    e.L.pop(1)
    e.closeEmbed()
    return false
  e.ready = true
  e.lastError = ""
  true

proc ensureOpen(e: var PetrelEmbed; repoRoot: string): bool =
  if e.ready and e.repo == repoRoot and e.L != nil:
    return true
  e.openEmbed(repoRoot)

proc decide*(e: var PetrelEmbed; proj: JsonNode; repoRoot: string): JsonNode =
  ## Run traverse.decide(frame) in-process. Returns strategy intent JSON.
  if not e.ensureOpen(repoRoot):
    return %*{"kind": "hold", "reason": "embed_boot_failed", "error": e.lastError}
  let L = e.L
  discard L.getglobal("__petrel_decide")
  if L.`type`(-1) != 6:  # LUA_TFUNCTION
    L.pop(1)
    e.lastError = "decide missing"
    return %*{"kind": "hold", "reason": "embed_no_decide"}
  L.pushJson(proj)
  L.createtable(0, 0)
  let st = L.pcall(2, 1, 0)
  if st != OK:
    let err = if L.tostring(-1).isNil: $st else: $L.tostring(-1)
    L.pop(1)
    e.lastError = err
    return %*{"kind": "hold", "reason": "embed_lua_error", "error": err}
  result = L.popJson(-1)
  L.pop(1)
  if result.isNil or result.kind != JObject:
    result = %*{"kind": "hold", "reason": "embed_bad_intent"}
  elif not result.hasKey("kind"):
    result["kind"] = %"hold"
    if not result.hasKey("reason"):
      result["reason"] = %"embed_missing_kind"

proc globalDecide*(proj: JsonNode; repoRoot: string): JsonNode =
  initLockOnce()
  withLock gLock:
    result = gEmbed.decide(proj, repoRoot)

proc globalDecideFromViewJson*(viewBody: string; repoRoot: string): JsonNode =
  ## ClientView JSON → project → strategy intent (in-process).
  let view = parseJson(viewBody)
  let proj = projectClientView(view)
  initLockOnce()
  withLock gLock:
    result = gEmbed.decide(proj, repoRoot)
    gLastProjection = proj
    gLastIntent = result

proc globalReload*(repoRoot: string): tuple[ok: bool, detail: string] =
  ## Transactional hot reload: keep the active VM if the replacement fails.
  initLockOnce()
  withLock gLock:
    var candidate: PetrelEmbed
    if not candidate.openEmbed(repoRoot):
      return (false, candidate.lastError)
    gEmbed.closeEmbed()
    gEmbed = candidate
    gLastProjection = nil
    gLastIntent = nil
    result = (true, "reloaded")

proc lastDecisionTrace*(): JsonNode =
  initLockOnce()
  withLock gLock:
    result = %*{
      "projection":
        (if gLastProjection.isNil: newJObject() else: gLastProjection),
      "intent": (if gLastIntent.isNil: newJObject() else: gLastIntent)
    }

proc lastEmbedError*(): string =
  initLockOnce()
  withLock gLock:
    result = gEmbed.lastError
