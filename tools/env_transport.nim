## Synchronous WebSocket client + control-wire codec for WS /env.
##
## STDLIB ONLY. Pure codec/frame helpers are buffer-based so unit tests need
## no sockets. Live I/O lives on EnvClient (connect / send / recv / close).

import
  std/[
    base64, endians, net, random, sha1, strutils, uri
  ]

const
  ControlFrameMagic* = 0x44524E4B'u32
  ControlFrameVersion* = 2'u16
  MaxControlPayloadBytes* = 1024 * 1024
  ControlHeaderSize* = 16

  FrameControlError* = 8'u16
  FrameActionSubmission* = 9'u16
  FrameAgentFrame* = 10'u16
  FrameEnvAttach* = 11'u16  # direct-TCP mode only; the WS relay sends it for us
  FrameEnvHello* = 12'u16
  FrameEnvClose* = 13'u16

  WsOpContinuation* = 0x0'u8
  WsOpText* = 0x1'u8
  WsOpBinary* = 0x2'u8
  WsOpClose* = 0x8'u8
  WsOpPing* = 0x9'u8
  WsOpPong* = 0xA'u8

  WsAcceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  DefaultRecvChunk = 4096

type
  ControlFrame* = object
    kind*: uint16
    requestId*: uint32
    payload*: string

  WsCloseInfo* = object
    code*: uint16
    reason*: string

  EnvTransportError* = object of CatchableError
    closeCode*: int
    closeReason*: string

  WsFrame* = object
    opcode*: uint8
    fin*: bool
    masked*: bool
    payload*: string

  EnvClient* = ref object
    sock: Socket
    host: string
    port: Port
    closed: bool
    closeInfo: WsCloseInfo
    hasClose: bool
    recvBuf: string  # bytes read past the HTTP upgrade (server pushes hello eagerly)
    rawTcp: bool     # direct env-host connection: control frames without WS framing

# ---------------------------------------------------------------------------
# Control-wire codec (pure)
# ---------------------------------------------------------------------------

proc encodeControlFrame*(
  kind: uint16;
  requestId: uint32;
  payload: string = ""
): string =
  ## Encode one 16-byte little-endian control header plus payload.
  if payload.len > MaxControlPayloadBytes:
    raise newException(ValueError, "control payload is too large")
  result = newString(ControlHeaderSize + payload.len)
  var magic = ControlFrameMagic
  var ver = ControlFrameVersion
  var k = kind
  var rid = requestId
  var plen = uint32(payload.len)
  littleEndian32(addr result[0], addr magic)
  littleEndian16(addr result[4], addr ver)
  littleEndian16(addr result[6], addr k)
  littleEndian32(addr result[8], addr rid)
  littleEndian32(addr result[12], addr plen)
  if payload.len > 0:
    copyMem(addr result[ControlHeaderSize], addr payload[0], payload.len)

proc decodeControlHeader*(
  header: openArray[char]
): tuple[kind: uint16, requestId: uint32, payloadLen: int] =
  ## Decode the 16-byte control header. Raises on bad magic/version/size.
  if header.len < ControlHeaderSize:
    raise newException(ValueError, "control header too short")
  var magic, rid, plen: uint32
  var ver, kind: uint16
  littleEndian32(addr magic, unsafeAddr header[0])
  littleEndian16(addr ver, unsafeAddr header[4])
  littleEndian16(addr kind, unsafeAddr header[6])
  littleEndian32(addr rid, unsafeAddr header[8])
  littleEndian32(addr plen, unsafeAddr header[12])
  if magic != ControlFrameMagic:
    raise newException(ValueError, "invalid control frame magic")
  if ver != ControlFrameVersion:
    raise newException(ValueError, "unsupported control frame version " & $ver)
  if plen > uint32(MaxControlPayloadBytes):
    raise newException(ValueError, "control payload is too large")
  result = (kind, rid, int(plen))

proc decodeControlFrame*(data: openArray[char]): ControlFrame =
  ## Decode one complete control frame (header + payload) from a buffer.
  let (kind, rid, plen) = decodeControlHeader(data)
  if data.len != ControlHeaderSize + plen:
    raise newException(
      ValueError,
      "one complete control frame is required (got " & $data.len &
        ", expected " & $(ControlHeaderSize + plen) & ")"
    )
  result.kind = kind
  result.requestId = rid
  if plen > 0:
    result.payload = newString(plen)
    copyMem(addr result.payload[0], unsafeAddr data[ControlHeaderSize], plen)
  else:
    result.payload = ""

# ---------------------------------------------------------------------------
# WebSocket frame codec (pure)
# ---------------------------------------------------------------------------

proc wsAcceptKey*(secWebSocketKey: string): string =
  ## Compute Sec-WebSocket-Accept for a client Sec-WebSocket-Key (RFC 6455).
  let digest = secureHash(secWebSocketKey & WsAcceptGuid)
  var raw = newString(20)
  let bytes = Sha1Digest(digest)
  for i in 0..19:
    raw[i] = char(bytes[i])
  result = encode(raw)

proc applyMask*(data: openArray[char]; mask: array[4, byte]): string =
  ## XOR-mask a payload with a 4-byte WebSocket mask key.
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(byte(data[i]) xor mask[i mod 4])

proc randomMaskKey*(): array[4, byte] =
  ## Four random mask bytes for a client-to-server frame.
  for i in 0..3:
    result[i] = byte(rand(255))

proc randomSecWebSocketKey*(): string =
  ## 16 random bytes, base64-encoded (RFC 6455 client key).
  var raw = newString(16)
  for i in 0..15:
    raw[i] = char(rand(255))
  result = encode(raw)

proc encodeWsFrame*(
  opcode: uint8;
  payload: openArray[char];
  maskKey: array[4, byte] = [0'u8, 0, 0, 0];
  masked = true;
  fin = true
): string =
  ## Encode one WebSocket frame. Client frames must set masked=true.
  let plen = payload.len
  var headerLen = 2
  if plen >= 65536:
    headerLen += 8
  elif plen >= 126:
    headerLen += 2
  if masked:
    headerLen += 4
  result = newString(headerLen + plen)
  result[0] = char((if fin: 0x80 else: 0) or (opcode and 0x0f))
  if plen < 126:
    result[1] = char((if masked: 0x80 else: 0) or plen)
  elif plen < 65536:
    result[1] = char((if masked: 0x80 else: 0) or 126)
    var be = uint16(plen)
    bigEndian16(addr result[2], addr be)
  else:
    result[1] = char((if masked: 0x80 else: 0) or 127)
    var be = uint64(plen)
    bigEndian64(addr result[2], addr be)
  var payloadOff = headerLen - (if masked: 4 else: 0)
  if masked:
    let maskOff = payloadOff
    for i in 0..3:
      result[maskOff + i] = char(maskKey[i])
    payloadOff = headerLen
    for i in 0 ..< plen:
      result[payloadOff + i] = char(byte(payload[i]) xor maskKey[i mod 4])
  else:
    if plen > 0:
      copyMem(addr result[payloadOff], unsafeAddr payload[0], plen)

proc decodeWsFrame*(
  data: openArray[char];
  start = 0
): tuple[frame: WsFrame, next: int] =
  ## Decode one WebSocket frame starting at `start`. Raises if truncated.
  if start + 2 > data.len:
    raise newException(ValueError, "truncated websocket frame header")
  let b0 = byte(data[start])
  let b1 = byte(data[start + 1])
  let fin = (b0 and 0x80'u8) != 0
  let opcode = b0 and 0x0f'u8
  let masked = (b1 and 0x80'u8) != 0
  var plen = int(b1 and 0x7f'u8)
  var off = start + 2
  if plen == 126:
    if off + 2 > data.len:
      raise newException(ValueError, "truncated websocket extended length")
    var be: uint16
    bigEndian16(addr be, unsafeAddr data[off])
    plen = int(be)
    off += 2
  elif plen == 127:
    if off + 8 > data.len:
      raise newException(ValueError, "truncated websocket extended length")
    var be: uint64
    bigEndian64(addr be, unsafeAddr data[off])
    if be > uint64(high(int)):
      raise newException(ValueError, "websocket payload too large")
    plen = int(be)
    off += 8
  var mask: array[4, byte]
  if masked:
    if off + 4 > data.len:
      raise newException(ValueError, "truncated websocket mask")
    for i in 0..3:
      mask[i] = byte(data[off + i])
    off += 4
  if off + plen > data.len:
    raise newException(ValueError, "truncated websocket payload")
  var payload = newString(plen)
  if plen > 0:
    if masked:
      for i in 0 ..< plen:
        payload[i] = char(byte(data[off + i]) xor mask[i mod 4])
    else:
      copyMem(addr payload[0], unsafeAddr data[off], plen)
  result.frame = WsFrame(opcode: opcode, fin: fin, masked: masked, payload: payload)
  result.next = off + plen

proc parseClosePayload*(payload: openArray[char]): WsCloseInfo =
  ## Parse a close frame payload into code + UTF-8 reason.
  if payload.len == 0:
    result = WsCloseInfo(code: 1005, reason: "")
  elif payload.len == 1:
    raise newException(ValueError, "invalid close payload length 1")
  else:
    var code: uint16
    bigEndian16(addr code, unsafeAddr payload[0])
    result.code = code
    if payload.len > 2:
      result.reason = newString(payload.len - 2)
      copyMem(addr result.reason[0], unsafeAddr payload[2], payload.len - 2)
    else:
      result.reason = ""

proc encodeClosePayload*(code: uint16; reason = ""): string =
  ## Encode a close frame payload (2-byte BE code + optional reason).
  result = newString(2 + reason.len)
  var c = code
  bigEndian16(addr result[0], addr c)
  if reason.len > 0:
    copyMem(addr result[2], addr reason[0], reason.len)

# ---------------------------------------------------------------------------
# Socket helpers
# ---------------------------------------------------------------------------

proc raiseTransport(
  msg: string;
  closeCode = 0;
  closeReason = ""
) {.noreturn.} =
  var err = new EnvTransportError
  err.msg = msg
  err.closeCode = closeCode
  err.closeReason = closeReason
  raise err

proc recvExact(s: Socket; n: int): string =
  ## Read exactly n bytes or raise on close.
  if n == 0:
    return ""
  result = newString(n)
  var got = 0
  while got < n:
    let k = s.recv(addr result[got], n - got)
    if k <= 0:
      raise newException(IOError, "socket closed")
    got += k

proc sendAll(s: Socket; data: string) =
  ## Send the full buffer.
  var sent = 0
  while sent < data.len:
    let n = s.send(data[sent].addr, data.len - sent)
    if n <= 0:
      raise newException(IOError, "send failed")
    sent += n

proc readHttpResponse(s: Socket): tuple[status: int; headers: string; body: string] =
  ## Read an HTTP/1.1 response until the header terminator.
  var buf = ""
  var chunk = newString(DefaultRecvChunk)
  while true:
    let n = s.recv(addr chunk[0], chunk.len)
    if n <= 0:
      raise newException(IOError, "socket closed during HTTP upgrade")
    buf.add chunk[0 ..< n]
    let sep = buf.find("\r\n\r\n")
    if sep >= 0:
      let headerBlock = buf[0 ..< sep]
      let rest = buf[sep + 4 .. ^1]
      let lines = headerBlock.split("\r\n")
      if lines.len == 0:
        raise newException(IOError, "empty HTTP response")
      let parts = lines[0].splitWhitespace()
      if parts.len < 2:
        raise newException(IOError, "bad HTTP status line: " & lines[0])
      var status = 0
      try:
        status = parseInt(parts[1])
      except ValueError:
        raise newException(IOError, "bad HTTP status: " & lines[0])
      return (status, headerBlock, rest)

proc headerValue(headers: string; name: string): string =
  ## Case-insensitive header lookup; returns "" if missing.
  let want = name.toLowerAscii()
  for line in headers.split("\r\n"):
    let colon = line.find(':')
    if colon <= 0:
      continue
    if line[0 ..< colon].strip().toLowerAscii() == want:
      return line[colon + 1 .. ^1].strip()
  result = ""

# ---------------------------------------------------------------------------
# EnvClient (live WebSocket)
# ---------------------------------------------------------------------------

proc close*(c: EnvClient; code: uint16 = 1000; reason = "") =
  ## Send a close frame if still open, then shut the TCP socket.
  if c.isNil or c.closed:
    return
  c.closed = true
  if c.sock != nil:
    if not c.rawTcp:
      try:
        let payload = encodeClosePayload(code, reason)
        let frame = encodeWsFrame(WsOpClose, payload, randomMaskKey(), masked = true)
        c.sock.sendAll(frame)
      except CatchableError:
        discard
    try:
      c.sock.close()
    except CatchableError:
      discard
    c.sock = nil

proc sendWsFrame(c: EnvClient; opcode: uint8; payload: string; fin = true) =
  if c.isNil or c.closed or c.sock.isNil:
    raise newException(IOError, "env client closed")
  let frame = encodeWsFrame(opcode, payload, randomMaskKey(), masked = true, fin = fin)
  c.sock.sendAll(frame)

proc recvExact(c: EnvClient; n: int): string =
  ## Read exactly n bytes, draining the post-upgrade push-back buffer first.
  if n == 0:
    return ""
  if c.recvBuf.len > 0:
    if c.recvBuf.len >= n:
      result = c.recvBuf[0 ..< n]
      c.recvBuf = c.recvBuf[n .. ^1]
      return
    result = c.recvBuf
    c.recvBuf = ""
    result.add c.sock.recvExact(n - result.len)
    return
  result = c.sock.recvExact(n)

proc recvWsRawFrame(c: EnvClient): WsFrame =
  ## Read one WebSocket frame from the socket (handles server unmasked).
  if c.isNil or c.closed or c.sock.isNil:
    raise newException(IOError, "env client closed")
  let hdr = c.recvExact(2)
  let b0 = byte(hdr[0])
  let b1 = byte(hdr[1])
  let fin = (b0 and 0x80'u8) != 0
  let opcode = b0 and 0x0f'u8
  let masked = (b1 and 0x80'u8) != 0
  var plen = int(b1 and 0x7f'u8)
  if plen == 126:
    let ext = c.recvExact(2)
    var be: uint16
    bigEndian16(addr be, addr ext[0])
    plen = int(be)
  elif plen == 127:
    let ext = c.recvExact(8)
    var be: uint64
    bigEndian64(addr be, addr ext[0])
    if be > uint64(MaxControlPayloadBytes + ControlHeaderSize + 1024):
      raise newException(ValueError, "websocket payload too large")
    plen = int(be)
  var mask: array[4, byte]
  if masked:
    let m = c.recvExact(4)
    for i in 0..3:
      mask[i] = byte(m[i])
  var payload = c.recvExact(plen)
  if masked and plen > 0:
    payload = applyMask(payload, mask)
  result = WsFrame(opcode: opcode, fin: fin, masked: masked, payload: payload)

proc handleControlFrame(c: EnvClient; frame: WsFrame): bool =
  ## Handle ping/pong/close. Returns true if the frame was a control frame.
  case frame.opcode
  of WsOpPing:
    c.sendWsFrame(WsOpPong, frame.payload)
    return true
  of WsOpPong:
    return true
  of WsOpClose:
    let info = parseClosePayload(frame.payload)
    c.hasClose = true
    c.closeInfo = info
    # Reply close if still open, then mark closed.
    if not c.closed and c.sock != nil:
      try:
        let reply = encodeClosePayload(info.code, "")
        c.sock.sendAll(
          encodeWsFrame(WsOpClose, reply, randomMaskKey(), masked = true)
        )
      except CatchableError:
        discard
      try:
        c.sock.close()
      except CatchableError:
        discard
      c.sock = nil
      c.closed = true
    raiseTransport(
      "websocket closed: " & $info.code &
        (if info.reason.len > 0: " " & info.reason else: ""),
      closeCode = int(info.code),
      closeReason = info.reason
    )
  else:
    return false

proc recvWsMessage*(c: EnvClient): tuple[opcode: uint8, payload: string] =
  ## Receive one complete (reassembled) data message; answers ping/close.
  var started = false
  var opcode: uint8 = 0
  var acc = ""
  while true:
    let frame = c.recvWsRawFrame()
    if frame.opcode in {WsOpClose, WsOpPing, WsOpPong}:
      discard c.handleControlFrame(frame)
      continue
    if frame.opcode == WsOpContinuation:
      if not started:
        raise newException(ValueError, "unexpected continuation frame")
      acc.add frame.payload
      if frame.fin:
        return (opcode, acc)
    elif frame.opcode in {WsOpText, WsOpBinary}:
      if started:
        raise newException(ValueError, "new data frame before prior finished")
      if frame.fin:
        return (frame.opcode, frame.payload)
      started = true
      opcode = frame.opcode
      acc = frame.payload
    else:
      raise newException(ValueError, "unsupported websocket opcode " & $frame.opcode)

proc connectEnv*(
  host: string;
  port: int;
  slot: int;
  token: string;
  path = "/env";
  useSsl = false
): EnvClient =
  ## TCP (or TLS) connect + RFC 6455 client handshake to `ws[s]://host:port/path`.
  ## Hosted Softmax injects `COWORLD_PLAYER_WS_URL`; rewrite `/player` → `/env`.
  randomize()
  result = EnvClient(host: host, port: Port(port), closed: false)
  result.sock = newSocket(buffered = false)
  when defined(ssl):
    if useSsl:
      let ctx = newContext(verifyMode = CVerifyPeer)
      ctx.wrapSocket(result.sock)
  else:
    if useSsl:
      raiseTransport("wss requested but binary was not built with -d:ssl")
  result.sock.connect(host, Port(port))
  let key = randomSecWebSocketKey()
  let q = "slot=" & encodeUrl($slot) & "&token=" & encodeUrl(token)
  let resource = path & "?" & q
  let req =
    "GET " & resource & " HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & key & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n" &
    "\r\n"
  result.sock.sendAll(req)
  let (status, headers, leftover) = result.sock.readHttpResponse()
  if status != 101:
    result.close()
    raiseTransport(
      "websocket upgrade failed: HTTP " & $status &
        (if leftover.len > 0: " body=" & leftover[0 ..< min(200, leftover.len)] else: "")
    )
  let accept = headerValue(headers, "Sec-WebSocket-Accept")
  let expect = wsAcceptKey(key)
  if accept != expect:
    result.close()
    raiseTransport(
      "bad Sec-WebSocket-Accept: got " & accept & " expected " & expect
    )
  # The relay pushes hello immediately after the 101, so the first WS frame
  # can coalesce into the upgrade read — keep it for the frame reader.
  result.recvBuf = leftover

proc connectEnvDirect*(host: string; port: int): EnvClient =
  ## Plain TCP to a local env host (default 127.0.0.1:41113). No WebSocket
  ## layer: control frames ride the socket bare. The caller must send a
  ## kind-11 attach as the first frame (`sendAttach`).
  result = EnvClient(host: host, port: Port(port), closed: false, rawTcp: true)
  result.sock = newSocket(buffered = false)
  result.sock.connect(host, Port(port))

proc sendControlFrame*(
  c: EnvClient;
  kind: uint16;
  requestId: uint32;
  payload: string = ""
) =
  ## Send one control frame — bare on direct TCP, masked binary WS otherwise.
  let data = encodeControlFrame(kind, requestId, payload)
  if c.rawTcp:
    if c.isNil or c.closed or c.sock.isNil:
      raise newException(IOError, "env client closed")
    c.sock.sendAll(data)
  else:
    c.sendWsFrame(WsOpBinary, data)

proc sendAttach*(c: EnvClient; attachJson: string) =
  ## Direct-TCP only: kind-11 attach must be the first frame on the wire.
  c.sendControlFrame(FrameEnvAttach, 0, attachJson)

proc sendActionSubmission*(
  c: EnvClient;
  requestId: uint32;
  payloadJson: string
) =
  ## Send a kind-9 action_submission frame (JSON payload).
  c.sendControlFrame(FrameActionSubmission, requestId, payloadJson)

proc recvControlFrame*(c: EnvClient): ControlFrame =
  ## Receive the next binary control frame (answers ping; surfaces close).
  if c.rawTcp:
    let hdr = c.recvExact(ControlHeaderSize)
    let (kind, rid, plen) = decodeControlHeader(hdr)
    result.kind = kind
    result.requestId = rid
    result.payload = c.recvExact(plen)
    return
  while true:
    let (opcode, payload) = c.recvWsMessage()
    if opcode != WsOpBinary:
      raise newException(
        ValueError,
        "environment transport accepts binary messages only (got opcode " &
          $opcode & ")"
      )
    return decodeControlFrame(payload)

proc lastClose*(c: EnvClient): WsCloseInfo =
  ## Last peer close info, if any.
  if c.hasClose:
    result = c.closeInfo
  else:
    result = WsCloseInfo(code: 0, reason: "")
