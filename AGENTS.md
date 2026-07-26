# wow-shadow-army — agent rules

## Mission

Build the solo-leveling bot army per `coworld-playbook/games/solo-leveling.md`:
human-in-the-loop first (monofuel plays, bots assist, he reports bugs),
persona populations over single champions, stranger-ready cooperation as the
end state (Softmax mission: cooperate with policies we don't control).

Architecture target: racha_notes `AI/game_bots/architecture.md` — three
layers only: **knowledgebase (`kb/`)** / **Lua tool library (`lua/`)** /
**LLM planner** (later). Named intents in Lua; reflexes at the cadence the
upstream controller already owns.

## Hard rules

- **NO PYTHON.** Do not write, extend, or land new Python for bots, policy,
  tools, brain loops, or tests of those layers. Policy and named-intent
  tools live in **`lua/`** (and Lua unit tests under `lua/tests/`). The
  `brain/*.py` tree is legacy drift from a prior agent pass — do not grow
  it; do not copy its patterns. If a task seems to "need Python," stop and
  either (a) call **upstream** (Nim client / existing goals / control
  surface) or (b) add a **Lua** tool. One-off host scripts outside the bot
  army are monofuel's call, not an agent default.
- **Rely on upstream as much as possible.** `../coworld-vanilla-wow` already
  owns perception, pathing, combat sequencing, looting, formation, recovery,
  and the `nim_control.v1` socket. Do not reimplement that stack here. Prefer
  typed goals and thin named intents that *select* among upstream
  capabilities over home-grown action FSMs. If upstream is missing a
  capability, document the gap and tell monofuel — do not paper over it with
  a local Python (or other) policy brain.
- **FAIR PLAY — NO COLLUSION.** Seats play as strangers. In-party
  cooperation is legitimate ONLY through the game's own typed contracts
  (party membership, `VANILLA_WOW_RFC_ASSIGNMENT`) and live observations.
  Any edge that depends on our seats recognizing each other out-of-band is
  cheating: mark WONT FIX. Same rule as coworld-playbook/AGENTS.md.
- **Upstream is read-only.** Never commit to `../coworld-vanilla-wow`, never
  vendor client source here. We consume it at the `upstream.lock` pin through
  the `nim_control.v1` boundary. If an upstream bug blocks us, document it
  and tell monofuel — he decides whether to report it.
- **Respect the client/bot boundary.** Our layer sees typed frames and
  sends typed goals/actions. No database pokes for progress, no GM-command
  gameplay, no memory reads. (Local GM usage for *observation/testing
  setup* is fine; never as a policy action.)
- **Tests stay green and instant.** `make test` before every commit; unit
  tier has no network, no docker, no sleeps (testing doctrine:
  racha_notes `Programming/testing.md`). Integration tier may use the
  local realm. Prefer Lua tool tests; do not add Python unit suites.
- **Naming.** Repo-internal personas use shadow-soldier names (igris,
  beru, tusk, kaisel, ...). One file per persona, one thesis per persona,
  each a pinned hypothesis (see solo-leveling.md persona section).
- **Knowledgebase discipline.** Durable facts the bots learn (map facts,
  tool reliability, postmortems) go in `kb/` as small markdown files the
  planner/tools read — not into prompts or code comments.
- **Coupling isolation.** Version-specific facts (endpoints, protocol
  labels, thresholds tied to the upstream pin) live in one config module,
  not scattered through tools.

## Session protocol with monofuel

He plays alongside the bots and reports issues in plain language; those
land in `kb/postmortems/` or the playbook queue. Every play session opens
by re-testing the previous session's complaints.
