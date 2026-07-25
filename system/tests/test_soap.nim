## Unit tests for SOAP XML escape + result extraction.
## Run: nim r --hints:off --warnings:off system/tests/test_soap.nim
## No network, no docker, no realm — pure functions on fixture strings.

import
  std/[options, strutils, unittest],
  ../system_server

const
  SuccessEnvelope = """<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:ns1="urn:MaNGOS">
  <SOAP-ENV:Body>
    <ns1:executeCommandResponse>
      <result>There is no such command</result>
    </ns1:executeCommandResponse>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>"""

  FaultEnvelope = """<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <SOAP-ENV:Fault>
      <faultcode>SOAP-ENV:Client</faultcode>
      <faultstring>HTTP Error: 401 Unauthorized</faultstring>
    </SOAP-ENV:Fault>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>"""

suite "escapeXml":
  test "escapes ampersand less-than greater-than":
    check escapeXml("a & b < c > d") == "a &amp; b &lt; c &gt; d"
    check escapeXml("plain") == "plain"
    check escapeXml("") == ""

  test "command body embeds escaped text":
    let body = buildSoapBody("announce foo & <bar>")
    check body.contains("<command>announce foo &amp; &lt;bar&gt;</command>")
    check not body.contains("<command>announce foo & <bar></command>")

suite "extractSoapResult":
  test "success envelope yields result text":
    let r = extractSoapResult(SuccessEnvelope)
    check r.isSome
    check r.get == "There is no such command"

  test "fault envelope has no result":
    check extractSoapResult(FaultEnvelope).isNone

  test "empty / garbage":
    check extractSoapResult("").isNone
    check extractSoapResult("<nope/>").isNone
