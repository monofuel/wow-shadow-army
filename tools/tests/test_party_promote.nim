## Pure unit tests for party_promote.decidePromote (no network).
import ../party_promote

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

let murist = PromoteMember(name: "Murist", entityIndex: 2)
let igris = PromoteMember(name: "Igris", entityIndex: 3)
let members = [murist, igris]

# (a) bot is leader + Murist in party → promote
var d = decidePromote(
  selfName = "Tusk",
  partyLeaderName = "Tusk",
  preferredLeader = "Murist",
  members = members,
  promoteKindAllowed = true,
  promoteTargetAllowed = true
)
check(d.shouldPromote and d.targetIndex == 2 and d.targetName == "Murist",
  "bot-leader promotes Murist")
check(d.reason == "promote_preferred_leader", "promote reason")

# (b) Murist already leader → no spam
d = decidePromote(
  selfName = "Tusk",
  partyLeaderName = "Murist",
  preferredLeader = "Murist",
  members = members,
  promoteKindAllowed = true,
  promoteTargetAllowed = true
)
check(not d.shouldPromote, "already-leader no promote")
check(d.reason == "self_not_party_leader", "not leader reason")

# Self is Murist already preferred and leader
d = decidePromote(
  selfName = "Murist",
  partyLeaderName = "Murist",
  preferredLeader = "Murist",
  members = members,
  promoteKindAllowed = true,
  promoteTargetAllowed = true
)
check(not d.shouldPromote, "Murist self preferred no promote")
check(d.reason == "self_is_preferred", "self preferred reason")

# (c) Murist not in party → no promote
d = decidePromote(
  selfName = "Tusk",
  partyLeaderName = "Tusk",
  preferredLeader = "Murist",
  members = [igris],
  promoteKindAllowed = true,
  promoteTargetAllowed = true
)
check(not d.shouldPromote, "Murist absent no promote")
check(d.reason == "preferred_not_in_party", "absent reason")

# Mask off → no promote
d = decidePromote(
  selfName = "Tusk",
  partyLeaderName = "Tusk",
  preferredLeader = "Murist",
  members = members,
  promoteKindAllowed = false,
  promoteTargetAllowed = true
)
check(not d.shouldPromote and d.reason == "promote_not_masked", "kind masked off")

d = decidePromote(
  selfName = "Tusk",
  partyLeaderName = "Tusk",
  preferredLeader = "Murist",
  members = members,
  promoteKindAllowed = true,
  promoteTargetAllowed = false
)
check(not d.shouldPromote and d.reason == "promote_not_masked", "target masked off")

echo "test_party_promote: ", passed, " checks passed"
