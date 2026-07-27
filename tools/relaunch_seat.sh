#!/usr/bin/env bash
# relaunch_seat.sh <slot> <account> <character> <class> <binary>
set -eu
cd "$(dirname "$0")/.."
SLOT=$1; ACCT=$2; CHAR=$3; CLASS=$4; BIN=$5
LDP=$(cat local_data/slot2.ldpath)
setsid nohup env \
  LD_LIBRARY_PATH="$LDP" \
  VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
  VANILLA_WOW_PLAYER_REALM_PORT=3724 \
  VANILLA_WOW_PLAYER_USERNAME="$ACCT" \
  VANILLA_WOW_PLAYER_PASSWORD="$ACCT" \
  VANILLA_WOW_PLAYER_CHARACTER_NAME="$CHAR" \
  VANILLA_WOW_PLAYER_CHARACTER_RACE=undead \
  VANILLA_WOW_PLAYER_CHARACTER_CLASS="$CLASS" \
  VANILLA_WOW_PLAYER_CHARACTER_GENDER=male \
  VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
  WOW_SDK_NIM_RUNTIME_SLOT="$SLOT" \
  WOW_SDK_NIM_RUNTIME_DIR="$PWD/local_data/nim-runtime-slot$SLOT" \
  WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
  VANILLA_WOW_NAVMESH_HELPER=/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow/tmp/vmangos-navmesh-helper \
  VANILLA_WOW_EXTRACTED_DATA_DIR=/home/monofuel/Documents/Projects/Softmax/coworld-vanilla-wow/local_data/vmangos-5875-data \
  "./local_data/$BIN" --scenario=nim-control \
  > "local_data/brain-logs/seat-slot$SLOT.log" 2>&1 < /dev/null &
echo "slot $SLOT ($CHAR) launched with $BIN"
