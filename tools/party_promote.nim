## Pure party-leader hand-off decision (no I/O).
##
## When a bot seat is the current party leader and the preferred human (Murist)
## is online in the group, emit promote once. Idempotent when already correct.

import std/strutils

type
  PromoteMember* = object
    name*: string
    entityIndex*: int ## 1-based policy entity index; 0 if unknown

  PromoteDecision* = object
    shouldPromote*: bool
    targetName*: string
    targetIndex*: int
    reason*: string

proc decidePromote*(
  selfName: string;
  partyLeaderName: string;
  preferredLeader: string;
  members: openArray[PromoteMember];
  promoteKindAllowed: bool;
  promoteTargetAllowed: bool
): PromoteDecision =
  ## Return a promote intent when this seat holds leadership and should hand
  ## it to preferredLeader. Pure — no sockets, no frame objects.
  result = PromoteDecision(shouldPromote: false, targetIndex: 0, reason: "noop")
  let selfN = selfName.strip()
  let leaderN = partyLeaderName.strip()
  let preferN = preferredLeader.strip()
  if selfN.len == 0 or preferN.len == 0:
    result.reason = "missing_names"
    return
  if preferN.cmpIgnoreCase(selfN) == 0:
    result.reason = "self_is_preferred"
    return
  if leaderN.cmpIgnoreCase(selfN) != 0:
    result.reason = "self_not_party_leader"
    return
  # Preferred already party leader.
  if leaderN.cmpIgnoreCase(preferN) == 0:
    result.reason = "preferred_already_leader"
    return
  var found: PromoteMember
  var ok = false
  for m in members:
    if m.name.strip().cmpIgnoreCase(preferN) == 0:
      found = m
      ok = true
      break
  if not ok:
    result.reason = "preferred_not_in_party"
    return
  if found.entityIndex <= 0:
    result.reason = "preferred_entity_missing"
    return
  if not promoteKindAllowed or not promoteTargetAllowed:
    result.reason = "promote_not_masked"
    return
  result.shouldPromote = true
  result.targetName = found.name
  result.targetIndex = found.entityIndex
  result.reason = "promote_preferred_leader"
