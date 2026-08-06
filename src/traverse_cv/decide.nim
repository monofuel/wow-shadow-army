## Run lua/entry/traverse.lua decide() via in-process Petrel embed.

import std/json
import ../petrel/embed

proc runTraverseDecide*(
  proj: JsonNode;
  repoRoot: string
): JsonNode =
  ## repoRoot is wow-shadow-army root (contains lua/). In-process — no lua subprocess.
  globalDecide(proj, repoRoot)
