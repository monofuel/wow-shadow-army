"""Run real Lua tools via subprocess (lua5.3 / lua), zero new Python deps.

Choice: subprocess + a tiny pure-Lua JSON shim rather than lupa. Rationale:
- No extra package to install (lupa needs a C extension + matching Lua).
- PATH lua5.3 matches `make test` (Makefile RUN_LUA).
- Frame/args are small plain tables; we emit them as Lua literals from Python
  and print the intent as JSON from a ~40-line pure-Lua encoder covering the
  shapes follow_leader returns (string/number/bool keys).

Stdin is not used; the decide call is baked into a short temp script so we
never need a full JSON parser on the Lua side.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping, Optional

_REPO_ROOT = Path(__file__).resolve().parents[1]
_LUA_TOOLS = _REPO_ROOT / "lua" / "tools"
_LUA_PATH = f"{_LUA_TOOLS}/?.lua;;"


def find_lua() -> str:
    """Resolve lua5.3 or lua on PATH (same preference as Makefile).

    Falls back to `nix shell nixpkgs#lua5_3 --command which lua` once, then
    caches the store path so subsequent decides are fast.
    """
    for name in ("lua5.3", "lua"):
        path = shutil.which(name)
        if path:
            return path
    cached = getattr(find_lua, "_nix_cache", None)
    if cached:
        return cached
    if shutil.which("nix"):
        try:
            proc = subprocess.run(
                ["nix", "shell", "nixpkgs#lua5_3", "--command", "which", "lua"],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if proc.returncode == 0:
                path = (proc.stdout or "").strip().splitlines()[-1].strip()
                if path and Path(path).is_file():
                    find_lua._nix_cache = path  # type: ignore[attr-defined]
                    return path
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise FileNotFoundError(
        "lua5.3/lua not on PATH; install lua5.3 or use nix shell nixpkgs#lua5_3"
    )


def _lua_string(s: str) -> str:
    return (
        '"'
        + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        + '"'
    )


def _to_lua(value: Any) -> str:
    """Encode a JSON-like Python value as a Lua table/literal."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        # Keep a decimal so Lua sees a number, not an integer edge case.
        return repr(value) if value == value and value not in (float("inf"), float("-inf")) else "0"
    if isinstance(value, str):
        return _lua_string(value)
    if isinstance(value, Mapping):
        parts = []
        for k, v in value.items():
            if isinstance(k, str) and k.isidentifier():
                key = k
            else:
                key = f"[{_to_lua(k)}]"
            parts.append(f"{key}={_to_lua(v)}")
        return "{" + ",".join(parts) + "}"
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(_to_lua(v) for v in value) + "}"
    raise TypeError(f"cannot encode {type(value)!r} as Lua")


# Pure-Lua JSON encoder for the small intent tables tools return.
_JSON_ENCODE_LUA = r'''
local function json_encode(v)
  local t = type(v)
  if v == nil then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then return string.format("%.10g", v) end
  if t == "string" then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
  end
  if t == "table" then
    -- Array if consecutive integer keys from 1..n
    local n = #v
    local is_array = n > 0
    if is_array then
      for i = 1, n do
        if v[i] == nil then is_array = false; break end
      end
    end
    if is_array then
      local parts = {}
      for i = 1, n do parts[i] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      if type(k) == "string" then
        parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(val)
      end
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot json_encode " .. t)
end
'''


def decide(
    tool_name: str,
    frame: Mapping[str, Any],
    args: Optional[Mapping[str, Any]] = None,
    *,
    timeout_seconds: float = 5.0,
) -> Optional[dict[str, Any]]:
    """Load registry + tool, call decide(frame, args), return intent dict or None."""
    lua_bin = find_lua()
    frame_lua = _to_lua(dict(frame))
    args_lua = _to_lua(dict(args) if args else {})
    script = f'''
package.path = {_lua_string(_LUA_PATH)} .. package.path
{_JSON_ENCODE_LUA}
local registry = require("registry")
require({_lua_string(tool_name)})
local tool = registry.get({_lua_string(tool_name)})
if not tool then
  io.stderr:write("unknown tool: {tool_name}\\n")
  os.exit(2)
end
local frame = {frame_lua}
local args = {args_lua}
local intent = tool.decide(frame, args)
if intent == nil then
  io.write("null\\n")
else
  io.write(json_encode(intent) .. "\\n")
end
'''
    env = os.environ.copy()
    env["LUA_PATH"] = _LUA_PATH + env.get("LUA_PATH", "")

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".lua", delete=False, encoding="utf-8"
    ) as tmp:
        tmp.write(script)
        tmp_path = tmp.name
    try:
        proc = subprocess.run(
            [lua_bin, tmp_path],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            env=env,
            cwd=str(_REPO_ROOT),
        )
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"lua decide failed (rc={proc.returncode}): {err}")

    line = (proc.stdout or "").strip().splitlines()
    if not line:
        raise RuntimeError("lua decide produced no stdout")
    raw = line[-1].strip()
    if raw == "null":
        return None
    return json.loads(raw)
