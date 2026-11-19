## Read-only private-realm system check; deliberately outside offline test_*.
## Run inside this repo's nix develop with the existing private realm running.
## Exercises the production membership selector in the real MariaDB engine.
## It creates no accounts, characters, currency, tables or other world state.
import std/[os, osproc, sets, streams, strutils]
import ../system_server

let inventory = fetchRealmInventory()
doAssert inventory.error.len == 0, inventory.error
var expected, actual: HashSet[string]
expected.incl(AdminRequesterName)
for seat in seatTargets(): expected.incl(seat.name)
for character in inventory.characters: actual.incl(character.name)
doAssert actual == expected,
  "actual private character/account memberships differ from configured roster"

let scaled = scaledSeatTargets()
doAssert scaled.len > 0, "system check requires the existing home roster"
let first = scaled[0]
# The parser admits only alphanumeric identity fields; quote these as SQL
# literals as well so the test's synthetic source cannot introduce syntax.
proc literal(value: string): string = "'" & value.replace("'", "''") & "'"
let samples = """WITH sample AS (
 SELECT 1 id, 'Murist' name, 'MONOFUEL' username, 50 level, 2000000 money
 UNION ALL SELECT 2, 'Shadowfel', 'SHADOW1', 1, 31
 UNION ALL SELECT 3, """ & literal(first.name) & ", " & literal(first.account) & """, 60, 3000000
 UNION ALL SELECT 4, 'Botwarrior', 'BOT1', 50, 200000
 UNION ALL SELECT 5, 'Shadowfel', 'BOT1', 1, 200000
 UNION ALL SELECT 6, 'Kaisel', 'SHADOW9', 3, 14
)
SELECT COUNT(*), SUM(c.money) FROM sample c JOIN sample a ON a.id = c.id
WHERE """ & inventoryPartyScope()
var process = startProcess("docker", args = @[
  "exec", getEnv("SYSTEM_MYSQL_CONTAINER", "coworld-vmangos-coworld-game-1"),
  "mariadb", "--protocol=SOCKET",
  "--socket=/tmp/coworld-mariadb-run/mysqld.sock", "-uroot",
  "--batch", "--raw", "--skip-column-names", "--execute", samples],
  options = {poUsePath, poStdErrToStdOut})
let output = process.outputStream.readAll()
let code = process.waitForExit()
process.close()
doAssert code == 0, output
doAssert output.strip == "3\t5000031",
  "eligible high-level/high-balance members must count; fixtures and wrong accounts must not: " & output
echo "PASS real configured memberships; synthetic high-gold/wrong-account/QA exclusion in MariaDB; no DB writes"
