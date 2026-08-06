## C ABI for in-process Petrel decide (loaded by fork player via dynlib).
## No process spawn — shared library linked into the player address space.

import std/[json, os]
import ./embed
import ../traverse_cv/lower

when appType == "lib":
  proc petrel_init(repoPath: cstring): cint {.exportc, dynlib, cdecl.} =
    ## Warm the Lua VM. 0 = ok, non-zero = fail.
    let repo = $repoPath
    if repo.len == 0 or not dirExists(repo / "lua"):
      return 1
    let intent = globalDecide(%*{"self_unit": newJObject()}, repo)
    # Boot may fail on empty frame; only care that VM loads traverse.
    if intent{"reason"}.getStr == "embed_boot_failed":
      return 2
    return 0

  var
    lastResult: string
    lastBatch: string
    castSeq: int

  proc petrel_decide(viewJson: cstring; repoPath: cstring): cstring
      {.exportc, dynlib, cdecl.} =
    ## ClientView JSON → strategy intent JSON (static buffer; copy before next call).
    let repo = $repoPath
    let body = if viewJson.isNil: "{}" else: $viewJson
    try:
      let intent = globalDecideFromViewJson(body, repo)
      lastResult = $intent
    except CatchableError as e:
      lastResult = $(%*{
        "kind": "hold",
        "reason": "embed_exception",
        "error": e.msg
      })
    result = lastResult.cstring

  proc petrel_lower_cast(viewJson: cstring; spell: cint): cstring
      {.exportc, dynlib, cdecl.} =
    ## ClientView JSON + form spell → ClientInputBatch JSON (stance/chat/bar).
    ## Uses traverse lowerer form path proven for Aquatic/Travel.
    let body = if viewJson.isNil: "{}" else: $viewJson
    try:
      let view = parseJson(body)
      let intent = %*{
        "kind": "cast_spell",
        "spell": spell.int,
        "reason": "aquatic_form"
      }
      inc castSeq
      let batch = lowerIntent(view, intent, castSeq)
      lastBatch = $batch
    except CatchableError as e:
      lastBatch = $(%*{
        "type": "client_input_batch",
        "events": newJArray(),
        "error": e.msg
      })
    result = lastBatch.cstring

  proc petrel_last_error(): cstring {.exportc, dynlib, cdecl.} =
    lastEmbedError().cstring
