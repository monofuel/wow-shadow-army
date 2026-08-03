## Unit tests for classic 1.12 race/class enum maps and gold formatting.
## Run: nim r system/tests/test_enums.nim  (or make test-nim)
## Not part of `make test` — that tier stays Lua-only / no nim required.

import
  std/[strutils, unittest],
  ../system_server

suite "classic 1.12 enums":
  test "race names":
    check raceName(1) == "Human"
    check raceName(2) == "Orc"
    check raceName(4) == "Night Elf"
    check raceName(8) == "Troll"
    check raceName(99).startsWith("Race#")

  test "class names":
    check className(1) == "Warrior"
    check className(4) == "Rogue"
    check className(5) == "Priest"
    check className(7) == "Shaman"
    check className(8) == "Mage"
    check className(11) == "Druid"
    check className(99).startsWith("Class#")

  test "format gold":
    check formatGold(0) == "0g 0s 0c"
    check formatGold(2000000) == "200g 0s 0c"
    check formatGold(12345) == "1g 23s 45c"

  test "parse roster TSV (legacy 6 cols)":
    let tsv = "Nightsun\t30\t7\t8\t2000000\t0\nBotmage\t30\t8\t2\t2000000\t1\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 2
    check rows[0].name == "Nightsun"
    check rows[0].className == "Shaman"
    check rows[0].raceName == "Troll"
    check rows[0].gold == "200g 0s 0c"
    check rows[0].online == false
    check rows[0].xp == 0
    check rows[1].name == "Botmage"
    check rows[1].className == "Mage"
    check rows[1].raceName == "Orc"
    check rows[1].online == true

  test "parse roster TSV with xp columns":
    # name level class race money online xp next_level_xp
    let tsv = "Shadowfel\t4\t9\t5\t161\t1\t178\t2100\nIgris\t1\t9\t5\t1\t1\t62\t400\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 2
    check rows[0].name == "Shadowfel"
    check rows[0].level == 4
    check rows[0].xp == 178
    check rows[0].nextLevelXp == 2100
    check rows[0].xpToLevel == 1922
    check rows[0].xpPct == 8  # 178*100/2100
    check rows[1].name == "Igris"
    check rows[1].xpToLevel == 338
    check rows[1].xpPct == 15  # 62*100/400

  test "parse roster TSV with life + zone columns":
    # flags 8192 = ghost; health 1; zone 85 Tirisfal; map 0
    let tsv = "Shadowfel\t4\t9\t5\t161\t1\t178\t2100\t8192\t1\t85\t0\tTirisfal Glades\n" &
              "Tusk\t1\t1\t5\t0\t1\t0\t400\t0\t100\t85\t0\tTirisfal Glades\n" &
              "Murist\t7\t9\t5\t0\t0\t0\t5000\t0\t200\t85\t0\tTirisfal Glades\n" &
              "Deadbody\t2\t1\t5\t0\t1\t0\t900\t0\t0\t154\t0\tDeathknell\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 4
    check rows[0].life == "ghost"
    check rows[0].isGhost
    check rows[0].zoneName == "Tirisfal Glades"
    check rows[0].zoneId == 85
    check rows[0].mapId == 0
    check rows[1].life == "alive"
    check rows[1].className == "Warrior"
    check not rows[1].isGhost
    check rows[2].life == "offline"
    check rows[2].online == false
    check rows[3].life == "dead"
    check rows[3].zoneName == "Deathknell"
    check lifeLabel("ghost") == "Ghost"

  test "parse roster TSV with HP/MP vitals columns":
    # 18 cols: … zone_name power1 power2 power4 basehp basemana
    # Shadowfel warlock lvl4: mana 182, basehp 48, basemana 117
    # Tusk warrior: rage 40, basehp 20
    let tsv =
      "Shadowfel\t4\t9\t5\t161\t1\t178\t2100\t0\t108\t85\t0\tTirisfal Glades\t182\t0\t0\t48\t117\n" &
      "Tusk\t1\t1\t5\t0\t1\t0\t400\t0\t70\t85\t0\tTirisfal Glades\t0\t40\t0\t20\t0\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 2
    check rows[0].health == 108
    check rows[0].maxHealth == 108 # live > class base
    check rows[0].powerKind == "mana"
    check rows[0].power == 182
    check rows[0].maxPower == 182 # live mana > basemana
    check rows[1].className == "Warrior"
    check rows[1].powerKind == "rage"
    check rows[1].power == 40
    check rows[1].maxPower == 100
    check rows[1].maxHealth == 70
    let html = renderVitalsCell(rows[0])
    check "HP" in html
    check "MP" in html
    check "108" in html

  test "parse roster TSV with position columns":
    # 21 cols: … basemana position_x y z
    let tsv =
      "Igris\t1\t9\t5\t1\t1\t97\t400\t0\t63\t85\t0\tTirisfal Glades\t110\t0\t0\t23\t90\t1843.5\t1590.1\t93.3\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 1
    check abs(rows[0].posX - 1843.5) < 0.01
    check abs(rows[0].posY - 1590.1) < 0.01
    check abs(rows[0].posZ - 93.3) < 0.01
    let pos = renderPosCell(rows[0])
    check "1844" in pos or "1843" in pos
    check "1590" in pos

  test "primaryPower by class":
    check primaryPower(1, 0, 55, 0, 0) == (kind: "rage", cur: 55, max: 100)
    check primaryPower(4, 0, 0, 80, 0) == (kind: "energy", cur: 80, max: 100)
    check primaryPower(9, 200, 0, 0, 300) == (kind: "mana", cur: 200, max: 300)

  test "roster display order and seat ports":
    check rosterSortRank("Murist") < rosterSortRank("Shadowfel")
    check rosterSortRank("Shadowfel") < rosterSortRank("Igris")
    check rosterSortRank("Igris") < rosterSortRank("Tusk")
    check rosterSortRank("Tusk") < rosterSortRank("Beru")
    check rosterSortRank("Beru") < rosterSortRank("Cowcam")
    check seatControlPort("Shadowfel") == 41116
    check seatControlPort("Igris") == 41117
    check seatControlPort("Tusk") == 41118
    check seatControlPort("Beru") == 41119
    check seatControlPort("Murist") == 0
    var mixed = @[
      Character(name: "Beru", level: 1, life: "alive", online: true),
      Character(name: "Murist", level: 7, life: "offline", online: false),
      Character(name: "Igris", level: 1, life: "ghost", online: true),
      Character(name: "Shadowfel", level: 4, life: "alive", online: true),
    ]
    sortCharactersForDisplay(mixed)
    check mixed[0].name == "Murist"
    check mixed[1].name == "Shadowfel"
    check mixed[2].name == "Igris"
    check mixed[3].name == "Beru"
    let summary = armySummary(mixed)
    check "1 online" in summary or "online" in summary
    check "ghost" in summary

  test "lifeState rules":
    check lifeState(online = true, characterFlags = 0, health = 100) == "alive"
    check lifeState(online = true, characterFlags = 8192, health = 1) == "ghost"
    check lifeState(online = false, characterFlags = 8192, health = 1) == "ghost"
    check lifeState(online = true, characterFlags = 0, health = 0) == "dead"
    check lifeState(online = false, characterFlags = 0, health = 100) == "offline"

  test "xpProgress clamps":
    check xpProgress(50, 400) == (toLevel: 350, pct: 12)
    check xpProgress(400, 400) == (toLevel: 0, pct: 100)
    check xpProgress(0, 0) == (toLevel: 0, pct: 0)

  test "foundation seat filter":
    check isFoundationSeat("Botmage")
    check isFoundationSeat("botpriest")
    check isFoundationSeat("Nightsun")
    check isFoundationSeat("Cowcam")
    check not isFoundationSeat("Murist")
    check not isFoundationSeat("Shadowfel")
    check not isFoundationSeat("Igris")
    let all = @[
      Character(name: "Murist", level: 6),
      Character(name: "Botmage", level: 30),
      Character(name: "Nightsun", level: 30),
      Character(name: "Igris", level: 1),
    ]
    let mainOnly = filterCharacters(all, includeFoundation = false)
    check mainOnly.len == 2
    check mainOnly[0].name == "Murist"
    check mainOnly[1].name == "Igris"
    check filterCharacters(all, includeFoundation = true).len == 4
