# WoW Client Version

Facts confirmed with the team (2026-08-03). This doc pins down which client
version we target so other docs and code can refer to it consistently.

## Target version: 5875

- We specifically target **WoW 1.12, build 5875** — referred to as just
  **"5875"**.
- There is evidence in the code for this, and it has been confirmed with the
  team.
- Vanilla client **addon / slash-command** surface for this pin:
  [docs/vanilla-addons/](vanilla-addons/) (Lua 5.0, stock `SLASH_*`,
  anti-hallucination notes — e.g. `/cancelform` does not exist).

## Server

- The server codebase appears to be a **patched version of MaNGOS**.
- Upstream MaNGOS supported a **range** of client versions, not just one.
- Softmax appears to be applying **additional patches on top, specific to
  5875**.

## The 3368 red herring

- The `coworld-vanilla-wow` repo has references to some sort of **packet dump
  or documentation relating to client 3368**.
- 3368 was supported by MaNGOS, but it is **not** the client we target. Do not
  treat 3368 material as authoritative for 5875 behavior.

## Known network issues

- There appear to be **misunderstood / mishandled packets on the server
  side**, possibly related to the Softmax patches, that cause the **vanilla
  client (5875) to crash**.
- The **Nim client does not crash** — but likely only because it was **built
  against the malformed API**, so it tolerates (or expects) the wrong wire
  format rather than validating it.
- Some parts of the networking appear to have been **vibe-coded against
  3368**. They work with the Nim client but **crash the vanilla client**.
- Consequence: "works with the Nim client" is **not** evidence of correct
  5875 protocol behavior. The vanilla 5875 client is the ground truth for
  wire-format correctness.

## Clients we run

- **Vanilla WoW client (5875)** — the real game client, headed.
- **Nim client** — used for both:
  - players, in a headed mode
  - bots, in a headed or headless mode
