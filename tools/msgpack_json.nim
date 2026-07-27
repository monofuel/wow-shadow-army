## Minimal MessagePack → JsonNode unpacker (env frames only).
import std/[json, streams, strutils, endians]

proc readExact(s: Stream, n: int): string =
  result = s.readStr(n)
  if result.len != n:
    raise newException(IOError, "truncated msgpack")

proc unpackJson*(s: Stream): JsonNode

proc unpackJson*(s: Stream): JsonNode =
  let b = s.readChar().uint8
  case b
  of 0x00..0x7f:
    result = newJInt(int(b))
  of 0x80..0x8f:
    let n = int(b - 0x80)
    result = newJObject()
    for i in 0..<n:
      let k = unpackJson(s)
      let v = unpackJson(s)
      result[k.getStr] = v
  of 0x90..0x9f:
    let n = int(b - 0x90)
    result = newJArray()
    for i in 0..<n:
      result.add unpackJson(s)
  of 0xa0..0xbf:
    let n = int(b - 0xa0)
    result = newJString(s.readExact(n))
  of 0xc0:
    result = newJNull()
  of 0xc2:
    result = newJBool(false)
  of 0xc3:
    result = newJBool(true)
  of 0xc4:
    let n = s.readUint8().int
    discard s.readExact(n)
    result = newJString("") # bin as empty
  of 0xc5:
    let n = s.readUint16().int
    discard s.readExact(n)
    result = newJString("")
  of 0xc6:
    var n: uint32
    var buf = s.readExact(4)
    littleEndian32(addr n, addr buf[0])
    discard s.readExact(int(n))
    result = newJString("")
  of 0xca:
    var f: float32
    var buf = s.readExact(4)
    # big-endian float32 for msgpack
    var be: uint32
    bigEndian32(addr be, addr buf[0])
    copyMem(addr f, addr be, 4)
    result = newJFloat(float(f))
  of 0xcb:
    var f: float64
    var buf = s.readExact(8)
    var be: uint64
    bigEndian64(addr be, addr buf[0])
    copyMem(addr f, addr be, 8)
    result = newJFloat(f)
  of 0xcc:
    result = newJInt(int(s.readUint8()))
  of 0xcd:
    var n: uint16
    var buf = s.readExact(2)
    bigEndian16(addr n, addr buf[0])
    result = newJInt(int(n))
  of 0xce:
    var n: uint32
    var buf = s.readExact(4)
    bigEndian32(addr n, addr buf[0])
    result = newJInt(int(n))
  of 0xcf:
    var n: uint64
    var buf = s.readExact(8)
    bigEndian64(addr n, addr buf[0])
    result = newJInt(int(n)) # may truncate
  of 0xd0:
    result = newJInt(int(cast[int8](s.readUint8())))
  of 0xd1:
    var n: int16
    var buf = s.readExact(2)
    bigEndian16(addr n, addr buf[0])
    result = newJInt(int(n))
  of 0xd2:
    var n: int32
    var buf = s.readExact(4)
    bigEndian32(addr n, addr buf[0])
    result = newJInt(int(n))
  of 0xd3:
    var n: int64
    var buf = s.readExact(8)
    bigEndian64(addr n, addr buf[0])
    result = newJInt(int(n))
  of 0xd9:
    let n = s.readUint8().int
    result = newJString(s.readExact(n))
  of 0xda:
    var n: uint16
    var buf = s.readExact(2)
    bigEndian16(addr n, addr buf[0])
    result = newJString(s.readExact(int(n)))
  of 0xdb:
    var n: uint32
    var buf = s.readExact(4)
    bigEndian32(addr n, addr buf[0])
    result = newJString(s.readExact(int(n)))
  of 0xdc:
    var n: uint16
    var buf = s.readExact(2)
    bigEndian16(addr n, addr buf[0])
    result = newJArray()
    for i in 0..<int(n):
      result.add unpackJson(s)
  of 0xdd:
    var n: uint32
    var buf = s.readExact(4)
    bigEndian32(addr n, addr buf[0])
    result = newJArray()
    for i in 0..<int(n):
      result.add unpackJson(s)
  of 0xde:
    var n: uint16
    var buf = s.readExact(2)
    bigEndian16(addr n, addr buf[0])
    result = newJObject()
    for i in 0..<int(n):
      let k = unpackJson(s).getStr
      result[k] = unpackJson(s)
  of 0xdf:
    var n: uint32
    var buf = s.readExact(4)
    bigEndian32(addr n, addr buf[0])
    result = newJObject()
    for i in 0..<int(n):
      let k = unpackJson(s).getStr
      result[k] = unpackJson(s)
  of 0xe0..0xff:
    result = newJInt(int(cast[int8](b)))
  else:
    raise newException(ValueError, "unsupported msgpack byte " & $b)

proc unpackJson*(data: string): JsonNode =
  var ss = newStringStream(data)
  result = unpackJson(ss)
