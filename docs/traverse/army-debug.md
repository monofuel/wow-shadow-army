# Army host debug admin (HTTP + WebSocket)

Local live-debug surface for long traverse runs (`docs/traverse/traverse-2026-08-05.md` side quest).

## Enable

| | |
|---|---|
| Flag | `--debug-port:7788` |
| Env | `ARMY_DEBUG_PORT=7788` (local traverse defaults this on) |
| Token | optional `ARMY_DEBUG_TOKEN` / `--debug-token` (Bearer or `?token=`) |
| Bind | **127.0.0.1 only** |

Hosted Softmax policy images should leave the port **off** (`ARMY_DEBUG_PORT=0` / omit flag).

## Lua reload — honest semantics

`army_host` already runs **one fresh `lua5.3` process per decide frame** (`runDecide`). Editing `lua/**` on disk is live on the **next frame** without any admin call.

`POST /lua/reload` / WS `lua.reload` still matter as:

- validate entry with a dry-run `require`
- bump `lua_gen` so agents can prove a handshake
- surface parse errors without waiting for a live decide FAIL

## HTTP

| Method | Path |
|---|---|
| `GET` | `/healthz` |
| `GET` | `/status` |
| `GET` | `/log?n=50&src=policy` |
| `POST` | `/hold` / `/resume` |
| `POST` | `/lua/reload` |
| `POST` | `/dump` |

## WebSocket `ws://127.0.0.1:7788/ws`

Client ops: `auth`, `subscribe`/`unsubscribe` (`status`|`log`), `status`, `hold`, `resume`, `lua.reload`, `ping`.

## Agent loop

```bash
# while local traverse is running
make army-debug-status
# edit lua/entry/traverse.lua
make army-debug-reload
make army-debug-status   # lua.gen bumped
```

Hold during multi-file edits: `make army-debug-hold` … edit … `make army-debug-resume`.

## Headed Nim client (Softmax path)

```bash
make traverse-headed
```

One Softmax command: headed Nim client + **RealPlayerBot** on `--league=traverse`
(same as their participate guide). Window = the bot process.

Our **Lua / army_host** pilot is Softmax’s **external `/env`** lane (headless
reference/env host). Softmax does not put that lane in `player.nim` headed mode.
`make traverse-pol` + dashboard status is how we run *our* bot; headed Softmax
RPB is how their stack is meant to be watched in a window.
