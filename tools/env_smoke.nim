## Live smoke client for WS /env: hello + N agent frames, then clean close.
##
##   nim r tools/env_smoke.nim --host=127.0.0.1 --port=8080 --slot=0 \
##     --token=token-0 --frames=5
##
## Does not select actions. Compile/check only in agent workflows when a human
## session owns :8080 — the operator runs the live smoke.

import
  std/[json, parseopt, random, strformat, strutils],
  env_transport, msgpack_json

type
  SmokeConfig = object
    host: string
    port: int
    slot: int
    token: string
    frames: int
    direct: bool        # plain TCP to a host-local env host; we send attach
    dump: bool          # print the first agent frame as full pretty JSON
    account: string
    password: string
    character: string
    gameUrl: string     # base for assets/navmesh URLs in the attach payload
    assetSlot: int      # slot in the assets/navmesh query — NOT the attach slot;
                        # only tokens[slot] pairs authenticate (slot_token_valid)

proc usage() =
  echo "usage: env_smoke [--host=127.0.0.1] [--port=8080] [--slot=0] " &
    "[--token=token-0] [--frames=5]"
  echo "  direct env-host mode (no WS relay): --direct [--port=41113] " &
    "[--account=coworld] [--password=coworld] [--character=Nightsun] " &
    "[--game-url=http://127.0.0.1:8080]"
  quit 2

proc parseArgs(): SmokeConfig =
  result = SmokeConfig(
    host: "127.0.0.1",
    port: 0,
    slot: 0,
    token: "token-0",
    frames: 5,
    direct: false,
    account: "coworld",
    password: "coworld",
    character: "Nightsun",
    gameUrl: "http://127.0.0.1:8080",
    assetSlot: 0
  )
  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "host", "h":
        result.host = val
      of "port", "p":
        result.port = parseInt(val)
      of "slot", "s":
        result.slot = parseInt(val)
      of "token", "t":
        result.token = val
      of "frames", "n", "f":
        result.frames = parseInt(val)
      of "direct":
        result.direct = true
      of "dump":
        result.dump = true
      of "account":
        result.account = val
      of "password":
        result.password = val
      of "character":
        result.character = val
      of "game-url":
        result.gameUrl = val
      of "asset-slot":
        result.assetSlot = parseInt(val)
      of "help":
        usage()
      else:
        echo "unknown option: --", key
        usage()
    of cmdArgument:
      echo "unexpected argument: ", key
      usage()
    of cmdEnd:
      discard

proc jget(n: JsonNode; keys: varargs[string]): JsonNode =
  result = n
  for k in keys:
    if result.isNil or result.kind != JObject or k notin result:
      return nil
    result = result[k]

proc jstr(n: JsonNode; def = ""): string =
  if n.isNil:
    return def
  case n.kind
  of JString: n.getStr
  of JInt: $n.getInt
  of JFloat: $n.getFloat
  of JBool: $n.getBool
  else: def

proc closeMessage(code: int; reason: string): string =
  ## Human-readable exit text for known /env close codes.
  case code
  of 1008:
    result = "close 1008: bad token or slot already attached"
  of 1011:
    result = "close 1011: internal error or session ended before hello"
  of 1002:
    result = "close 1002: protocol error"
  of 1000:
    result = "close 1000: normal closure"
  of 1001:
    result = "close 1001: going away"
  else:
    result = "close " & $code
  if reason.len > 0:
    result.add " (" & reason & ")"

proc summarizeAgentFrame(requestId: uint32; node: JsonNode): string =
  ## One compact summary line: request id + a few recognizable fields.
  var parts: seq[string]
  parts.add "request_id=" & $requestId
  let frameId = jget(node, "frame_id")
  if frameId.isNil:
    let alt = jget(node, "frameId")
    if not alt.isNil:
      parts.add "frame_id=" & jstr(alt)
  else:
    parts.add "frame_id=" & jstr(frameId)
  let tick = jget(node, "tick")
  if not tick.isNil:
    parts.add "tick=" & jstr(tick)
  let charName = jget(node, "observation", "character", "name")
  if charName.isNil:
    let c2 = jget(node, "observation", "self", "name")
    if not c2.isNil:
      parts.add "name=" & jstr(c2)
    else:
      let c3 = jget(node, "observation", "player_name")
      if not c3.isNil:
        parts.add "name=" & jstr(c3)
  else:
    parts.add "name=" & jstr(charName)
  let zone = jget(node, "observation", "zone")
  if not zone.isNil:
    parts.add "zone=" & jstr(zone)
  let hp = jget(node, "observation", "character", "health")
  if hp.isNil:
    let hp2 = jget(node, "observation", "self", "health")
    if not hp2.isNil:
      parts.add "health=" & jstr(hp2)
  else:
    parts.add "health=" & jstr(hp)
  # Always include top-level key count so empty unpacks are obvious.
  if node.kind == JObject:
    parts.add "keys=" & $node.len
  result = parts.join(" ")

proc attachPayload(cfg: SmokeConfig): string =
  ## Mirror of the relay's env_attach_payload (game/env_service.py) for the
  ## direct env-host path: assets/navmesh served by the game HTTP port with
  ## slot+token auth; the env host itself takes no token.
  randomize()
  var sid = ""
  for _ in 0 ..< 32:
    sid.add "0123456789abcdef"[rand(15)]
  let q = "?slot=" & $cfg.assetSlot & "&token=" & cfg.token
  $(%*{
    "protocol": "vanilla_wow.env.attach.v1",
    "type": "attach",
    "session_id": sid,
    "slot": cfg.slot,
    "account_username": cfg.account,
    "account_password": cfg.password,
    "character_name": cfg.character,
    "character_creation": nil,
    "simulation_time_scale": 1,
    "class_deck_enabled": false,
    "assets_base_url": cfg.gameUrl & "/player/assets" & q,
    "navmesh_service_url": cfg.gameUrl & "/player/navigation" & q
  })

proc main() =
  let cfg = parseArgs()
  if cfg.frames < 0:
    echo "frames must be >= 0"
    quit 2
  let port =
    if cfg.port != 0: cfg.port
    elif cfg.direct: 41113
    else: 8080
  var client: EnvClient
  try:
    if cfg.direct:
      client = connectEnvDirect(cfg.host, port)
      client.sendAttach(attachPayload(cfg))
    else:
      client = connectEnv(cfg.host, port, cfg.slot, cfg.token)
  except EnvTransportError as e:
    echo closeMessage(e.closeCode, e.closeReason)
    if e.closeCode == 0:
      echo "connect failed: ", e.msg
    quit 1
  except CatchableError as e:
    echo "connect failed: ", e.msg
    quit 1

  try:
    # First frame should be hello (kind 12, JSON).
    let hello = client.recvControlFrame()
    if hello.kind != FrameEnvHello:
      echo &"expected hello kind {FrameEnvHello}, got {hello.kind}"
      client.close()
      quit 1
    echo "hello: ", hello.payload

    var got = 0
    while got < cfg.frames:
      let frame = client.recvControlFrame()
      case frame.kind
      of FrameAgentFrame:
        inc got
        var node: JsonNode
        try:
          node = unpackJson(frame.payload)
        except CatchableError as e:
          echo &"agent_frame request_id={frame.requestId} msgpack_error={e.msg} bytes={frame.payload.len}"
          continue
        if cfg.dump and got == 1:
          echo node.pretty
        echo "agent_frame ", summarizeAgentFrame(frame.requestId, node)
      of FrameControlError:
        echo "control_error request_id=", frame.requestId, " ", frame.payload
      of FrameEnvClose:
        echo "env_close: ", frame.payload
        break
      of FrameEnvHello:
        echo "hello(re): ", frame.payload
      else:
        echo &"frame kind={frame.kind} request_id={frame.requestId} bytes={frame.payload.len}"

    client.close(1000, "env_smoke done")
  except EnvTransportError as e:
    echo closeMessage(e.closeCode, e.closeReason)
    if e.closeCode == 0:
      echo e.msg
    quit 1
  except CatchableError as e:
    echo "error: ", e.msg
    try:
      client.close()
    except CatchableError:
      discard
    quit 1

main()
