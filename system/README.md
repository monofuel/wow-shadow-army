# The System

Management server for the wow-shadow-army: one Nim binary, two faces.

| Face | Path | Role |
|---|---|---|
| HTTP dashboard | `GET /` | htmx Roster page (auto-refresh) |
| Roster partial | `GET /roster` | htmx fragment (table rows) |
| MCP | `POST /mcp` | MCPort JSON-RPC (`list_shadows`) |
| Health | `GET /healthz` | process liveness |
| Info | `GET /server-info` | MCP metadata |

Design source: `coworld-playbook/games/solo-leveling.md` → **The System (management server)**.

## Run

From the repo root (`wow-shadow-army`):

```sh
make system
# or:
nim r system/system_server.nim
```

Listens on **http://127.0.0.1:7777** (chosen to avoid realmd 3724, healthz 8080, world 8085, MariaDB 3307).

Requires a running local realm (`make start-server`) so the game container can answer SQL.

Optional env:

| Env | Default | Meaning |
|---|---|---|
| `SYSTEM_MYSQL_CONTAINER` | `coworld-vmangos-coworld-game-1` | docker container that hosts MariaDB |

## Dashboard

Open http://127.0.0.1:7777/ — Roster lists every character on the local realm:

name · level · class · race · gold · online/offline

The table body polls `GET /roster` every few seconds via htmx.

## MCP

Same port, MCPort over HTTP. Example: list tools and call `list_shadows`.

```sh
# Initialize (many clients skip this; The System is always ready)
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# List tools
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Call list_shadows
curl -sS -X POST http://127.0.0.1:7777/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_shadows","arguments":{}}}'
```

## Read-only guarantee

- The System is an **observer** only. It runs `SELECT` against the `characters` DB.
- No INSERT/UPDATE/DELETE, no GM commands, no gameplay path through the DB.
- Credentials match the Makefile `account` target (`mangos`/`mangos` inside the game container).

## One dispatch path, two faces

```
listShadows()  ──►  htmx handlers  (render HTML)
               └──►  MCP list_shadows (JSON)
```

**Rule for future pages/tools:** add a single data/action proc first; wire the dashboard button and the MCP tool to that same proc. Never let the two faces diverge.

## Stack choices

| Piece | Choice |
|---|---|
| HTTP | mummy (shared router for dashboard + MCP) |
| MCP | MCPort (`McpServer.handleRequest` on `POST /mcp`) |
| UI | htmx (CDN) + server-rendered HTML |
| nimponents | on the path for future custom elements; Roster is SSR fragments for now |
| DB access | **`docker exec … mariadb`** — same reliable path as `make account`. No host mysql client; avoids a Nim MySQL driver. Documented intentional tradeoff. |

## Deps / nimby footgun

Paths come from this repo's `nim.cfg` + Softmax parent `nim.cfg` (mummy, jsony, …) and `~/.nimby/pkgs/MCPort`.

**Do not** run plain `nimby sync` from Softmax workspace mode — it mutates sibling checkouts. Deps are already present.

## Tests

`make test` stays Lua-only (no nim required).

Optional Nim unit tests for class/race enum maps:

```sh
make test-nim
```
