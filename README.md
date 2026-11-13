# WoW Shadow Army

Bot policies, a player companion addon, and development tools for autonomous
play in classic World of Warcraft (1.12). Built during Softmax's WoW Coworld
experiments, the project explores solo leveling, navigation, and a party of
bots playing alongside a human.

Gameplay policies are written in **Lua**. **Nim** powers the dashboard,
experiment orchestration, and map viewer, as well as the separate game client
that hosts the bots.

**Current status: source available for review; runtime restoration pending.**
The `master` branch and its history have been cleaned of extracted game
assets, generated game datasets, and captured fixtures. Some code still
expects those local inputs, and the build and launch paths need restoration.
This checkout is not currently a verified, ready-to-run distribution.

## What the project explores

- **Party assistance:** bots follow a human player, assist in combat, perform
  class roles such as tanking and healing, and recover after death. The home
  policy falls back to solo leveling when the human is absent.
- **Solo leveling:** policies select combat targets, manage resources, loot,
  and optionally interact with quests.
- **World traversal:** a navigation policy handles running, swimming,
  shapeshifting, and recovery while crossing a continent.
- **Observation and iteration:** a player addon, dashboard, and map viewer
  help inspect behavior; experiment tooling evaluates proposed code changes.

## Start reading here

| Component | Source | What to look for |
|---|---|---|
| Party policy | [home.lua](lua/entry/home.lua) | Following, combat roles, party support, and solo fallback |
| Leveling policy | [accelerated.lua](lua/entry/accelerated.lua) | Target selection, resource management, and optional quest behavior |
| Traversal policy | [traverse.lua](lua/entry/traverse.lua) | Navigation decisions, movement forms, and failure handling |
| Shared Lua tools | [lua/tools/](lua/tools/) | Movement, quest interaction, item decisions, and road routing |
| Shadow Advisor addon | [ShadowArmy.lua](addons/ShadowArmy/ShadowArmy.lua) | In-game player UI, inventory and quest helpers, and telemetry |
| Dashboard and MCP server | [system_server.nim](system/system_server.nim) | Character status, inventory, addon events, and local administration |
| Experiment conductor | [src/conductor/](src/conductor/) | Coding/review agents, evaluation gates, experiment records, and deployment controls |
| Map browser | [map_browser.nim](src/tools/map_browser.nim) | Terrain and navigation overlays for debugging routes |

Tests live alongside these components in [lua/tests/](lua/tests/),
[system/tests/](system/tests/), and [tools/tests/](tools/tests/).
Local data generators and operator utilities are in [tools/](tools/).

## How the bots fit into the game

The bots run inside a separate Nim client fork, `monofuel-vanilla-wow`,
connected to a local VMaNGOS game server. Each bot character
has its own client process and embedded Lua 5.3 VM.

The client exposes an observation of the game world to the Lua policy. The
policy chooses an intent, such as following a party member or casting a spell;
the client validates and executes it. Game protocol handling, perception,
and movement mechanics belong to the client. This repository holds the
policies and supporting tools.

The Shadow Advisor is a separate addon for the human player's client. The
dashboard collects status and addon events and exposes local management
operations through a web UI and the Model Context Protocol (MCP).

### Where AI is used

The gameplay policies in this checkout are scripted Lua decision logic.
The conductor uses external coding and review agents to propose and evaluate
changes to those policies, with software checks controlling acceptance.

A gameplay LLM planner and durable bot knowledgebase were planned, but are
not implemented here. The [kb/](kb/) directory documents that intended layer.

## Dependencies and project status

The original development setup used Linux/NixOS, Nix development shells,
Nim, Lua, Docker, a separate client/server checkout, and locally supplied
game data. Parts of the tooling also depend on the surrounding development
workspace. Standalone setup is part of the planned runtime restoration.

The [interface overview](docs/interfaces.md) explains the client/policy
boundary. More detail is available for the [addon](docs/advisor.md),
[dashboard](system/README.md), [conductor](docs/conductor.md), and
[map browser](docs/tools/map-browser.md). Some documents preserve earlier
designs and commands; treat them as engineering references while restoration
is pending.

## Game data and licensing

Game client binaries, artwork, audio, extracted databases, and generated game
datasets are excluded from the shared source. Data generators remain in the
repository; their inputs must be supplied locally and their outputs kept out
of Git. See the [repository policy](AGENTS.md#copyright-hygiene-and-licensing)
and [content cleanup record](docs/copyright-cleanup.md).

No project source license has been selected yet. Third-party game content
is not covered by any future source-code license for this project.
