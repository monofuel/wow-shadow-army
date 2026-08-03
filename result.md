# Terminology rename finish — result

Finish pass after the partial sed rename (Shadow→Character, listShadows→listCharacters, ShadowArmyCast→BotSeats, etc.). No commit/push.

## Files touched

| File | What changed |
|---|---|
| `system/system_server.nim` | Comments/doc comments/UI strings: cast→bot seats / main characters; faces→interfaces / MCP JSON view / HTML rendering; HTML labels `Cast:`→`Seats:`; JSON key `"cast"`→`"seats"`; MCP tool descriptions; leftover `listShadowsHandler`→`listCharactersHandler`. Kept: `{.cast(gcsafe).}`, character names, ShadowArmy*, shadowsoap, respawn shadow army routes/tools/buttons. |
| `system/tests/test_admin.nim` | Suite/test name strings + comments; JSON assert `cast`→`seats`. |
| `system/tests/test_enums.nim` | Test name “roster display order…”; local var `castOnly`→`mainOnly`. |
| `system/tests/test_server_ops.nim` | Suite “server status views”; test names (json view, bot seats only, non-bot-seat names). |
| `system/README.md` | `list_shadows`→`list_characters`; section “One dispatch path, many interfaces”; faces→interfaces; cast→bot seats / main characters; keep foundation seats + respawn shadow army wording. |
| `docs/terms.md` | Deleted **face**, **cast**, **shadow** entries; rewrote **seat** and **foundation seats** without cast/face refs. |
| `AGENTS.md` | Vocabulary line: `(upstream, the fork, seats, foundation seats, fair play, …)`. |
| `result.md` | This file. |

## Verify

```
nim check --hints:off --warnings:off system/system_server.nim  # exit 0
make test  # exit 0
```

### Tail of `make test` output

```
== system/tests/test_soap.nim ==

[Suite] escapeXml
  [OK] escapes ampersand less-than greater-than
  [OK] command body embeds escaped text

[Suite] extractSoapResult
  [OK] success envelope yields result text
  [OK] fault envelope has no result
  [OK] empty / garbage
== tools/tests/test_fair_play_audit.nim ==
OK: 27 checks passed
== tools/tests/test_party_promote.nim ==
test_party_promote: 10 checks passed
make[1]: Leaving directory '/mnt/steel-chest/Monolab/Home/monofuel/Softmax/wow-shadow-army'
test-smoke-lua: all lua parses clean
make[1]: Entering directory '/mnt/steel-chest/Monolab/Home/monofuel/Softmax/wow-shadow-army'
== nim check system/system_server.nim ==
== nim check tools/army_host.nim ==
== nim check tools/fair_play_audit.nim ==
== nim check tools/party_promote.nim ==
== nim check tools/msgpack_json.nim ==
make[1]: Leaving directory '/mnt/steel-chest/Monolab/Home/monofuel/Softmax/wow-shadow-army'
```

Working tree left dirty for review (no git commit / push).
