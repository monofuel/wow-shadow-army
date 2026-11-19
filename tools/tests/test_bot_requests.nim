## Request broker contracts: who is addressed, what may be chosen.

import
  std/[json, os, strutils, unittest],
  ../bot_requests

const
  Murist = "1000007"

proc row(kind, text: string; guid = Murist; name = "Murist"): ChatRow =
  ## One chat row as the seat's observation reports it.
  ChatRow(sequence: 1, kind: kind, senderGuid: guid, senderName: name, text: text)

suite "addressing":
  test "a whisper from the authority is direct":
    let a = row("whisper", "can you stay here").address("Legia", "Murist", Murist)
    check a.scope == scopeDirect and a.text == "can you stay here"

  test "an explicit @recipient in party reaches only that seat":
    let line = row("party", "@Legia come here")
    check line.address("Legia", "Murist", Murist).scope == scopeDirect
    check line.address("Legia", "Murist", Murist).text == "come here"
    check line.address("Vulcan", "Murist", Murist).scope == scopeNone

  test "a raid line is not a request (the seat has no raid reply path)":
    check row("raid", "@Legia come here").address("Legia", "Murist", Murist).scope == scopeNone

  test "a deliberate group request reaches every seat":
    for seat in ["Legia", "Vulcan"]:
      let a = row("party", "@all summon your pets").address(seat, "Murist", Murist)
      check a.scope == scopeGroup and a.text == "summon your pets"

  test "unaddressed party chat and ordinary phrases trigger nobody":
    for text in ["Can you all hear me", "can you come here", "lol", "@Leg come"]:
      check row("party", text).address("Legia", "Murist", Murist).scope == scopeNone
    # A seat literally named Can is not woken by "Can you ...".
    check row("party", "Can you come").address("Can", "Murist", Murist).scope == scopeNone

  test "anyone but the authority is ignored, by guid and name":
    check row("whisper", "stay", guid = "1000012", name = "Kaisel").address(
      "Legia", "Murist", Murist).scope == scopeNone
    check row("whisper", "stay", guid = "1000012", name = "Murist").address(
      "Legia", "Murist", Murist).scope == scopeNone

suite "decisions":
  let offered: seq[MenuItem] = @[("hold_here", "stay"), ("none", "nothing")]

  test "an offered action is accepted":
    let d = parseDecision("""{"intent":"action","choice":"hold_here"}""", offered)
    check d.intent == "action" and d.choice == "hold_here"

  test "an unoffered action is refused, never defaulted":
    expect ValueError:
      discard parseDecision("""{"intent":"action","choice":"summon_pet"}""", offered)

  test "a question never becomes an action job":
    let d = parseDecision("""{"intent":"question","choice":"hold_here"}""", offered)
    check d.intent == "question" and d.choice == "none"

suite "menu":
  test "only feasible actions are offered":
    let petless = %*{"class_id": 9, "known_spells": [686, 688], "active_pet_guid": "0",
      "copper": 35, "level": 5, "inventory_items": []}
    var keys: seq[string]
    for item in menu(petless, false, false): keys.add item.key
    check "summon_pet" in keys
    check "come_here" notin keys and "train" notin keys and "resume" notin keys
    let withPet = %*{"class_id": 9, "known_spells": [688], "active_pet_guid": "77",
      "active_pet_dead": false, "copper": 300, "level": 5,
      "inventory_items": [{"upgrade_score": 4, "required_level": 3}]}
    keys = @[]
    for item in menu(withPet, true, true): keys.add item.key
    check "summon_pet" notin keys
    check "come_here" in keys and "wear_upgrades" in keys and "train" in keys and
      "resume" in keys

  test "replies are one printable line within the chat limit":
    check cleanReply("/w Murist \"hi\"\nthere") == "w Murist hi there"
    check cleanReply("x".repeat(200)).len == 120

suite "operator requests":
  test "pending requests are claimed, and a crash-left claim comes first":
    let jobs = getTempDir() / "test_bot_requests_operator"
    removeDir(jobs)
    createDir(jobs)
    check claimOperator(jobs) == ""
    writeFile(jobs / "operator.jsonl", "{\"key\":\"a\"}\n")
    let claim = claimOperator(jobs)
    check claim == jobs / "operator.claimed.jsonl"
    check not fileExists(jobs / "operator.jsonl")
    check readFile(claim) == "{\"key\":\"a\"}\n"
    writeFile(jobs / "operator.jsonl", "{\"key\":\"b\"}\n")
    check claimOperator(jobs) == claim
    check readFile(claim) == "{\"key\":\"a\"}\n"
    check fileExists(jobs / "operator.jsonl")
    removeDir(jobs)
