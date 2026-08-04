# play-classic — the genuine 1.12.1 client for the human seat

`make play-classic` launches the real Blizzard 1.12.1 client under wine
against the local realm. Motivation (2026-07-25): the coworld Nim client is
a young reimplementation under active upstream development — human play hit
UI/rendering/input bugs (see the QA list below), and the advisor addon plan
(docs/advisor.md) needs the 1.12 addon sandbox, which only the real client
has. Bots are unaffected: shadows keep consuming frames from headless Nim
clients either way.

## How it works

- **flake.nix devshell** provides `wineWowPackages.stable` (WoW.exe is
  32-bit; that package ships both arches). `make play-classic` =
  `nix develop --command tools/play_classic.sh`.
- **local_classic/** (gitignored) is assembled idempotently on first run:
  - `client/Data` → **symlink** into the wow-classic-data snapshot
    (~8GB of MPQs, immutable — the game only reads these).
  - `client/WTF/`, `client/Interface/`, `WoW.exe` + dlls → **copies**,
    because the game writes settings into WTF/ and addons live in
    Interface/AddOns/. The snapshot repo must never be written to
    (private immutable data — see docs/testing.md copyright rules).
  - `wineprefix/` — dedicated WINEPREFIX; nothing touches `~/.wine`.
- `realmlist.wtf` is rewritten to `set realmlist 127.0.0.1` on every
  launch (the snapshot's copy points at the old tailnet host).
- `WTF/Config.wtf` gets `SET gxApi "d3d"` by default (Direct3D via wine;
  launch without `-opengl`). Override with `WOW_GX_API=opengl make play-classic`
  for the old GL path. Windowed + 1024x768 from the snapshot until you
  change video options.
- Login at the door: `monofuel` / `password` (`make account` if missing).

## netlog — capture the wire while you play

`make play-classic-netlog` is `play-classic` plus a tcpdump on loopback:
realm (3724) and world (8085) traffic is written to
`captures/play-classic-<timestamp>.pcap` (gitignored) for offline protocol
analysis — the vanilla 5875 client is the ground truth for wire-format
correctness (docs/wow-version.md). Capture needs CAP_NET_RAW, so sudo
prompts once before launch; tcpdump flushes per-packet (`-U`) so the tail
of the capture survives a client crash.

A pcap alone is a time-bomb: world (8085) packet headers are encrypted with
the session key (bodies are plaintext in vanilla), the packet size field
lives in that encrypted header, and the server overwrites
`account.sessionkey` on every login — so an unkeyed capture becomes
undecodable the moment the account logs in again. The wrapper therefore
snapshots all accounts' session keys to `<capture>.sessionkey` next to the
pcap when the session ends (bots share these ports, so every key is kept).
Heed the WARNING if the snapshot fails — that capture's world traffic has a
shelf life of one login. How to actually decode a capture (framing, header
cipher, key byte-order gotcha): docs/netlog-pcap-analysis.md.

## Addons

Drop addons into `local_classic/client/Interface/AddOns/<Name>/` with a
`<Name>.toc`. 1.12 has no protected-function lockdown — `ReloadUI()` from
a slash command or chat event is legal, which is what the advisor's live
iteration loop (docs/advisor.md) builds on. New addon folders need a full
client restart once (TOC scan happens at launch); after that, code edits
only need `/console reloadui`.

## Known-unknowns (first human run answers these)

- Does the login screen render under wine+GL on this NixOS host? (wine has
  needed no extra GL env in testing elsewhere, but the nim client needed
  /run/opengl-driver/lib — if wine reports a GL error, that's the first
  suspect.)
- Sound under winepulse.
- Whether the snapshot's `winerosetta.dll` matters at all on x86_64
  (expected: no; it targets ARM hosts).

## Nim-client QA list (why the human seat moved)

Observed by monofuel on the Nim client, 2026-07-24/25, local realm — worth
reporting upstream once de-duplicated against their tracker:

1. Keyboard input dead on spawn-in (WASD + action bars; mouse fine),
   reproducible across client restarts — worst of the list.
2. No `!` quest markers over questgivers (possibly not yet implemented).
3. Tooltips/hover bubbles render off-screen.
4. Misplaced UI buttons in places.
5. Character mesh missing chunks (geoset handling, likely gear-dependent).
6. Audio absent (2026-07-24, before the libpulse env fix landed — needs a
   retest before reporting).
