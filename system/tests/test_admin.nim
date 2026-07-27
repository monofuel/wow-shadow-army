## Unit tests for admin cast helpers (respawn command planning).
## Run: nim r --hints:off --warnings:off system/tests/test_admin.nim
## No network, no docker, no realm — pure functions only.

import
  std/[json, strutils, unittest],
  ../system_server

suite "shadow army cast":
  test "fixed cast seats":
    check ShadowArmyCast.len == 4
    check isShadowArmyCastName("Shadowfel")
    check isShadowArmyCastName("Igris")
    check isShadowArmyCastName("Tusk")
    check isShadowArmyCastName("Beru")
    check not isShadowArmyCastName("Murist")
    check not isShadowArmyCastName("shadowfel") # case-sensitive exact match
    check not isShadowArmyCastName("")
    check not isShadowArmyCastName("Shadowfel; revive all")

  test "respawn commands are ordered revive → tele → repair":
    let cmds = respawnCommandsFor("Shadowfel")
    check cmds.len == 3
    check cmds[0] == "revive Shadowfel"
    check cmds[1] == "tele name Shadowfel Deathknell"
    check cmds[2] == "repairitems Shadowfel"
    check ShadowArmyRespawnTele == "Deathknell"

  test "respawn commands reject non-cast names":
    expect ValueError:
      discard respawnCommandsFor("Murist")
    expect ValueError:
      discard respawnCommandsFor("evil; quit")

  test "respawn commands reject junk tele dest":
    expect ValueError:
      discard respawnCommandsFor("Igris", teleDest = "Death knell")
    expect ValueError:
      discard respawnCommandsFor("Igris", teleDest = "foo;quit")
    expect ValueError:
      discard respawnCommandsFor("Igris", teleDest = "")

  test "admin JSON shape":
    let r = AdminActionResult(
      ok: true,
      action: "respawn_shadow_army",
      summary: "ok",
      steps: @[
        AdminStepResult(
          name: "Shadowfel",
          command: "revive Shadowfel",
          ok: true,
          detail: "revived"
        )
      ]
    )
    let j = adminActionToJson(r)
    check j{"ok"}.getBool == true
    check j{"action"}.getStr == "respawn_shadow_army"
    check j{"tele"}.getStr == "Deathknell"
    check j{"steps"}.len == 1
    check j{"cast"}.len == 4

  test "render admin result marks failures":
    let r = AdminActionResult(
      ok: false,
      action: "respawn_shadow_army",
      summary: "partial",
      steps: @[
        AdminStepResult(name: "A", command: "revive A", ok: true, detail: "ok"),
        AdminStepResult(name: "B", command: "revive B", ok: false, detail: "nope"),
      ]
    )
    let html = renderAdminResult(r)
    check "admin-err" in html
    check "FAIL" in html
    check "revive B" in html
    check "partial" in html
