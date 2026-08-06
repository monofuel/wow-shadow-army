## ClientView JSON → Lua traverse decide → ClientInputBatch JSON.
## Used in-process from the player bridge hook (stdin/stdout or --view/--out files).
##
##   traverse_lua_bridge --repo ROOT --view view.json --out batch.json --sequence N
##   echo '<client_view json>' | traverse_lua_bridge --repo ROOT --sequence N

import std/[json, math, os, parseopt, strutils]
import ../src/traverse_cv/[project, lower, decide]

type Cfg = object
  repo: string
  viewPath: string
  outPath: string
  sequence: int
  dumpIntent: bool

proc usage() =
  stderr.writeLine """
traverse_lua_bridge — ClientView → traverse.lua → ClientInputBatch

  --repo DIR       wow-shadow-army root (default: cwd)
  --view FILE      ClientView JSON (default: stdin)
  --out FILE       ClientInputBatch JSON (default: stdout)
  --sequence N     batch sequence (default 1)
  --dump-intent    also print intent JSON to stderr
"""

proc parseCfg(): Cfg =
  result.repo = getCurrentDir()
  result.sequence = 1
  var pending = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if pending.len > 0:
        stderr.writeLine "missing value for --", pending
        quit(2)
      case key
      of "repo", "view", "out", "sequence":
        if val.len > 0:
          case key
          of "repo": result.repo = val
          of "view": result.viewPath = val
          of "out": result.outPath = val
          of "sequence": result.sequence = parseInt(val)
          else: discard
        else:
          pending = key
      of "dump-intent": result.dumpIntent = true
      of "h", "help":
        usage()
        quit(0)
      else:
        stderr.writeLine "unknown option: ", key
        usage()
        quit(2)
    of cmdArgument:
      if pending.len > 0:
        case pending
        of "repo": result.repo = key
        of "view": result.viewPath = key
        of "out": result.outPath = key
        of "sequence": result.sequence = parseInt(key)
        else: discard
        pending = ""
    of cmdEnd: discard
  if pending.len > 0:
    stderr.writeLine "missing value for --", pending
    quit(2)

proc main() =
  let cfg = parseCfg()
  let viewBody =
    if cfg.viewPath.len > 0: readFile(cfg.viewPath)
    else: stdin.readAll()
  let view = parseJson(viewBody)
  if jstr(jget(view, "type")) != "client_view" and jget(view, "player").isNil:
    # Allow bare player-only fixtures without type field.
    discard
  # Periodic full-view dump for debugging action-bar / form binds.
  try:
    if cfg.sequence mod 50 == 1:
      createDir(cfg.repo / "local_data")
      writeFile(cfg.repo / "local_data" / "traverse-cv-last-view.json", viewBody)
  except CatchableError:
    discard
  let proj = projectClientView(view)
  let intent = runTraverseDecide(proj, cfg.repo)
  if cfg.dumpIntent:
    stderr.writeLine $intent
  let batch = lowerIntent(view, intent, cfg.sequence)
  let outBody = $batch
  # Status for long-run watching (merchant coast is the leg-2 prove target).
  try:
    let me = jget(proj, "self_unit")
    # Primary prove goal: merchant coast (override with TRAVERSE_GOAL_*).
    let gx = parseFloat(getEnv("TRAVERSE_GOAL_X", "-1533.7"))
    let gy = parseFloat(getEnv("TRAVERSE_GOAL_Y", "-4056.5"))
    let gr = parseFloat(getEnv("TRAVERSE_GOAL_RADIUS", "100"))
    let wx = parseFloat(getEnv("TRAVERSE_WATER_X", "-6784.5"))
    let wy = parseFloat(getEnv("TRAVERSE_WATER_Y", "-4833.9"))
    let px = jnum(jget(me, "x"))
    let py = jnum(jget(me, "y"))
    let dist = sqrt((px - gx) * (px - gx) + (py - gy) * (py - gy))
    let waterDist = sqrt((px - wx) * (px - wx) + (py - wy) * (py - wy))
    let statusDir = cfg.repo / "local_data"
    createDir(statusDir)
    writeFile(
      statusDir / "traverse-cv-status.json",
      $(%*{
        "x": px, "y": py, "z": jnum(jget(me, "z")),
        "goal_x": gx, "goal_y": gy,
        "dist": dist, "radius": gr,
        "water_dist": waterDist,
        "at_goal": dist <= gr,
        "swimming": jbool(jget(me, "is_swimming")),
        "form_spell": jint(jget(me, "shapeshift_form_spell_id")),
        "ghost": jbool(jget(jget(proj, "death"), "is_ghost")),
        "intent": intent,
        "sequence": cfg.sequence,
        "view_id": jint(jget(view, "view_id"))
      })
    )
  except CatchableError:
    discard
  if cfg.outPath.len > 0:
    writeFile(cfg.outPath, outBody)
  else:
    stdout.writeLine outBody

when isMainModule:
  main()
