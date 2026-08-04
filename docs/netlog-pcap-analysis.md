# Working with netlog pcaps (5875 wire format)

How to decode the captures produced by `make play-classic-netlog`
(docs/play-classic.md). Written so an AI agent (or human) can go from a
`.pcap` + `.sessionkey` pair to fully parsed packets without re-deriving
the protocol. Every fact below was verified against the server reference
source at
`../coworld-vanilla-wow/local_data/reference/vmangos-core/src/` —
that tree is the ground truth if anything here seems off. We target client
build **5875** (docs/wow-version.md); beware 3368-era material elsewhere in
the upstream repo.

## The artifact pair

Each capture session in `captures/` (gitignored) is TWO files that only
work together:

- `play-classic-<ts>.pcap` — loopback capture, tcp ports 3724 + 8085.
- `play-classic-<ts>.sessionkey` — TSV of `USERNAME\t<80 hex chars>`, one
  row per account, snapshotted from the auth DB when the session ended.

**Session key gotcha #1 (the big one):** the server overwrites
`realmd.account.sessionkey` on every login. The `.sessionkey` snapshot is
the only durable copy of the keys for its pcap. A pcap without its
`.sessionkey` file becomes permanently undecodable for world traffic the
moment those accounts log in again — the packet size field is inside the
encrypted header, so the stream cannot even be re-framed. Treat the pair
as one artifact; never separate or delete one half.

**Session key gotcha #2 (byte order):** the DB hex string is the SRP `K`
as a big-endian big-number (`BigNumber::AsHexStr`), but the cipher is keyed
with `K.AsByteArray()` which is **byte-reversed** (`BigNumber.cpp`
`AsByteArray(minSize=0, reverse=true)`; key set at `WorldSocket.cpp:430`).
So: hex-decode the 80 chars to 40 bytes, then **reverse the byte array**
before using it as the cipher key.

## Port 3724 — realm/auth (plaintext)

SRP6 login handshake + realm list. No encryption at any point; analyzable
directly. The session key K is derived here (never transmitted), which is
why it must come from the DB snapshot.

## Port 8085 — world

TCP stream in both directions. Reassemble the stream first (loopback, so
no loss/reorder in practice, but split/merged segments are common — packet
boundaries do NOT align with TCP segment boundaries).

### Framing (`WorldSocket.h` struct ClientPktHeader / ServerPktHeader)

| Direction | Header | Fields |
|---|---|---|
| client → server | 6 bytes | `size` uint16 **big-endian**, `opcode` uint32 little-endian |
| server → client | 4 bytes | `size` uint16 **big-endian**, `opcode` uint16 little-endian |

`size` counts the opcode field plus the body — i.e. everything after the
size field itself (client: body + 4; server: body + 2, see
`WorldSocket.cpp:602`). Bodies follow the header, little-endian throughout.

### Encryption boundary

The connection starts in plaintext:

1. `SMSG_AUTH_CHALLENGE` (0x1EC) — server's first packet, plaintext.
2. `CMSG_AUTH_SESSION` (0x1ED) — plaintext; contains build number and the
   **account name in cleartext**. This is how you map a TCP connection to
   its row in the `.sessionkey` file.
3. Everything after: packet **headers** encrypted, bodies still plaintext
   (vanilla encrypts only the header — `WorldSocket.cpp:605`).

### Header cipher (`shared/Auth/AuthCrypt.cpp`)

A 40-byte-keyed rolling byte cipher. Decryption is identical for both
directions (it's the inverse of the encrypt step), but each direction has
its **own independent state**:

```
# key = reversed 40 bytes (see gotcha #2); i = 0, j = 0 per direction
for each encrypted header byte c (in stream order):
    p = (c - j) & 0xFF ^ key[i % 40]     # plaintext byte
    j = c                                 # j tracks the CIPHERTEXT byte
    i += 1
```

Only header bytes advance the cipher (4 per server packet, 6 per client
packet); body bytes do not touch `i`/`j`.

**Streaming-state gotcha:** `i` and `j` persist across packets for the
lifetime of the connection. You cannot decrypt a header in isolation — you
must walk each direction's stream in order from the first encrypted
header. Framing and decryption are one interleaved pass: decrypt header →
read `size` → skip body → decrypt next header.

### Opcode names

The 5875 opcode enum is
`.../src/game/Server/Protocol/Opcodes_1_12_1.h` (enum values are the wire
values). The sibling `Opcodes_1_*.h` files are for OTHER client builds the
server supports — do not decode against them.

## Decode recipe

1. Load the `.sessionkey` TSV; hex-decode and byte-reverse each key.
2. Reassemble each 8085 TCP connection into two ordered byte streams
   (one per direction), keyed by the TCP 4-tuple — a capture can hold
   several concurrent sessions (human + bots share these ports).
3. Per connection: parse the plaintext prologue (SMSG_AUTH_CHALLENGE,
   CMSG_AUTH_SESSION), take the account name from CMSG_AUTH_SESSION,
   select that account's key.
4. From the packet after CMSG_AUTH_SESSION (server side: after
   SMSG_AUTH_CHALLENGE, i.e. from `SMSG_AUTH_RESPONSE` on), run the
   interleaved decrypt/frame pass per direction.
5. Name opcodes via `Opcodes_1_12_1.h`; bodies are plaintext little-endian
   structs.

## Why this exists

The vanilla 5875 client is the ground truth for wire-format correctness —
the Nim client tolerates malformed packets it was built against
(docs/wow-version.md "Known network issues"). Decoded captures are the
evidence base for proving packet structures and for crash forensics
(last decoded server packets before a client crash).
