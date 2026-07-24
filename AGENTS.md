# wow-shadow-army — agent rules

## Mission

Build the solo-leveling bot army per `coworld-playbook/games/solo-leveling.md`:
human-in-the-loop first (monofuel plays, bots assist, he reports bugs),
persona populations over single champions, stranger-ready cooperation as the
end state (Softmax mission: cooperate with policies we don't control).

## Hard rules

- **FAIR PLAY — NO COLLUSION.** Seats play as strangers. In-party
  cooperation is legitimate ONLY through the game's own typed contracts
  (party membership, `VANILLA_WOW_RFC_ASSIGNMENT`) and live observations.
  Any edge that depends on our seats recognizing each other out-of-band is
  cheating: mark WONT FIX. Same rule as coworld-playbook/AGENTS.md.
- **Upstream is read-only.** `../coworld-vanilla-wow` is Metta-AI's repo.
  Never commit to it, never vendor client source here. We consume it at
  the `upstream.lock` pin through the `nim_control.v1` boundary. If an
  upstream bug blocks us, document it and tell monofuel — he decides
  whether to report it.
- **Respect the client/bot boundary.** Our layer sees typed frames and
  sends typed goals/actions. No database pokes for progress, no GM-command
  gameplay, no memory reads. (Local GM usage for *observation/testing
  setup* is fine; never as a policy action.)
- **Tests stay green and instant.** `make test` before every commit; unit
  tier has no network, no docker, no sleeps (testing doctrine:
  racha_notes `Programming/testing.md`). Integration tier may use the
  local realm.
- **Naming.** Repo-internal personas use shadow-soldier names (igris,
  beru, tusk, kaisel, ...). One file per persona, one thesis per persona,
  each a pinned hypothesis (see solo-leveling.md persona section).
- **Knowledgebase discipline.** Durable facts the bots learn (map facts,
  tool reliability, postmortems) go in `kb/` as small markdown files the
  brain reads — not into prompts or code comments.
- **Coupling isolation.** Version-specific facts (endpoints, protocol
  labels, thresholds tied to the upstream pin) live in one config module,
  not scattered through tools.

## Session protocol with monofuel

He plays alongside the bots and reports issues in plain language; those
land in `kb/postmortems/` or the playbook queue. Every play session opens
by re-testing the previous session's complaints.
