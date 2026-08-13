# Conductor — automated autoresearch loop over the league lanes.
# Imports scriptorium (../scriptorium, wow-coworld submodule) for agent
# harnesses and git plumbing; the loop, eval gate, and ledger are ours.
# Design + runbook: docs/conductor.md. Config: ../conductor.json.

import scriptorium/config as scriptorium_config

when isMainModule:
  echo "conductor: skeleton — CLI lands with the conductor build"
  echo "scriptorium harness types available: ", $Harness.high
