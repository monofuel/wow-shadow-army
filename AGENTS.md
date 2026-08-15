# wow-shadow-army — agent rules

**Vocabulary: `docs/terms.md` — read it first and use those terms
consistently** (upstream, the fork, seats, foundation seats, fair play, …).

## Scope

This repo is home base for our **WoW coworld** experiments, and its rules
govern how we work in the sibling wow repos too:

- `../coworld-vanilla-wow` — **upstream** checkout (read-only, see hard rules).
  Actively developed by other Softmax engineers; staying current with it is a
  competition requirement.
- `../monofuel-vanilla-wow` — **the fork**, where our changes live.
  **Client customizations only — never touch server components** (take
  upstream's server code verbatim). Sync upstream `main` regularly; merge
  conflicts in client files are expected and get resolved, not avoided.
- `../coworld-vanilla-wow-xr` — xr client-build testing checkout.
- `../wow-classic-data` — canonical game data store (one copy; everything
  else symlinks to it).

- please follow the general rules of `../autoresearch` when relevant

## Mission

Build the solo-leveling bot army per `coworld-playbook/games/solo-leveling.md`:
human-in-the-loop first (monofuel plays, bots assist, he reports bugs),
persona populations over single champions, stranger-ready cooperation as the
end state (Softmax mission: cooperate with policies we don't control).

Architecture target: racha_notes `AI/game_bots/architecture.md` — three
layers only: **knowledgebase (`kb/`)** / **Lua tool library (`lua/`)** /
**LLM planner** (later). Named intents in Lua; reflexes at the cadence the
upstream controller already owns.

Only **`lua/`** exists today. `kb/` is a reserved empty folder and the LLM
planner is unbuilt — see "Docs vs knowledgebase" below before writing a
markdown file anywhere.

Our tools need to be fast and robust. we only have a week for each coworld competition and can't waste time on buggy or slow tools.

## Hard rules

- **NO PYTHON.** Do not write, extend, or land new Python for bots, policy,
  tools, brain loops, or tests of those layers. Policy and named-intent
  tools live in **`lua/`** (and Lua unit tests under `lua/tests/`). The old
  `brain/*.py` tree was deleted 2026-07-27 — do not resurrect it or copy
  its patterns from git history. If a task seems to "need Python," stop and
  either (a) call **upstream** (Nim client / existing goals / control
  surface) or (b) add a **Lua** tool. One-off host scripts outside the bot
  army are monofuel's call, not an agent default.
- **Rely on the client stack as much as possible.** The fork already owns
  typed perception and actions, rendering, pathing, combat mechanics, and the
  generic embedded `lua-bot` boundary. Persistent-home strategy lives in
  `lua/entry/home.lua`; generic Observation projection, intent validation, and
  lowering live in `../monofuel-vanilla-wow/bots/lua_bot/`. Do not recreate
  client mechanics in the policy.
- **DO NOT CHEAT.** We need to do things properly so we can win in the
  tournament. If you cheat, you only make things harder: you mask real
  issues in pathing, combat, quests, party, and recovery that we would
  otherwise find and fix. Forbidden as progress or “just this once”
  shortcuts: GM level/XP/gold/items, force-complete quests, DB progress
  pokes, memory cheats, out-of-band collusion between seats, or any other
  path that a stranger client on the live realm cannot take. When something
  is hard or stuck, **document the gap** and fix the real pipeline — do not
  paper over it with admin power.
- **NO TELEPORT FOR MURIST unless monofuel directly orders it.** Do not
  SOAP/GM/DB teleport the human player Murist, including “just recovery” or
  “just setup,” and do not use summon/appear/goname or equivalent position
  control on him. **Only** tele Murist when monofuel explicitly names him and
  the destination.
- **Scenario bots may use checkpoint teleports for local test setup.** Agents
  may automatically position disposable scenario/test bots (for example
  Northbound in Traverse) at named checkpoints to isolate and iterate on a
  segment. A checkpointed run proves only that segment: never count it as an
  untouched end-to-end run or tournament progress, and never use teleports to
  bypass gameplay in a claimed progress result. This exception does not permit
  GM level/XP/gold/items, quest completion, loot, or other progress cheats.
- **FAIR PLAY — NO COLLUSION.** Seats play as strangers. In-party
  cooperation is legitimate ONLY through the game's own typed contracts
  (party membership, `VANILLA_WOW_RFC_ASSIGNMENT`) and live observations.
  Any edge that depends on our seats recognizing each other out-of-band is
  cheating: mark WONT FIX. Same rule as coworld-playbook/AGENTS.md.
- **Upstream is read-only.** Never commit to `../coworld-vanilla-wow`, never
  vendor client source here. We track it with `upstream.lock`; client changes
  we need go on **the fork**
  (`../monofuel-vanilla-wow`) — client code only, never server components
  (see Scope and `docs/terms.md`). If an upstream bug blocks us, document it
  and tell monofuel — he decides whether to report it.
- **Respect the client/bot boundary.** Our layer sees typed frames and
  sends typed goals/actions. No database pokes for progress, no GM-command
  gameplay, no memory reads. Local GM for **observation / testing setup** is
  narrow: e.g. account creation, server logs, and scenario-bot checkpoint
  positioning under the rule above. Never use it for Murist position control
  without his explicit order, or for levels, XP, quest completion, loot, or
  claimed progress. When in doubt, do not use GM.
- **Tests stay green and instant.** `make test` before every commit; unit
  tier has no network, no docker, no sleeps (testing doctrine:
  racha_notes `Programming/testing.md`). Integration tier may use the
  local realm. Prefer Lua tool tests; do not add Python unit suites.
- **Naming.** Repo-internal personas use shadow-soldier names (igris,
  beru, tusk, kaisel, ...). One file per persona, one thesis per persona,
  each a pinned hypothesis (see solo-leveling.md persona section).
- **Docs vs knowledgebase.** Two different audiences — do not mix them.
  **`docs/` is for humans and agents working on this repo**: architecture,
  protocol notes, upstream pins and gaps, build/run steps, postmortems of our
  own bugs, anything naming a file path, Nim flag, Makefile target, or packet.
  **`kb/` is bot memory** — facts a seat could act on *in-game* (map and route
  facts, quest giver/item/mob ids, tool reliability learned from play), small
  and one per file, written for the LLM planner to read at play time.
  The test: *would a bot mid-fight use this, or only an engineer at a
  keyboard?* Commit hashes, branch names, and "run `make …`" are always
  `docs/`. `kb/` is **empty on purpose** (see `kb/README.md`) — its only
  claimed reader was the deleted Python `brain/`, so nine engineering docs
  drifted in there and moved to `docs/` on 2026-08-03. Do not refill it to
  make it look used; it stays empty until the planner exists to read it.
- **Coupling isolation.** Version-specific facts (endpoints, protocol
  labels, thresholds tied to the upstream pin) live in one config module,
  not scattered through tools.

## Operator surface (human vs agent)

- **Human operator only interacts with play clients:** `make play` or
  `make play-classic` (and in-game play / bug reports). That is the
  intended human surface.
- **Do not instruct the user to run commands.** Agents must not say
  “please run `make home-army-start`”, “restart the bots”, “check the log
  with …”, or hand off shell steps. Execute those yourself.
- **Agents own everything else automatically:** realm/server bring-up,
  logging config, accounts, embedded Lua headless bot seats, SOAP/admin
  recovery when used for **setup only**, log
  greps, rebuilds, tests, upstream pulls/rebases (fork), pin updates,
  and postmortems. Prefer Makefile targets already in-repo.
- If something needs a human decision (force-push, report upstream bug,
  irreversible data loss, tournament-risking cheat), **state the decision
  and options** — do not dump a command list for the operator to type.

- DO NOT run gui apps unless specifically directed. this interrupts whatever the human is doing.

## Dashboard rules

- a dashboard is for buttons, metrics, and dashboard like stuff
- a dashboard is NOT documentation, a tutorial, or a conversation. DO NOT include instructions, comments, implementation details, or explanations on a dashboard unless directly requested. 

- the system dashboard should be as automated as possible. don't make the user do tons of work, they want a dashboard that works at a glance.
  - things should auto refresh
  - NEVER expect the user to run one-off bash scripts or make targets to refresh data, that is stupid.
  - AVOID 'refresh' buttons unless the user asks for it (eg: if data is very slow or heavy to fetch)

- dashboards need to give useful data at a glance to the user. they are juggling dozens of tasks, they don't need to manually fiddle with stupid refresh tools to get things lined up.
  - presenting stale data to the user and lieing to them that it's fresh is BAD.

## The System service (dashboard) — restart after changes

The System (dashboard + MCP, `system/system_server.nim`) runs as the systemd
**user** service `wow-system` from this repo checkout. `nim r` recompiles on
every start, so **restarting the service is how a dashboard change goes
live** — there is no separate build or deploy step.

After editing `system/system_server.nim` (agent owns all of this):

1. `make test` — must be green before restarting.
2. `systemctl --user restart wow-system`
3. Verify: `curl -sS http://127.0.0.1:7777/healthz` returns ok (allow a few
   seconds for the recompile), and the change is visible on
   `http://127.0.0.1:7777/`.
4. Logs when something is wrong: `journalctl --user -u wow-system -f`
   (compile errors land here — the service retries every 15s until the code
   compiles again).

Other commands: `systemctl --user status wow-system` (state),
`systemctl --user stop wow-system` / `start wow-system` (lifecycle). The unit
source lives at `tools/wow-system.service` (live copy in
`~/.config/systemd/user/`); the launcher is `tools/run_system.sh`. Do not run
`make system` or a stray `nim r system/system_server.nim` while the service
is up — port 7777 is taken.

## Shadow Advisor — make monofuel's job easy

The vanilla-client **ShadowArmy advisor** (`addons/ShadowArmy/`) is the
human seat. Its job is to reduce cognitive load while monofuel plays and
reports bugs — not to invent a second control language he has to memorize.

- **UI or fully automated. Period.** Any capability monofuel is expected to
  use mid-play must be either (a) a clear control on the advisor panel /
  windows / map UI, or (b) automatic with a sensible default and an easy
  off-switch. Prefer automation when the decision is obvious; prefer a
  button/toggle when judgment is still his.
- **Do not ship “remember `/sa …`” as the product.** Slash commands are a
  **dev/power-user escape hatch** (reload, debug, off-screen recovery), not
  the primary operator path. If a feature only exists as `/sa foo`, it is
  unfinished — add UI or auto it before calling the work done.
- **Do not tell him to type slash commands in play.** Agents and docs aimed
  at the human seat should point at what is on screen or what already runs
  itself. Never hand him a `/sa` cheat sheet as the way to use the advisor.
- **Make the job easier, not harder.** New advisor surface area that
  demands memory, setup rituals, or extra mid-fight keystrokes is a
  regression. When in doubt: fewer things to remember, more things that
  Just Work, overrides available without a manual.

See also: `docs/advisor-autopilot.md` (L0–L5 ladder) and `docs/advisor.md`.

## Shadow Advisor — live update / reload path

When monofuel is in `make play-classic`, agents push addon changes **without
making him restart the client or type slash commands.** Detail lives in
`docs/the-system-loop.md` and `system/README.md`; the agent protocol is:

### Layout (source of truth)

- Edit **`addons/ShadowArmy/`** in the repo (Lua + `.toc`). That tree is the
  only place agents write advisor code.
- `tools/play_classic.sh` **symlinks** each `addons/*` into
  `local_classic/client/Interface/AddOns/` on launch (wine follows host
  symlinks). Disk edits are what the client reloads — no separate copy step.
- **New addon folder or `.toc` name change** needs a **full client restart
  once** (TOC scan at launch). Pure `.lua` edits do not.

### After every advisor edit (agent owns this)

1. **Bump `REV`** in `addons/ShadowArmy/ShadowArmy.lua` (string like `"r24"`).
   The System proves a reload by seeing a fresh `<SA> loaded rev=…` line.
2. **Parse-check** with `luac -p` on touched Lua (Lua 5.0-safe syntax).
3. Ensure **`make system`** is up (http://127.0.0.1:7777) and the realm is
   running (`make start-server`) so SOAP + Chat.log tail work.
4. Call MCP **`reload_addon`** (or dashboard **Reload addon** → `POST /reload`).
   That SOAP-announces `<SYS> reload` to every client.
5. Confirm success via **`addon_events`** / dashboard: a new `loaded` event
   with the **new** rev. Timeout (~6s) with no `loaded` usually means a
   file-scope Lua error or the human seat is not logged in — check events
   and fix; do not dump a `/sa` checklist on monofuel.

### What monofuel sees (and why he rarely does anything)

This 1.12/wine build often **gates** programmatic `ReloadUI()` outside a
hardware event. The addon already handles that:

1. Tries free paths (`ReloadUI` / `ConsoleExec("reloadui")`).
2. If those no-op: shows a green **Reload!** button on the panel and arms
   the **next out-of-combat action-bar press** so a normal keypress applies
   the reload.

Monofuel’s job at most: notice Reload! / press a bar key when safe. Agents
**must not** tell him to type `/sa reload` or `/console reloadui` as the
happy path — that is the escape hatch, not the product.

### Do / don’t

| Do | Don’t |
|---|---|
| Edit repo `addons/ShadowArmy/`, bump `REV`, `luac -p`, `reload_addon` | Ask monofuel to restart wine for every Lua tweak |
| Confirm `loaded rev=<new>` before claiming the fix is live | Treat `reloading from-rev=…` as the new rev (that line is the *old* rev) |
| Keep The System running during play sessions that iterate the advisor | Hand him slash-command reload recipes mid-fight |
| Full client restart only for new AddOn folders / TOC changes | Copy files into `local_classic/…` by hand (symlink is already the path) |

## Session protocol with monofuel

He plays alongside the bots and reports issues in plain language; those
land in `docs/postmortems/` or the playbook queue. Every play session opens
by re-testing the previous session's complaints. Agents keep the bot/server
stack healthy without asking him to run ops commands.
