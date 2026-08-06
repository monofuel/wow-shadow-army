## Minimal Lua 5.3 C API binding (decompbound/noulith technique).
## Links liblua at compile time via PETREL_LUA_PREFIX or system paths.

import std/os

const
  LuaPrefix {.strdefine.}: string = ""

when LuaPrefix.len > 0:
  {.passC: "-I" & LuaPrefix & "/include".}
  {.passL: "-L" & LuaPrefix & "/lib -llua -lm -ldl".}
else:
  {.passL: "-llua -lm -ldl".}

type
  PState* = pointer
  CFunction* = proc (state: PState): cint {.cdecl.}

const
  OK* = 0
  ERRRUN* = 2
  ERRSYNTAX* = 3
  ERRMEM* = 4
  MULTRET* = -1
  TNIL* = 0
  TBOOLEAN* = 1
  TNUMBER* = 3
  TSTRING* = 4
  TTABLE* = 5
  RegistryIndex* = -1001000  ## LUA_REGISTRYINDEX (5.3 default)

type
  Number* = float64
  Integer* = int64

{.pragma: ilua, importc: "lua_$1", cdecl.}
{.pragma: iluaL, importc: "luaL_$1", cdecl.}

proc newstate*(): PState {.iluaL.}
proc close*(L: PState) {.ilua.}
proc openlibs*(L: PState) {.importc: "luaL_openlibs", cdecl.}
proc loadbufferx*(
  L: PState; buff: cstring; size: csize_t; name: cstring; mode: cstring
): cint {.iluaL.}
proc pcallk*(
  L: PState; nargs, nresults, errfunc: cint; ctx: pointer; k: CFunction
): cint {.ilua.}
proc pcall*(L: PState; nargs, nresults, errfunc: cint): cint {.inline.} =
  L.pcallk(nargs, nresults, errfunc, nil, nil)

proc getglobal*(L: PState; name: cstring): cint {.ilua.}
proc setglobal*(L: PState; name: cstring) {.ilua.}
proc pushcclosure*(L: PState; fn: CFunction; n: cint) {.ilua.}
proc pushnil*(L: PState) {.ilua.}
proc pushboolean*(L: PState; b: cint) {.ilua.}
proc pushinteger*(L: PState; n: Integer) {.ilua.}
proc pushnumber*(L: PState; n: Number) {.ilua.}
proc pushstring*(L: PState; s: cstring): cstring {.ilua.}
proc pushlstring*(L: PState; s: cstring; len: csize_t): cstring {.ilua.}
proc createtable*(L: PState; narr, nrec: cint) {.ilua.}
proc settable*(L: PState; idx: cint) {.ilua.}
proc gettable*(L: PState; idx: cint): cint {.ilua.}
proc rawseti*(L: PState; idx: cint; n: Integer) {.ilua.}
proc gettop*(L: PState): cint {.ilua.}
proc settop*(L: PState; idx: cint) {.ilua.}
proc pop*(L: PState; n: cint) {.inline.} =
  L.settop(-n - 1)
proc `type`*(L: PState; idx: cint): cint {.ilua.}
proc toboolean*(L: PState; idx: cint): cint {.ilua.}
proc tointegerx*(L: PState; idx: cint; isnum: ptr cint): Integer {.ilua.}
proc tonumberx*(L: PState; idx: cint; isnum: ptr cint): Number {.ilua.}
proc tolstring*(L: PState; idx: cint; len: ptr csize_t): cstring {.ilua.}
proc tostring*(L: PState; idx: cint): cstring {.inline.} =
  L.tolstring(idx, nil)
proc next*(L: PState; idx: cint): cint {.ilua.}
proc isnil*(L: PState; idx: cint): bool {.inline.} =
  L.`type`(idx) == TNIL

proc loadstring*(L: PState; s: string; name = "chunk"): cint =
  L.loadbufferx(s.cstring, s.len.csize_t, name.cstring, nil)

proc dostring*(L: PState; s: string; name = "chunk"): cint =
  result = L.loadstring(s, name)
  if result == OK:
    result = L.pcall(0, MULTRET, 0)
