# Lua policy architecture

Target architecture for external Lua policy in wow-shadow-army: how goals
are selected, how tools are shared, and how hosts call into `lua/`.

Vocabulary: `docs/terms.md`. Transport and projection: `docs/interfaces.md`.
Hard constraints (no Python policy, fair play, frozen frame table): `AGENTS.md`.

## Layers

```text
┌─────────────────────────────────────────────────────────────┐
│  Entrypoints (modes) — top-level goal only                    │
│  lua/entry/<mode>.lua                                         │
└────────────────────────────┬────────────────────────────────┘
                             │ calls named tools
┌────────────────────────────▼────────────────────────────────┐
│  Shared tools — named intents, pure decide(frame, args)     │
│  lua/tools/*                                                  │
└────────────────────────────┬────────────────────────────────┘
                             │ intent tables
┌────────────────────────────▼────────────────────────────────┐
│  Host adapter (Nim) — lua-bot pilot: view + intent + exec   │
│  monofuel-vanilla-wow/bots/lua_bot/ (in-process, -d:luaBotVm)│
└────────────────────────────┬────────────────────────────────┘
                             │ AgentFrame / AgentAction
┌────────────────────────────▼────────────────────────────────┐
│  Upstream nim client (WS /env) — no our Lua inside client   │
└─────────────────────────────────────────────────────────────┘
```

Optional upper layers when a mode needs them: **`kb/`** (planner facts readable
at play time) and an **LLM planner** that selects named tools. Modes may run
with pure Lua entry + tools alone.

**Coupling rule:** Lua never sees MessagePack, frame kinds, or HTTP. The host
projects each frame into a frozen plain table (`projectV2` or successor) and
lowers intent tables to typed actions (`mapIntentV2` or successor). Upstream
churn hits Nim once; tools and entrypoints stay stable.

## Modes

One physical `lua/` tree. Five **modes**, each a thin entrypoint that owns a
single top-level goal and reuses shared tools. Not five independent codebases.

| Mode | Top-level goal | Runtime |
|---|---|---|
| **shadow_army** | Cooperate with the human seat on the local private realm (escort, grind, quest assist) while a human plays on the vanilla client | Local realm + `army_host` seats |
| **persistent** | Advance the durable hosted account (level / XP) across sealed windows | Hosted `persistent-wow` |
| **accelerated** | Maximize level progress in a short 10× fresh-start episode | Hosted `accelerated-wow` |
| **speedrun** | Clear RFC as a five-seat party under one policy image | Hosted `speedrun-wow` |
| **traverse** | Maximize Kalimdor northing (map 1) under fair-play rules | Hosted / local `traverse-wow` |

Separate entrypoints exist because the top-level goals, fixtures, and host
contracts differ (human party leader vs solo durable account vs 10× fresh start
vs five RFC roles vs continent northing). Shared movement, combat primitives,
death recovery, form upkeep, and the frozen frame table live in tools. Only the
goal selector lives in the entrypoint.

Fair-play isolation follows from this split: traverse must not ship an authored
continent route as policy; shadow_army may keep human-centric escort heuristics.
Modes must not accidentally run each other's top-level goal.

## Entrypoint contract

Each entrypoint:

1. Declares a **mode name** and a one-sentence **top-level goal**.
2. Exposes `decide(frame, args) → intent | nil` for the host every tick (same
   shape as tools, so hosts stay simple).
3. **Selects and sequences tools**; rarely inlines logic that belongs in
   `lua/tools/`.
4. Does **not** reimplement combat or path primitives that belong in tools.

## Layout

```text
lua/
  entry/
    shadow_army.lua
    persistent.lua
    accelerated.lua
    speedrun.lua
    traverse.lua
  tools/                 -- shared named-intent library
    registry.lua
    …
  tests/
    entry/
    tools/
```

Host selection (current: the **lua-bot** host in `monofuel-vanilla-wow`;
`army_host` and its `/env` transport were deleted in `1454caa`):

| Context | Mode selection |
|---|---|
| Local accelerated | `--bot=lua-bot --lua-entry=accelerated` (`make accelerated-pol`) |
| Local traverse (Petrel) | `--bot=lua-bot --lua-entry=traverse` (`make traverse-pol`) |
| League player image | Container maps to one entry per league |
| Tests | `lua/tests/test_*.lua` fake `_G.wow` and assert on intent tables |

The lua-bot host loads `lua/entry/<name>.lua` and calls `entry.decide(view)`
each frame. Intent kinds: `hold`, `navigate`, `cast_spell`, `attack`,
`release`, `reclaim`, `accept_rez`, `interact`, `ui_press`, `quest_cmd`
(`monofuel-vanilla-wow/bots/lua_bot/intent.nim`). The old `army_host`
`kind = "move"` dialect is gone.

## Mode goals

### shadow_army

**Goal:** Be useful to the human seat on the local private persistent realm
while the human plays on the vanilla client (`play-classic`).

Primary behaviors: party accept, escort/formation, assist combat, light quest
help, grind when idle.

Out of scope: tournament northing, RFC five-seat orchestration, 10× fresh-start
optimization.

### persistent

**Goal:** Advance the durable hosted account across sealed windows without
breaking resume.

Reuses: grind, quest, death recovery, travel; later profession/vendor as needed.

Does not assume a fresh L1 every episode or a human leader.

### accelerated

**Goal:** Same general leveling thesis under 10× simulation and a short wall
window.

Reuses the persistent tool set; the entry may bias aggression or risk under time
pressure. Scale is world-side — do not fork grind with hard-coded 10× constants.

### speedrun

**Goal:** One image, five seats, RFC assignment roles (tank/heal/DPS): form
party, reset, clear as far as possible.

Reuses combat primitives, death, follow; adds role-specific tools and RFC
startup sequencing. Not shadow_army's "follow human leader" main loop.

### traverse

**Goal:** Maximize northing on map 1 under fair play.

Reuses move/cast/death recovery, form upkeep, optional short combat to survive.
Does not ship an authored continent waypoint list as policy. Online heuristics
and read-only nav proposals are allowed.

Strategy variants (e.g. named submissions under the same mode) are args or
strategy modules under the traverse entry, not separate trees.

## Shared tools

Tools are pure, named intents: `decide(frame, args) → intent | nil`, registered
for discovery. If two modes need the same branch, it is a **tool**. If only one
mode's top-level objective needs it, it stays in the **entry**.

| Concern | Lives in | Used by |
|---|---|---|
| Frame helpers (distance, nearest) | `lua/tools/` or `lua/lib/` | all |
| Formation / escort | formation / escort tools | shadow_army |
| Solo grind | grind tools | shadow_army, persistent, accelerated |
| Quest interact | quest tools | shadow_army, persistent, accelerated |
| Death / corpse | shared death tool | all |
| Move to point / unit | move tools | traverse, escort, quest |
| Travel / aquatic form upkeep | form tools | traverse (required), others as needed |
| Role combat tables | class helpers | escort, speedrun, grind |
| RFC assignment read | speedrun tool or entry | speedrun |

## Host packaging

```text
army_host --mode=shadow_army     # local seats
(league image) MODE=traverse     # hosted submissions
(league image) MODE=persistent
…
```

Hosted tournament images are one Linux player binary plus this `lua/` tree. Mode
is selected by env or CMD — not by five copies of policy logic in five
Dockerfiles.

Projection and intent mapping stay in Nim. Adding a mode does not require new
wire kinds unless upstream adds a new `AgentAction`.

## Architectural invariants

- A human on the private realm can run **shadow_army** without tournament goals
  in the main loop.
- Each tournament submission maps to one **entry + goal** and does not run
  another mode's top-level objective by accident.
- New behavior is usually a **new tool** or a **small entry change**, not a
  copy of an existing tool per mode.
- Upstream `AgentFrame` churn costs **zero** Lua changes when the Nim
  projection holds.
- Policy decide paths are **Lua only** (no Python brain).
- Fair play holds: no authored continent route as traverse policy; no
  out-of-band seat collusion.
