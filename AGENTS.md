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
- **DO NOT CHEAT.** We need to do things properly so we can win in the
  tournament. If you cheat, you only make things harder: you mask real
  issues in pathing, combat, quests, party, and recovery that we would
  otherwise find and fix. Forbidden as progress or “just this once”
  shortcuts: GM level/XP/gold/items, force-complete quests, DB progress
  pokes, memory cheats, out-of-band collusion between seats, or any other
  path that a stranger client on the live realm cannot take. When something
  is hard or stuck, **document the gap** and fix the real pipeline — do not
  paper over it with admin power.
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
  gameplay, no memory reads. Local GM is allowed only for **observation /
  testing setup** (e.g. revive after a stuck corpse, tele to a known start
  so you can re-test). Never for levels, XP, quest completion, loot, or
  any outcome that should come from play. When in doubt, do not use GM.
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

## Operator surface (human vs agent)

- **Human operator only interacts with play clients:** `make play` or
  `make play-classic` (and in-game play / bug reports). That is the
  intended human surface.
- **Do not instruct the user to run commands.** Agents must not say
  “please run `make escort-army`”, “restart the bots”, “check the log
  with …”, or hand off shell steps. Execute those yourself.
- **Agents own everything else automatically:** realm/server bring-up,
  logging config, accounts, headless bot seats, `army_host` / escort /
  grind brains, SOAP/admin recovery when used for **setup only**, log
  greps, rebuilds, tests, upstream pulls/rebases (fork), pin updates,
  and postmortems. Prefer Makefile targets already in-repo.
- If something needs a human decision (force-push, report upstream bug,
  irreversible data loss, tournament-risking cheat), **state the decision
  and options** — do not dump a command list for the operator to type.

## Session protocol with monofuel

He plays alongside the bots and reports issues in plain language; those
land in `kb/postmortems/` or the playbook queue. Every play session opens
by re-testing the previous session's complaints. Agents keep the bot/server
stack healthy without asking him to run ops commands.
