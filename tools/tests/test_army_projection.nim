## Unit tests for army_host projectV2 / mapIntentV2 (no network).
## Run: nim r --hints:off --warnings:off tools/tests/test_army_projection.nim

import std/[json, options, strutils]
import ../army_host

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

proc jget(n: JsonNode; keys: varargs[string]): JsonNode =
  result = n
  for k in keys:
    if result.isNil or result.kind != JObject or k notin result:
      return nil
    result = result[k]

# --- Frozen shape: all six top-level keys ---
block:
  let frame = %*{
    "frame_id": 1,
    "name": "Igris",
    "class_id": 1,
    "level": 10,
    "in_combat": false,
    "health_known": true,
    "health": 80,
    "max_health": 100,
    "power_known": [true, true],
    "powers": [50, 0],
    "max_powers": [100, 0],
    "location": {"map_id": 0, "x": 1.0, "y": 2.0, "z": 3.0, "orientation": 0.0},
    "selected_target_guid": "0",
    "units": [],
    "known_spells": [133],
    "cooldown_spell_ids": [],
    "is_dead": false,
    "is_ghost": false,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "corpse_location": {"map_id": 0, "x": 0.0, "y": 0.0, "z": 0.0, "orientation": 0.0},
    "party": {
      "in_group": false,
      "invite_pending": false,
      "invite_from": "",
      "leader_name": "",
      "members": []
    },
    "action_state": nil
  }
  let (proj, guids) = projectV2(frame, "Murist")
  check(proj.kind == JObject, "proj is object")
  for k in ["self_unit", "leader_unit", "combat", "spells", "death", "party"]:
    check(k in proj, "top-level key " & k)
  check(guids.len == 0, "no guids when no units")
  check(proj["self_unit"]["x"].getFloat == 1.0, "self x")
  check(proj["self_unit"]["class_id"].getInt == 1, "class_id")
  check(proj["self_unit"]["shapeshift_form_id"].getInt == 0, "form id default 0")
  check(proj["combat"]["health_pct"].getFloat == 80.0, "health_pct 80")
  check(proj["spells"]["mana"].getInt == 50, "mana pool 0")
  check(proj["spells"]["mana_pct"].getFloat == 50.0, "mana_pct")
  check(proj["death"]["corpse"].kind == JNull, "corpse null when unknown")
  check(proj["leader_unit"].kind == JNull, "leader null when not in group")
  check(proj["party"]["invite_pending"].getBool == false, "invite false")

# --- shapeshift form fields surface on self_unit (Travel Form = 3 / 783) ---
block:
  let frame = %*{
    "name": "Northbound",
    "class_id": 11,
    "level": 60,
    "health_known": true,
    "health": 100,
    "max_health": 100,
    "powers": [0],
    "max_powers": [0],
    "location": {"map_id": 1, "x": -9187.0, "y": -2530.25, "z": 14.09},
    "shapeshift_form_id": 3,
    "shapeshift_form_spell_id": 783,
    "units": [],
    "known_spells": [783],
    "cooldown_spell_ids": [],
    "is_dead": false,
    "is_ghost": false,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "party": {
      "in_group": false, "invite_pending": false, "invite_from": "",
      "leader_name": "", "members": []
    }
  }
  let (proj, _) = projectV2(frame)
  check(proj["self_unit"]["shapeshift_form_id"].getInt == 3, "travel form id")
  check(proj["self_unit"]["shapeshift_form_spell_id"].getInt == 783, "travel form spell")
  check(proj["self_unit"]["is_swimming"].getBool == false, "is_swimming default false")

# --- is_swimming surfaces on self_unit for aquatic-form policy ---
block:
  let frame = %*{
    "name": "Northbound",
    "class_id": 11,
    "level": 60,
    "health_known": true,
    "health": 100,
    "max_health": 100,
    "powers": [0],
    "max_powers": [0],
    "location": {"map_id": 1, "x": -6784.5, "y": -4833.9, "z": 0.7},
    "shapeshift_form_id": 4,
    "shapeshift_form_spell_id": 1066,
    "is_swimming": true,
    "units": [],
    "known_spells": [783, 1066],
    "cooldown_spell_ids": [],
    "is_dead": false,
    "is_ghost": false,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "party": {
      "in_group": false, "invite_pending": false, "invite_from": "",
      "leader_name": "", "members": []
    }
  }
  let (proj, _) = projectV2(frame)
  check(proj["self_unit"]["is_swimming"].getBool == true, "is_swimming true")
  check(proj["self_unit"]["shapeshift_form_id"].getInt == 4, "aquatic form id")
  check(proj["self_unit"]["shapeshift_form_spell_id"].getInt == 1066, "aquatic spell")

# --- corpse_known false maps to absent (null), not zero coords ---
block:
  let frame = %*{
    "name": "X",
    "class_id": 1,
    "level": 1,
    "health_known": true,
    "health": 10,
    "max_health": 10,
    "powers": [0],
    "max_powers": [0],
    "location": {"map_id": 0, "x": 0.0, "y": 0.0, "z": 0.0},
    "units": [],
    "known_spells": [],
    "cooldown_spell_ids": [],
    "is_dead": true,
    "is_ghost": true,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "corpse_location": {"map_id": 0, "x": 99.0, "y": 99.0, "z": 99.0},
    "party": {
      "in_group": false, "invite_pending": false, "invite_from": "",
      "leader_name": "", "members": []
    }
  }
  let (proj, _) = projectV2(frame)
  check(proj["death"]["corpse"].kind == JNull, "known-false corpse → null")
  check(proj["death"]["is_ghost"].getBool == true, "is_ghost true")

# --- invite_pending true surfaces with invite_from ---
block:
  let frame = %*{
    "name": "Shadowfel",
    "class_id": 9,
    "level": 5,
    "health_known": true,
    "health": 100,
    "max_health": 100,
    "powers": [200],
    "max_powers": [200],
    "location": {"map_id": 0, "x": 10.0, "y": 20.0, "z": 30.0},
    "units": [],
    "known_spells": [],
    "cooldown_spell_ids": [],
    "is_dead": false,
    "is_ghost": false,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "party": {
      "in_group": false,
      "invite_pending": true,
      "invite_from": "Murist",
      "leader_name": "",
      "members": []
    }
  }
  let (proj, _) = projectV2(frame)
  check(proj["party"]["invite_pending"].getBool == true, "invite_pending true")
  check(proj["party"]["invite_from"].getStr == "Murist", "invite_from Murist")
  check(proj["party"]["in_group"].getBool == false, "in_group false while invite")

# --- hostile alive → attackable; lootable dead → lootable; focus_id ---
block:
  let frame = %*{
    "name": "Tusk",
    "class_id": 1,
    "level": 12,
    "health_known": true,
    "health": 200,
    "max_health": 200,
    "powers": [0],
    "max_powers": [0],
    "in_combat": true,
    "location": {"map_id": 0, "x": 0.0, "y": 0.0, "z": 0.0},
    "selected_target_guid": "111",
    "units": [
      {
        "guid": "111",
        "entry": 1,
        "level": 10,
        "reaction": "hostile",
        "death_known": true,
        "is_dead": false,
        "health_known": true,
        "health": 50,
        "max_health": 50,
        "lootable_known": true,
        "is_lootable": false,
        "distance": 5.0,
        "line_of_sight_known": true,
        "line_of_sight_blocked": false,
        "location": {"map_id": 0, "x": 1.0, "y": 2.0, "z": 3.0}
      },
      {
        "guid": "222",
        "entry": 2,
        "level": 8,
        "reaction": "hostile",
        "death_known": true,
        "is_dead": true,
        "health_known": true,
        "health": 0,
        "max_health": 40,
        "lootable_known": true,
        "is_lootable": true,
        "distance": 3.0,
        "line_of_sight_known": false,
        "line_of_sight_blocked": true,
        "location": {"map_id": 0, "x": 4.0, "y": 5.0, "z": 6.0}
      }
    ],
    "known_spells": [],
    "cooldown_spell_ids": [],
    "is_dead": false,
    "is_ghost": false,
    "can_reclaim_corpse": false,
    "corpse_known": false,
    "party": {
      "in_group": false, "invite_pending": false, "invite_from": "",
      "leader_name": "", "members": []
    }
  }
  let (proj, guids) = projectV2(frame)
  check(guids.len == 2, "two guids")
  check(proj["combat"]["attackable"].len == 1, "one attackable")
  check(proj["combat"]["lootable"].len == 1, "one lootable")
  check(proj["combat"]["focus_id"].getInt == 1, "focus_id selected")
  check(proj["combat"]["lootable"][0]["los_blocked"].getBool == false,
    "los unknown → not blocked")
  check(proj["combat"]["attackable"][0]["lootable"].getBool == false,
    "alive not lootable row flag")

# --- mapIntentV2: move target_z_known polarity + submission envelope ---
block:
  let guids = @["999"]
  let moveIntent = %*{
    "kind": "move_to_unit",
    "unit_id": 1,
    "map_id": 0,
    "x": 10.0,
    "y": 20.0,
    "z": 30.0,
    "destination_z_unknown": true,
    "navigation_mode": "explore"
  }
  let a = mapIntentV2(moveIntent, guids)
  check(a.isSome, "move maps")
  check(a.get["kind"].getStr == "move", "kind move")
  check(a.get["target_z_known"].getBool == false,
    "destination_z_unknown true → target_z_known false")
  check(a.get["intent"].getStr == "explore", "intent explore")
  check("has_destination" notin a.get, "no has_destination")
  check("sequence" notin a.get, "no sequence")
  check("request_id" notin a.get, "no request_id")

  let knownZ = %*{
    "kind": "move_to_corpse",
    "map_id": 0, "x": 1.0, "y": 2.0, "z": 3.0
  }
  let b = mapIntentV2(knownZ, guids)
  check(b.isSome and b.get["target_z_known"].getBool == true,
    "absent destination_z_unknown → target_z_known true")

  let pointMove = %*{
    "kind": "move",
    "map_id": 1,
    "x": -9100.0,
    "y": -2530.0,
    "z": 14.0,
    "intent": "travel",
    "reason": "north_hop"
  }
  let c = mapIntentV2(pointMove, guids)
  check(c.isSome, "bare move maps")
  check(c.get["kind"].getStr == "move", "bare kind move")
  check(c.get["destination"]["map_id"].getInt == 1, "bare map_id")
  check(c.get["destination"]["x"].getFloat == -9100.0, "bare x")
  check(c.get["intent"].getStr == "travel", "bare intent travel")

  let env = parseJson(actionSubmissionPayload(a.get, 42, 2))
  check(env["protocol"].getStr == "vanilla_wow.environment.v1", "protocol")
  check(env["type"].getStr == "action_submission", "type action_submission")
  check(env["expected_frame_id"].getInt == 42, "expected_frame_id")
  check(env["expected_slot"].getInt == 2, "expected_slot")
  check(env["action"]["kind"].getStr == "move", "envelope action")

# --- mapIntent stock party + cast modes ---
block:
  let guids = @["555"]
  check(mapIntentV2(%*{"kind": "accept_party"}, guids).get["kind"].getStr ==
    "accept_party", "accept_party")
  check(mapIntentV2(%*{"kind": "promote_party", "unit_id": 1}, guids)
    .get["target_guid"].getStr == "555", "promote_party guid")
  check(mapIntentV2(%*{"kind": "ready_check"}, guids).get["kind"].getStr ==
    "ready_check", "ready_check")
  let castAct = mapIntentV2(%*{"kind": "cast_spell", "spell": 133, "unit_id": 1},
    guids)
  check(castAct.isSome and castAct.get["target_guid"].getStr == "555", "cast guid")
  let selfCast = mapIntentV2(%*{"kind": "cast_spell", "spell": 688}, @[])
  check(selfCast.isSome and selfCast.get{"cast_without_target"}.getBool,
    "cast without target mode")
  check(mapIntentV2(%*{"kind": "hold"}, guids).isNone, "hold → none")

echo "test_army_projection: ", passed, " checks passed"
