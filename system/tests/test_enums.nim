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

  test "parse roster TSV":
    let tsv = "Nightsun\t30\t7\t8\t2000000\t0\nBotmage\t30\t8\t2\t2000000\t1\n"
    let rows = parseRosterTsv(tsv)
    check rows.len == 2
    check rows[0].name == "Nightsun"
    check rows[0].className == "Shaman"
    check rows[0].raceName == "Troll"
    check rows[0].gold == "200g 0s 0c"
    check rows[0].online == false
    check rows[1].name == "Botmage"
    check rows[1].className == "Mage"
    check rows[1].raceName == "Orc"
    check rows[1].online == true
