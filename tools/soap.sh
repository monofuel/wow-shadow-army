#!/usr/bin/env bash
# VMaNGOS SOAP console helper — SETUP AND OBSERVATION ONLY.
#
#   tools/soap.sh account create shadow9 shadow9
#   tools/soap.sh server info
#
# Same credentials and envelope as system_server.nim's gmCommand (see
# `make soap-account` for how the `system` GM account is provisioned). Exists
# because the upstream account-provisioning script the `*-account` Makefile
# targets call (server/scripts/manage_coworld_accounts.py) no longer exists in
# the upstream checkout — see docs/quest-qa-2026-08-15.md.
#
# AGENTS.md rules still bind: account creation, server logs, and scenario-bot
# checkpoint positioning only. Never levels, XP, gold, items, quest completion,
# loot, or any position control over Murist.
set -euo pipefail

container="${SOAP_CONTAINER:-coworld-vmangos-coworld-game-1}"
user="${SYSTEM_SOAP_USER:-system}"
pass="${SYSTEM_SOAP_PASS:-shadowsoap}"

if [ "$#" -eq 0 ]; then
  echo "usage: tools/soap.sh <gm console command without leading dot>" >&2
  exit 2
fi

ip="${SYSTEM_SOAP_HOST:-}"
if [ -z "$ip" ]; then
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$container")
fi
if [ -z "$ip" ]; then
  echo "error: could not resolve SOAP host for container $container" >&2
  exit 1
fi

command_text="$*"
escaped=$(printf '%s' "$command_text" |
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

body="<?xml version=\"1.0\" encoding=\"utf-8\"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:ns1=\"urn:MaNGOS\">
  <SOAP-ENV:Body><ns1:executeCommand><command>${escaped}</command></ns1:executeCommand></SOAP-ENV:Body>
</SOAP-ENV:Envelope>"

response=$(curl -sS --fail-with-body -u "${user}:${pass}" \
  -H 'Content-Type: application/xml' -X POST "http://${ip}:7878/" -d "$body")

printf '%s\n' "$response" |
  sed -e 's/.*<result>//' -e 's|</result>.*||' \
      -e 's/&#xD;//g' -e 's/&#xA;/\n/g' -e 's/&amp;/\&/g' |
  tail -n +2
