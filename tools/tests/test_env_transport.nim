## Pure unit tests for env_transport (no network, no sockets).
## Run: nim r --hints:off --warnings:off tools/tests/test_env_transport.nim

import std/[strutils]
import ../env_transport

var passed = 0
proc check(cond: bool; name: string) =
  if not cond:
    echo "FAIL: ", name
    quit 1
  inc passed

# --- control header roundtrip ---
block:
  let payload = """{"type":"hello","session_id":"abc","slot":0,"action_deadline_seconds":5}"""
  let encoded = encodeControlFrame(FrameEnvHello, 0'u32, payload)
  check(encoded.len == ControlHeaderSize + payload.len, "encode size")
  let (kind, rid, plen) = decodeControlHeader(encoded[0 ..< ControlHeaderSize])
  check(kind == FrameEnvHello, "header kind hello")
  check(rid == 0'u32, "header request id 0")
  check(plen == payload.len, "header payload len")
  let frame = decodeControlFrame(encoded)
  check(frame.kind == FrameEnvHello, "frame kind")
  check(frame.requestId == 0'u32, "frame request id")
  check(frame.payload == payload, "frame payload roundtrip")

block:
  let empty = encodeControlFrame(FrameActionSubmission, 42'u32, "")
  check(empty.len == ControlHeaderSize, "empty payload size")
  let frame = decodeControlFrame(empty)
  check(frame.kind == FrameActionSubmission, "action kind 9")
  check(frame.requestId == 42'u32, "action request id")
  check(frame.payload.len == 0, "empty payload")

block:
  # Bad magic
  var bad = encodeControlFrame(FrameAgentFrame, 1'u32, "x")
  bad[0] = char(0)
  var raised = false
  try:
    discard decodeControlFrame(bad)
  except ValueError:
    raised = true
  check(raised, "bad magic raises")

block:
  # Length mismatch
  let full = encodeControlFrame(FrameAgentFrame, 1'u32, "abcd")
  var raised = false
  try:
    discard decodeControlFrame(full[0 ..< full.len - 1])
  except ValueError:
    raised = true
  check(raised, "truncated payload raises")

# --- RFC 6455 accept-key example ---
block:
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let accept = wsAcceptKey(key)
  check(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept key")

# --- mask apply ---
block:
  let mask: array[4, byte] = [0x37'u8, 0xfa, 0x21, 0x3d]
  let plain = "Hello"
  let masked = applyMask(plain, mask)
  check(masked.len == plain.len, "mask len")
  let unmasked = applyMask(masked, mask)
  check(unmasked == plain, "mask roundtrip")

# --- WS frame encode/decode (masked client frame) ---
block:
  let mask: array[4, byte] = [0x01'u8, 0x02, 0x03, 0x04]
  let payload = "binary-payload"
  let wire = encodeWsFrame(WsOpBinary, payload, mask, masked = true, fin = true)
  check((byte(wire[0]) and 0x80'u8) != 0, "fin bit set")
  check((byte(wire[0]) and 0x0f'u8) == WsOpBinary, "binary opcode")
  check((byte(wire[1]) and 0x80'u8) != 0, "mask bit set")
  let (frame, next) = decodeWsFrame(wire)
  check(next == wire.len, "consumed full frame")
  check(frame.fin, "decoded fin")
  check(frame.opcode == WsOpBinary, "decoded opcode")
  check(frame.masked, "decoded masked")
  check(frame.payload == payload, "decoded payload")

# --- unmasked server frame ---
block:
  let payload = "server-says-hi"
  let wire = encodeWsFrame(WsOpText, payload, masked = false, fin = true)
  check((byte(wire[1]) and 0x80'u8) == 0, "server unmasked")
  let (frame, next) = decodeWsFrame(wire)
  check(next == wire.len, "server frame full")
  check(frame.payload == payload, "server payload")
  check(not frame.masked, "server not masked")

# --- extended length 126 ---
block:
  var big = newString(200)
  for i in 0 ..< big.len:
    big[i] = char(ord('a') + (i mod 26))
  let mask: array[4, byte] = [0xaa'u8, 0xbb, 0xcc, 0xdd]
  let wire = encodeWsFrame(WsOpBinary, big, mask, masked = true)
  check((byte(wire[1]) and 0x7f'u8) == 126, "uses 16-bit length")
  let (frame, next) = decodeWsFrame(wire)
  check(next == wire.len, "ext126 full")
  check(frame.payload == big, "ext126 payload")

# --- fragmented message reassembly (two frames on one buffer) ---
block:
  let mask1: array[4, byte] = [0x10'u8, 0x20, 0x30, 0x40]
  let mask2: array[4, byte] = [0x50'u8, 0x60, 0x70, 0x80]
  let part1 = encodeWsFrame(WsOpBinary, "hello ", mask1, masked = true, fin = false)
  let part2 = encodeWsFrame(WsOpContinuation, "world", mask2, masked = true, fin = true)
  let wire = part1 & part2
  let (f1, n1) = decodeWsFrame(wire, 0)
  check(not f1.fin, "first fragment not fin")
  check(f1.opcode == WsOpBinary, "first opcode binary")
  check(f1.payload == "hello ", "first payload")
  let (f2, n2) = decodeWsFrame(wire, n1)
  check(f2.fin, "second fragment fin")
  check(f2.opcode == WsOpContinuation, "continuation opcode")
  check(f2.payload == "world", "second payload")
  check(n2 == wire.len, "fragment stream consumed")
  check(f1.payload & f2.payload == "hello world", "reassembled message")

# --- close payload ---
block:
  let payload = encodeClosePayload(1008'u16, "bad token")
  let info = parseClosePayload(payload)
  check(info.code == 1008'u16, "close code 1008")
  check(info.reason == "bad token", "close reason")
  let empty = parseClosePayload("")
  check(empty.code == 1005'u16, "empty close is 1005")

# --- kind constants match upstream ---
block:
  check(FrameControlError == 8'u16, "kind 8 control_error")
  check(FrameActionSubmission == 9'u16, "kind 9 action_submission")
  check(FrameAgentFrame == 10'u16, "kind 10 agent_frame")
  check(FrameEnvHello == 12'u16, "kind 12 hello")
  check(FrameEnvClose == 13'u16, "kind 13 close")
  check(ControlFrameMagic == 0x44524E4B'u32, "magic DRNK")
  check(ControlFrameVersion == 2'u16, "version 2")

echo "test_env_transport: ", passed, " checks passed"
