import
  std/[algorithm, httpclient, json, os, parseopt, strutils, times]

type
  Config = object
    seat: string
    observation: string
    outbox: string
    persona: string
    endpoint: string
    model: string
    speaker: string
    minInterval: float
    poll: float
    maxChars: int
    once: bool

  ChatMsg = object
    sequence: int
    kind: string
    senderName: string
    text: string

  CleanReply = object
    text: string
    slash: bool

const
  DefaultEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
  DefaultModel = "qwen/qwen3.8-27b"
  DefaultSpeaker = "Murist"
  DefaultMinInterval = 20.0
  DefaultPoll = 1.0
  DefaultMaxChars = 120
  HttpTimeoutMs = 30_000
  MaxTokens = 64
  Temperature = 0.9
  MaxContextMessages = 6
  OutboxProtocol = "wow_shadow_army.bot_chat.v1"
  KillEnv = "SHADOW_CHAT_QWEN_OFF"
  KillFileName = "chat-qwen.off"

proc usage() =
  stderr.writeLine(
    "usage: bot_chat_qwen --seat=NAME --observation=PATH --outbox=PATH " &
    "--persona=PATH [--endpoint=URL] [--model=ID] [--speaker=NAME] " &
    "[--min-interval=SECONDS] [--poll=SECONDS] [--max-chars=N] [--once]"
  )

proc parseConfig(): Config =
  result.endpoint = DefaultEndpoint
  result.model = DefaultModel
  result.speaker = DefaultSpeaker
  result.minInterval = DefaultMinInterval
  result.poll = DefaultPoll
  result.maxChars = DefaultMaxChars
  for kind, key, value in getopt():
    case kind
    of cmdArgument, cmdEnd:
      continue
    of cmdLongOption, cmdShortOption:
      if key.len == 0:
        continue
      case key
      of "seat":
        result.seat = value
      of "observation":
        result.observation = value
      of "outbox":
        result.outbox = value
      of "persona":
        result.persona = value
      of "endpoint":
        result.endpoint = value
      of "model":
        result.model = value
      of "speaker":
        result.speaker = value
      of "min-interval":
        try:
          result.minInterval = parseFloat(value)
        except ValueError:
          usage()
          quit(2)
      of "poll":
        try:
          result.poll = parseFloat(value)
        except ValueError:
          usage()
          quit(2)
      of "max-chars":
        try:
          result.maxChars = parseInt(value)
        except ValueError:
          usage()
          quit(2)
      of "once":
        result.once = true
      else:
        usage()
        quit(2)
  if result.seat.len == 0 or result.observation.len == 0 or
      result.outbox.len == 0 or result.persona.len == 0:
    usage()
    quit(2)

proc logLine(seat, msg: string) =
  stdout.writeLine("bot-chat[" & seat & "]: " & msg)
  stdout.flushFile()

proc logSkip(seat, reason: string) =
  logLine(seat, "skip " & reason)

proc killSwitchOn(outbox: string): bool =
  let envVal = getEnv(KillEnv)
  if envVal.len > 0 and envVal != "0":
    return true
  let seatDir = parentDir(outbox) / ".."
  # One file silences a seat, its parent silences the whole army.
  fileExists(seatDir / KillFileName) or
    fileExists(seatDir / ".." / KillFileName)

proc loadMessages(path: string): seq[ChatMsg] =
  if not fileExists(path):
    raise newException(IOError, "missing observation")
  let node = parseJson(readFile(path))
  if node.kind != JObject:
    raise newException(ValueError, "observation is not an object")
  let arr = node{"chat_messages"}
  if arr.isNil or arr.kind == JNull:
    return
  if arr.kind != JArray:
    raise newException(ValueError, "chat_messages is not an array")
  for item in arr:
    if item.kind != JObject:
      continue
    result.add ChatMsg(
      sequence: item{"sequence"}.getInt(),
      kind: item{"kind"}.getStr(),
      senderName: item{"sender_name"}.getStr(),
      text: item{"text"}.getStr()
    )

proc maxSequence(msgs: openArray[ChatMsg]): int =
  for msg in msgs:
    if msg.sequence > result:
      result = msg.sequence

proc isTrigger(msg: ChatMsg; speaker: string; highest: int): bool =
  if msg.kind != "party":
    return false
  if cmpIgnoreCase(msg.senderName, speaker) != 0:
    return false
  if msg.sequence <= highest:
    return false
  let text = msg.text.strip()
  if text.len == 0:
    return false
  if text.startsWith("<SA>") or text.startsWith("<SYS>"):
    return false
  true

proc newestTrigger(msgs: openArray[ChatMsg]; speaker: string;
    highest: int): ChatMsg =
  result.sequence = -1
  for msg in msgs:
    if isTrigger(msg, speaker, highest):
      if result.sequence < 0 or msg.sequence > result.sequence:
        result = msg

proc partyContext(msgs: openArray[ChatMsg]; triggerSeq: int): seq[ChatMsg] =
  for msg in msgs:
    if msg.kind != "party" or msg.sequence > triggerSeq:
      continue
    let text = msg.text.strip()
    if text.len == 0 or text.startsWith("<SA>") or text.startsWith("<SYS>"):
      continue
    result.add msg
  result.sort do (a, b: ChatMsg) -> int:
    cmp(a.sequence, b.sequence)
  if result.len > MaxContextMessages:
    result = result[^MaxContextMessages .. ^1]

proc buildUserPrompt(msgs: openArray[ChatMsg]; trigger: ChatMsg;
    cfg: Config): string =
  var lines: seq[string]
  for msg in partyContext(msgs, trigger.sequence):
    lines.add msg.senderName & ": " & msg.text
  lines.add "Reply to " & cfg.speaker & " as " & cfg.seat &
    ". One short sentence, under " & $cfg.maxChars & " characters."
  lines.join("\n")

proc requestCompletion(cfg: Config; persona, userPrompt: string): string =
  let client = newHttpClient(timeout = HttpTimeoutMs)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  # This model emits empty content unless reasoning_effort is none.
  let payload = %*{
    "model": cfg.model,
    "reasoning_effort": "none",
    "max_tokens": MaxTokens,
    "temperature": Temperature,
    "messages": [
      {"role": "system", "content": persona},
      {"role": "user", "content": userPrompt}
    ]
  }
  let response = client.request(
    cfg.endpoint, httpMethod = HttpPost, body = $payload
  )
  if response.code != Http200:
    raise newException(IOError, "HTTP " & $response.code)
  let parsed = parseJson(response.body)
  if parsed.kind != JObject or parsed{"choices"}.isNil or
      parsed["choices"].kind != JArray or parsed["choices"].len == 0:
    raise newException(ValueError, "unparseable body")
  let message = parsed["choices"][0]{"message"}
  if message.isNil or message.kind != JObject:
    raise newException(ValueError, "unparseable body")
  message{"content"}.getStr()

proc sanitizeReply(text: string; maxChars: int): CleanReply =
  var s = text
  let nl = s.find('\n')
  if nl >= 0:
    s = s[0 ..< nl]
  s = s.strip()
  if s.len >= 2 and (
      (s[0] == '"' and s[^1] == '"') or (s[0] == '\'' and s[^1] == '\'')):
    s = s[1 ..< s.len - 1]
  # The seat reads this line back out of a JSON field with a plain pattern,
  # so the text must never carry a quote or an escape of its own. Banter
  # loses nothing by giving them up.
  var cleaned = newStringOfCap(s.len)
  for ch in s:
    if ch >= ' ' and ch <= '~' and ch != '"' and ch != '\\':
      cleaned.add ch
  s = cleaned.splitWhitespace().join(" ")
  if s.len == 0:
    return
  if s.startsWith("/"):
    result.slash = true
    return
  if s.len > maxChars:
    s = s[0 ..< maxChars]
    let sp = s.rfind(' ')
    if sp >= 0:
      s = s[0 ..< sp]
  result.text = s

proc outboxBusy(path: string): bool =
  if not fileExists(path):
    return false
  getFileSize(path) > 0

proc writeOutbox(cfg: Config; text: string; id, replyTo: int) =
  let parent = parentDir(cfg.outbox)
  if parent.len > 0:
    createDir(parent)
  let body = $(%*{
    "protocol": OutboxProtocol,
    "seat": cfg.seat,
    "channel": "party",
    "text": text,
    "id": id,
    "reply_to": replyTo,
    "created_at_unix_seconds": epochTime()
  })
  let tmp = cfg.outbox & ".tmp"
  writeFile(tmp, body)
  moveFile(tmp, cfg.outbox)

proc main() =
  let cfg = parseConfig()
  if not fileExists(cfg.persona):
    stderr.writeLine("bot-chat: persona file not found: " & cfg.persona)
    quit(1)
  let persona = readFile(cfg.persona)
  var highest = 0
  # --once starts at 0 so existing messages count as new.
  if not cfg.once:
    try:
      highest = maxSequence(loadMessages(cfg.observation))
    except CatchableError:
      discard
  logLine(
    cfg.seat,
    "endpoint=" & cfg.endpoint & " model=" & cfg.model &
      " persona=" & cfg.persona & " starting_sequence=" & $highest
  )
  var
    lastReplyAt = 0.0
    nextId = 1
    parseErrorLogged = false
    killedLogged = false
  while true:
    let killed = killSwitchOn(cfg.outbox)
    var msgs: seq[ChatMsg]
    var loaded = false
    try:
      msgs = loadMessages(cfg.observation)
      loaded = true
      parseErrorLogged = false
    except CatchableError:
      if not parseErrorLogged:
        logLine(cfg.seat, "observation unreadable")
        parseErrorLogged = true
    if killed:
      if not killedLogged:
        logSkip(cfg.seat, "killed")
        killedLogged = true
      if loaded:
        highest = max(highest, maxSequence(msgs))
    else:
      killedLogged = false
      if loaded:
        var trigger = newestTrigger(msgs, cfg.speaker, highest)
        highest = max(highest, maxSequence(msgs))
        if trigger.sequence >= 0:
          logLine(
            cfg.seat,
            "trigger sequence=" & $trigger.sequence &
              " text=" & trigger.text.strip()
          )
          if outboxBusy(cfg.outbox):
            logSkip(cfg.seat, "outbox_busy")
          elif lastReplyAt > 0.0 and
              epochTime() - lastReplyAt < cfg.minInterval:
            logSkip(cfg.seat, "rate_limited")
          else:
            let started = epochTime()
            var raw = ""
            var httpFailed = false
            try:
              raw = requestCompletion(
                cfg, persona, buildUserPrompt(msgs, trigger, cfg)
              )
            except CatchableError as err:
              stderr.writeLine(
                "bot-chat[" & cfg.seat & "]: http_error " & err.msg
              )
              stderr.flushFile()
              logSkip(cfg.seat, "http_error")
              httpFailed = true
            if not httpFailed:
              let cleaned = sanitizeReply(raw, cfg.maxChars)
              if cleaned.slash:
                logSkip(cfg.seat, "slash_reply")
              elif cleaned.text.len == 0:
                logSkip(cfg.seat, "empty_reply")
              else:
                writeOutbox(cfg, cleaned.text, nextId, trigger.sequence)
                lastReplyAt = epochTime()
                logLine(
                  cfg.seat,
                  "reply latency=" &
                    formatFloat(lastReplyAt - started, ffDecimal, 3) &
                    " text=" & cleaned.text
                )
                inc nextId
    if cfg.once:
      break
    sleep(int(cfg.poll * 1000.0))

when isMainModule:
  main()
