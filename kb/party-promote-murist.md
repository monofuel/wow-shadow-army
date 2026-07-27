# Auto-promote Murist to party leader

When a bot seat is party leader and Murist is in the group, `army_host`
selects factorized `promote_party` (fork: CMSG_GROUP_SET_LEADER) for Murist.

Requires bot clients rebuilt with `bakPromoteParty` (restart seats after fork
change). Pure decide: `tools/party_promote.nim`. Rate limit 5s.

Run: `make escort-army` (or army_host on the current leader seat) with `--leader=Murist`.
