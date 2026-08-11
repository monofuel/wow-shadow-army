# Unit tier: instant, no network/docker/sleeps. Integration tier may use the
# local realm (see coworld-playbook/games/vanilla-wow.md for bring-up).
# Lua: PATH lua5.3 if present, else nix shell (same pattern as
# crewrift-prime-bots).
LUA := $(shell command -v lua5.3 2>/dev/null || command -v lua 2>/dev/null)
ifeq ($(LUA),)
RUN_LUA = nix shell nixpkgs\#lua5_3 --command lua
else
RUN_LUA = $(LUA)
endif
# luac for parse-only smoke checks (same PATH-then-nix pattern).
LUAC := $(shell command -v luac5.3 2>/dev/null || command -v luac 2>/dev/null)
ifeq ($(LUAC),)
RUN_LUAC = nix shell nixpkgs\#lua5_3 --command luac
else
RUN_LUAC = $(LUAC)
endif

# Upstream coworld-vanilla-wow checkout (sibling; read-only — never write there).
UPSTREAM := $(abspath ../coworld-vanilla-wow)
# Vendored NixOS client library env (from coworld-playbook/tools/wow_env.sh).
WOW_ENV := $(CURDIR)/tools/wow_env.sh

# Our fork of the client: hosts the lua-bot identity that runs lua/entry/*.lua.
FORK_CLIENT := $(abspath ../monofuel-vanilla-wow)
# Lua entry module driven by the accelerated targets.
ENTRY ?= accelerated
LUA_BOT_LAUNCH = nix develop $(FORK_CLIENT) --command \
	nim r tools/launch_nim_player.nim -- --league=accelerated \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=$(ENTRY)
# Same host, traverse league: Petrel runs as lua/entry/traverse.lua.
# Upstream renamed the leagues in the hosted-session protocol update
# (2026-08-10): traverse -> race (same kalimdor_traversal scenario).
TRAVERSE_LAUNCH = nix develop $(FORK_CLIENT) --command \
	nim r tools/launch_nim_player.nim -- --league=race \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=traverse \
	--lua-status-dir=$(CURDIR)/local_data/traverse-status

# Local realm operator inputs (paths relative to UPSTREAM).
export VANILLA_WOW_EXTRACTED_DATA_DIR := $(UPSTREAM)/local_data/vmangos-5875-data
export VMANGOS_MYSQL_DUMPS_DIR := $(UPSTREAM)/local_data/vmangos-db/mysql-dump
export COWORLD_CONFIG_DIR := $(UPSTREAM)/local_data/coworld-config
export COWORLD_RUN_DIR := $(UPSTREAM)/local_data/coworld-run
# Detour pathfinding helper (docs/navmesh.md). Without it every move settles
# `movement_blocked`. Build once with `make navmesh-helper`; the mmaps it reads
# come from VANILLA_WOW_EXTRACTED_DATA_DIR/mmaps above.
export VANILLA_WOW_NAVMESH_HELPER := $(UPSTREAM)/tmp/vmangos-navmesh-helper
# Sparse vmangos/core checkout supplying dep/recastnavigation + dep/include.
VMANGOS_CORE_DIR := $(UPSTREAM)/local_data/reference/vmangos-core

# Realm lifecycle: tools/realm_op.sh discovers the upstream operator script and
# adds --build when the local image lacks feature metadata. Same path The System
# uses (dashboard Start server). Override with SYSTEM_UPSTREAM_DIR if needed.
# Realm ops go through OUR fork's operator/compose: it carries the
# VMANGOS_DB_DIR override that keeps the persistent realm database on a
# plain host directory (see tools/realm_op.sh). The upstream checkout
# stays a read-only data home.
export SYSTEM_UPSTREAM_DIR ?= $(FORK_CLIENT)
export SYSTEM_ARMY_DIR ?= $(CURDIR)
REALM_OP := $(CURDIR)/tools/realm_op.sh
# Direct operator still used by server-logging (write-config / smoke flags).
OPERATOR := $(REALM_OP)
COMPOSE_FILE := infra/compose.vmangos.yml
# Human playtest account (type at the GlueXML login screen).
ACCOUNT_USER := monofuel
ACCOUNT_PASS := password

.PHONY: test test-lua test-nim system pin-check start-server stop-server server-logging logs account soap-account play play-classic play-classic-netlog play-xr traverse traverse-field traverse-replay traverse-pack-replay traverse-headed traverse-pol traverse-desert traverse-wet traverse-checkpoints lift-tele quest-data warlock-account warlock-bot botwarrior-bot tusk-account tusk-bot beru-account beru-bot party-army navmesh-helper navmesh-status map-browser map-browser-once map-browser-debug map-browser-probe

# Unit tier: Lua tools + Nim host/system tests only (v2 DoD: no Python required
# for bot correctness). If nim is missing, test-nim-soft skips rather than
# failing bare CI hosts. Smoke tier parse/compile-checks code no unit test
# executes (addon Lua, army_host) — doctrine: a cheap compile-check is a
# legitimate leg for a binary with no unit tests yet.
test: test-lua test-nim-soft test-smoke test-traverse-soap test-traverse-checkpoint

.PHONY: test-traverse-soap test-traverse-checkpoint
test-traverse-soap:
	@python3 tools/tests/test_traverse_soap.py
test-traverse-checkpoint:
	@python3 tools/tests/test_traverse_checkpoint.py
	@python3 tools/tests/test_traverse_scorecard.py

# Every Nim entrypoint/module must at least compile (`nim check`), even where
# no unit suite imports it yet (army_host, msgpack_json).
NIM_CHECK_FILES = system/system_server.nim \
	tools/fair_play_audit.nim tools/party_promote.nim

.PHONY: test-smoke test-smoke-lua test-smoke-nim test-smoke-nim-soft
test-smoke: test-smoke-lua test-smoke-nim-soft

# Parse-only check of every non-test Lua file (addon files are Lua 5.0-style
# but 5.3 luac still catches syntax errors; the addon itself is never run by
# lua/tests, so this is its only automated gate).
test-smoke-lua:
	@rc=0; for f in addons/*/*.lua lua/*.lua lua/tools/*.lua lua/entry/*.lua; do \
		[ -f "$$f" ] || continue; \
		$(RUN_LUAC) -p "$$f" || { echo "PARSE FAIL: $$f"; rc=1; }; \
	done; \
	if [ $$rc -eq 0 ]; then echo "test-smoke-lua: all lua parses clean"; fi; \
	exit $$rc

test-smoke-nim:
	@rc=0; for f in $(NIM_CHECK_FILES); do \
		echo "== nim check $$f =="; \
		nim check --hints:off --warnings:off "$$f" || rc=1; \
	done; exit $$rc

# Like test-nim-soft: skip (not fail) on hosts without nim (lua-only CI).
test-smoke-nim-soft:
	@if command -v nim >/dev/null 2>&1; then \
		$(MAKE) test-smoke-nim; \
	else \
		echo "test-smoke-nim-soft: nim not on PATH — skip"; \
	fi

# Like test-nim but no-op when nim is unavailable (wired into `make test`).
.PHONY: test-nim-soft
test-nim-soft:
	@if command -v nim >/dev/null 2>&1; then \
		$(MAKE) test-nim; \
	else \
		echo "test-nim-soft: nim not on PATH — skip"; \
	fi

test-lua:
	@rc=0; for t in lua/tests/test_*.lua; do \
		echo "== $$t"; LUA_PATH="lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
	done; exit $$rc

# Optional Nim unit tier (enum maps / pure parsers). Not part of `make test`
# so CI and bare hosts without nim stay green. PATH-nim first, else nix develop
# if a flake appears later (same pattern as crewrift-prime-bots).
test-nim:
	@if command -v nim >/dev/null 2>&1; then \
		rc=0; \
		for t in system/tests/test_*.nim tools/tests/test_*.nim; do \
			[ -f "$$t" ] || continue; \
			case "$$t" in \
				*test_map_browser_waypoints*) \
					echo "== $$t (skipped: needs the client fork 3D deps)"; \
					continue ;; \
			esac; \
			echo "== $$t =="; \
			nim r --hints:off --warnings:off "$$t" || rc=1; \
		done; \
		exit $$rc; \
	elif [ -f flake.nix ] || [ -f shell.nix ]; then \
		rc=0; \
		for t in system/tests/test_*.nim tools/tests/test_*.nim; do \
			[ -f "$$t" ] || continue; \
			echo "== $$t =="; \
			nix develop --command nim r --hints:off --warnings:off "$$t" || rc=1; \
		done; \
		exit $$rc; \
	else \
		echo "error: nim not on PATH and no flake/shell.nix fallback" >&2; exit 1; \
	fi

# The System: mummy dashboard + MCPort on :7777 (see system/README.md).
# Works with the realm up or down; Admin tab starts/stops it via the operator.
# SYSTEM_UPSTREAM_DIR pins the operator checkout explicitly (no cwd guessing).
system:
	@SYSTEM_UPSTREAM_DIR="$${SYSTEM_UPSTREAM_DIR:-$(UPSTREAM)}" \
		SYSTEM_ARMY_DIR="$${SYSTEM_ARMY_DIR:-$$(pwd)}" \
		nix develop --command nim r system/system_server.nim

# Map browser (docs/map-plan.md). Single window: 2D drill + client terrain 3D.
# Zone view reuses fork runMapViewer terrain (fog off, no doodads).
CLASSIC_CLIENT := $(abspath ../wow-classic-data/Coworld-WoW-Classic/client)
ifeq ($(wildcard $(CLASSIC_CLIENT)/Data),)
  CLASSIC_CLIENT := $(abspath ../coworld-vanilla-wow/local_data/coworld-bundle/Coworld-WoW-Classic/client)
endif
map-browser:
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
	VANILLA_WOW_CLIENT_DATA_DIR="$${VANILLA_WOW_CLIENT_DATA_DIR:-$(CLASSIC_CLIENT)}" \
		nix develop --command nim r src/tools/map_browser.nim

map-browser-once:
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
		MAP_BROWSER_ONCE=1 \
		nix develop --command nim r src/tools/map_browser.nim

# Debug run: per-second [mb-debug] lines + stats JSON for agents.
map-browser-debug:
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
	VANILLA_WOW_CLIENT_DATA_DIR="$${VANILLA_WOW_CLIENT_DATA_DIR:-$(CLASSIC_CLIENT)}" \
		MAP_BROWSER_DEBUG=1 \
		MAP_BROWSER_STATS=local_data/map_browser_stats.json \
		nix develop --command nim r src/tools/map_browser.nim

# Autopilot probe: drill a zone, stream, screenshot + stats, exit nonzero on
# failure. Override with MAP_BROWSER_AUTO="zone=...,seconds=...,screenshot=...".
map-browser-probe:
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
	VANILLA_WOW_CLIENT_DATA_DIR="$${VANILLA_WOW_CLIENT_DATA_DIR:-$(CLASSIC_CLIENT)}" \
		MAP_BROWSER_DEBUG=1 \
		MAP_BROWSER_AUTO="$${MAP_BROWSER_AUTO:-zone=Durotar,seconds=10,screenshot=local_data/map_browser_probe.png}" \
		nix develop --command nim r src/tools/map_browser.nim

# Pin-drift only: HEAD of ../coworld-vanilla-wow must match upstream.lock.
# Pure shell — no Python. Format of upstream.lock: "<name> <sha>".
pin-check:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	want=$$(awk '{print $$2}' upstream.lock); \
	have=$$(git -C "$(UPSTREAM)" rev-parse HEAD); \
	if [ -z "$$want" ]; then echo "error: bad upstream.lock" >&2; exit 1; fi; \
	if [ "$$want" != "$$have" ]; then \
		echo "pin drift: upstream HEAD $$have != upstream.lock $$want" >&2; exit 1; \
	fi; \
	echo "pin ok: $$want"

# Escort army: Nim host + Lua escort_leader (NO PYTHON decide path).
# Accept invites + follow formation + assist/attack leader target.
# Docs: docs/rolling-issues-2026-07-26.md
#
#   make escort SLOT=2 EXTRA='--max-seconds 120'
#   make escort-army
SLOT ?= 0
EXTRA ?=
ESCORT_LEADER ?= Murist
# Full 5-man cast: human + 2 locks + warrior tank + priest healer.
ESCORT_PARTY ?= Murist,Shadowfel,Igris,Tusk,Beru
ESCORT_ACCEPT_FROM ?= Murist
# Prefer fork SDK when the fork checkout exists (matches igris/warlock-bot-fork seats).
ESCORT_UPSTREAM ?= $(shell if [ -d "$(abspath ../coworld-vanilla-wow-fork)" ]; then echo $(abspath ../coworld-vanilla-wow-fork); else echo $(UPSTREAM); fi)

# Seat identity map (docs/work-2026-08-04.md). Under the new interface, attach
# CREATES the session: army_host logs into realmd itself with these credentials
# instead of dialing a seat process that already logged in. Without them the
# host falls back to its own defaults (coworld/coworld, character "Slot<N>"),
# which is not a real seat.
#
# Recursive `=` is deliberate — the per-seat vars live with the seat targets
# further down this file and would be empty under `:=` here.
SEAT_2_ACCOUNT = $(WARLOCK_ACCOUNT)
SEAT_2_PASS = $(WARLOCK_PASS)
SEAT_2_CHARACTER = $(WARLOCK_CHARACTER)
SEAT_3_ACCOUNT = $(IGRIS_ACCOUNT)
SEAT_3_PASS = $(IGRIS_PASS)
SEAT_3_CHARACTER = $(IGRIS_CHARACTER)
SEAT_4_ACCOUNT = $(TUSK_ACCOUNT)
SEAT_4_PASS = $(TUSK_PASS)
SEAT_4_CHARACTER = $(TUSK_CHARACTER)
SEAT_5_ACCOUNT = $(BERU_ACCOUNT)
SEAT_5_PASS = $(BERU_PASS)
SEAT_5_CHARACTER = $(BERU_CHARACTER)

# Credential flags for whichever SLOT a single-seat target was invoked with.
# Unmapped slots (0/1) emit nothing and keep the host defaults.
SEAT_CREDS = $(if $(SEAT_$(SLOT)_ACCOUNT),--account=$(SEAT_$(SLOT)_ACCOUNT) \
	--password=$(SEAT_$(SLOT)_PASS) --character=$(SEAT_$(SLOT)_CHARACTER))

# Same map for the shell `for s in 2 3 4 5` loops below.
define seat_creds_case
case $$s in \
  2) acct=$(SEAT_2_ACCOUNT); pass=$(SEAT_2_PASS); char=$(SEAT_2_CHARACTER) ;; \
  3) acct=$(SEAT_3_ACCOUNT); pass=$(SEAT_3_PASS); char=$(SEAT_3_CHARACTER) ;; \
  4) acct=$(SEAT_4_ACCOUNT); pass=$(SEAT_4_PASS); char=$(SEAT_4_CHARACTER) ;; \
  5) acct=$(SEAT_5_ACCOUNT); pass=$(SEAT_5_PASS); char=$(SEAT_5_CHARACTER) ;; \
  *) echo "no seat mapping for slot $$s" >&2; exit 1 ;; \
esac
endef

# Native environment host on 127.0.0.1:41113. Required before any seat can
# attach: the local realm image omits /usr/local/bin/vanilla-wow-env-host, so
# the game's WS /env relay is dead and direct TCP is the only path
# (docs/work-2026-08-04.md). Rebuilds itself when upstream source is newer;
# use FORCE_BUILD=1 after an upstream jump.
.PHONY: accelerated accelerated-episode accelerated-pol accelerated-headed
# Full-length league episode (720 wall seconds at 10x) with the final score
# read back from the bot's own status file.
accelerated-episode:
	@cd $(FORK_CLIENT) && timeout 900 $(LUA_BOT_LAUNCH) --presentation=headless || true
	@python3 tools/episode_score.py
# Headless accelerated run of the lua-bot (ENTRY=<module>, default accelerated).
accelerated:
	@cd $(FORK_CLIENT) && $(LUA_BOT_LAUNCH) --presentation=headless

# Bounded proof-of-life receipt for the lua-bot: the league admission gate.
accelerated-pol:
	@cd $(FORK_CLIENT) && $(LUA_BOT_LAUNCH) --proof-of-life

# Watch the lua-bot play (opens a window; run only when asked).
accelerated-headed:
	@cd $(FORK_CLIENT) && $(LUA_BOT_LAUNCH) --presentation=headed

.PHONY: backup-server
backup-server:
	@tools/backup_server.sh $(LABEL)

# Restore realm state from a backup dir (name under backups/ or full path).
# DESTRUCTIVE — replaces current realm DB. make restore-server BACKUP=<name>
.PHONY: restore-server
restore-server:
	@tools/restore_server.sh $(BACKUP) --yes

# Bring up the local VMaNGOS/Coworld realm, then attach to container logs.
# Operator `up` is detached (compose up -d). Ctrl-C only detaches from logs;
# containers keep running. Use `make stop-server` to stop cleanly.
# Idempotent when already up. realm_op.sh adds --build when the image needs it.
start-server:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	"$(REALM_OP)" up; \
	echo ""; \
	echo "Realm up (detached). Attaching logs for coworld-game."; \
	echo "Ctrl-C detaches logs only — containers keep running."; \
	echo "Stop cleanly with: make stop-server"; \
	echo ""; \
	cd "$(SYSTEM_UPSTREAM_DIR)"; \
	docker compose -f "$(COMPOSE_FILE)" --profile coworld logs -f coworld-game

# Stop the coworld-game service (compose rm --stop). Does not wipe volumes
# (character/account DB state persists). Never docker kill.
stop-server:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	"$(REALM_OP)" down

# Server-side breadcrumb logging (see docs/breadcrumbs.md for the why of each
# key). Writes vmangos.mangosd_config_overrides into the operator's config.json
# and restarts the realm so configure_vmangos.py re-applies them into
# mangosd.conf/realmd.conf. Upstream stays read-only; only local_data/ changes.
#
# LogLevel.File=4 is load-bearing: combat/spellcast/moves go through
# DEBUG_FILTER_LOG (LOG_LVL_DEBUG=4) into Server.log, so clearing the
# LogFilter_* keys alone emits nothing. Console stays at 2 on purpose —
# coworld-game's docker json log is unrotated.
LOG_DIR := /coworld-run/logs
MANGOSD_LOG_OVERRIDES := \
	LogsDir=$(LOG_DIR) \
	LogLevel.File=4 \
	LogLevel.Console=2 \
	LogLevel.DB=4 \
	LogFilter_Combat=0 \
	LogFilter_SpellCast=0 \
	LogFilter_Damage=0 \
	LogFilter_PlayerMoves=0 \
	LogFilter_PeriodicAffects=0 \
	LogFile.Basic=Server.log \
	LogFile.Chat=Chat.log \
	LogFile.Char=Char.log \
	LogFile.Movement=Movement.log \
	LogFile.Timestamp=0 \
	LogsDB.Chat=1 \
	LogsDB.Characters=1 \
	LogsDB.LevelUp=1 \
	PlayerSave.Interval=20000 \
	PlayerSave.Stats.MinLevel=1 \
	PlayerSave.Stats.SaveOnlyOnLogout=0 \
	SOAP.Enabled=1 \
	SOAP.IP=0.0.0.0 \
	SOAP.Port=7878
REALMD_LOG_OVERRIDES := \
	LogsDir=$(LOG_DIR) \
	LogFile=Realmd.log \
	LogFileLevel=2
# Host-visible landing zone for every log file (bind mount of /coworld-run).
SERVER_LOG_DIR := $(UPSTREAM)/local_data/coworld-run/logs

server-logging:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	mkdir -p "$(SERVER_LOG_DIR)"; \
	cd "$(UPSTREAM)"; \
	$(OPERATOR) write-config --force \
		$(foreach kv,$(MANGOSD_LOG_OVERRIDES),--mangosd-config-override '$(kv)') \
		$(foreach kv,$(REALMD_LOG_OVERRIDES),--realmd-config-override '$(kv)'); \
	echo ""; \
	echo "Restarting realm so the overrides reach mangosd.conf/realmd.conf."; \
	$(OPERATOR) down; \
	$(OPERATOR) up --smoke; \
	echo ""; \
	echo "Logs now land in $(SERVER_LOG_DIR)"; \
	ls -la "$(SERVER_LOG_DIR)"

# Tail the harvested server logs on the host (no docker exec needed).
logs:
	@if [ ! -d "$(SERVER_LOG_DIR)" ]; then \
		echo "error: $(SERVER_LOG_DIR) missing; run make server-logging first" >&2; exit 1; \
	fi; \
	tail -F $(SERVER_LOG_DIR)/Chat.log $(SERVER_LOG_DIR)/Char.log \
		$(SERVER_LOG_DIR)/Server.log

# Idempotently ensure player account monofuel / password on the local realm.
# Uses upstream manage_coworld_accounts.py (SRP v/s via game.vmangos_auth).
# Requires a running realm (MariaDB lives inside coworld-game on host :3307).
account:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(ACCOUNT_USER):$(ACCOUNT_USER):$(ACCOUNT_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 \
		--port 3306 \
		--db-user mangos \
		--db-password mangos \
		--apply; \
	echo "account ready: $(ACCOUNT_USER) / $(ACCOUNT_PASS)"

# Dedicated GM account for The System's SOAP writes (announce only — see
# system/README.md "Scoped write exception"). Two steps because VMaNGOS reads
# security from account_access, NOT account.gmlevel (AccountMgr::GetSecurity →
# GetAccountPersistentData, cached at startup): 1) SRP account row via the
# upstream script, 2) account_access gmlevel 6 (SEC_ADMINISTRATOR — the SOAP
# handler requires >= 6). A realm restart is needed after the gmlevel change
# because the security cache loads once at boot.
SOAP_USER := system
SOAP_PASS := shadowsoap
soap-account:
	@set -e; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(SOAP_USER):$(SOAP_USER):$(SOAP_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 --port 3306 \
		--db-user mangos --db-password mangos \
		--apply; \
	docker exec "$$cid" mariadb -umangos -pmangos realmd -e \
		"REPLACE INTO account_access (id, gmlevel, RealmID) SELECT id, 6, -1 FROM account WHERE username = UPPER('$(SOAP_USER)')"; \
	echo "SOAP account ready: $(SOAP_USER) (gmlevel 6). Restart the realm if it was created just now."

# ---------------------------------------------------------------------------
# Botwarrior — the seat that PROVES MOVEMENT (docs/navmesh.md).
#
# Orc warrior, level 30, map 1 (Durotar), slot 0 / socket 127.0.0.1:41114, on
# upstream's playtest account bot1/bot1. Unlike Shadowfel it resolves a real
# leveling profile (durotar_troll_shaman), so the planner actually offers move
# options. Inherits VANILLA_WOW_NAVMESH_HELPER from the export at the top.
#
# Foreground. Detach with:
#   nohup make botwarrior-bot > local_data/botwarrior-bot.log 2>&1 &
# Ready at: "Nim binary control socket listening on 127.0.0.1:41114."
# Then drive it:
#   make shadow SLOT=0 LEADER=Botwarrior PARTY=Botwarrior \
#     EXTRA='--move-fallback --max-seconds 75'
BOTWARRIOR_RUNTIME_DIR := $(CURDIR)/local_data/nim-runtime-slot0
botwarrior-bot:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	if [ ! -x "$(VANILLA_WOW_NAVMESH_HELPER)" ]; then \
		echo "error: navmesh helper missing; run: make navmesh-helper" >&2; exit 1; \
	fi; \
	mkdir -p "$(BOTWARRIOR_RUNTIME_DIR)"; \
	cd "$(UPSTREAM)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=bot1 \
	VANILLA_WOW_PLAYER_PASSWORD=bot1 \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=Botwarrior \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=0 \
	WOW_SDK_NIM_RUNTIME_DIR=$(BOTWARRIOR_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	WOW_SDK_NIM_CONTROL_PORT=41114 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# ---------------------------------------------------------------------------
# Shadowfel — headless UNDEAD WARLOCK seat (docs/warlock-seat.md).
#
# Undead is deliberately absent from the upstream seed scripts' race maps
# (game/vmangos_character.py RACE_NAME_TO_ID is Horde-with-coverage only, and
# upstream docs/leveling-character-selection.md says not to offer Undead as a
# *hosted submission* option). That is a seeding/submission constraint, not a
# server one — so this seat never touches the characters table. The reference
# player creates the character over the wire with CMSG_CHAR_CREATE, exactly
# like a human at the CharacterCreate screen: when
# VANILLA_WOW_PLAYER_CHARACTER_NAME is not on the account,
# connectBotControlSession creates it from the RACE/CLASS/GENDER env tuple
# (nim_control_server.nim botControlCharacterSpec →
#  control_session_packets.nim). Race/class validity comes from ChrRaces.dbc /
# CharBaseInfo.dbc (client/character_identity.nim), so undead+warlock is legal.
WARLOCK_ACCOUNT := shadow1
WARLOCK_PASS := shadow1
WARLOCK_CHARACTER := Shadowfel
WARLOCK_RACE := undead
WARLOCK_CLASS := warlock
WARLOCK_GENDER := male
# Slot map (docs/control-plane.md): 0=Botwarrior, 1=Botpriest, 2=Shadowfel.
# The control socket is 41114 + slot, so this seat answers on 127.0.0.1:41116.
# Leave WOW_SDK_NIM_CONTROL_PORT unset on BOTH sides — an explicit value is
# used verbatim and is NOT offset by the slot (nim_control_server.nim:666-673).
WARLOCK_SLOT := 2
WARLOCK_RUNTIME_DIR := $(CURDIR)/local_data/nim-runtime-slot$(WARLOCK_SLOT)

# Idempotently ensure the shadow1 account (same upstream SRP script as `account`).
warlock-account:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(WARLOCK_ACCOUNT):$(WARLOCK_ACCOUNT):$(WARLOCK_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 \
		--port 3306 \
		--db-user mangos \
		--db-password mangos \
		--apply; \
	echo "account ready: $(WARLOCK_ACCOUNT) / $(WARLOCK_PASS)"

# Bring the Shadowfel seat online. First run also creates the character.
#
# AUTONOMOUS=0 is load-bearing: a seat launched with AUTONOMOUS=1 was observed
# exiting shortly after listen. 0 parks the seat logged in and lets an external
# brain own the goal.
#
# The Detour navmesh helper IS built now (docs/navmesh.md) and this target
# inherits VANILLA_WOW_NAVMESH_HELPER from the export above, so movement is no
# longer blocked on it. Shadowfel specifically still cannot walk under a
# `leveling` goal — an undead warlock resolves `unsupported_profile`. Use
# `botwarrior-bot` for movement work until that is fixed.
#
# Foreground like `make play` / `make shadow`. Detach with:
#   nohup make warlock-bot > local_data/warlock-bot.log 2>&1 &
# Stop with: kill <pid>  (SIGTERM; the seat logs out and characters.online→0)
warlock-bot:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	mkdir -p "$(WARLOCK_RUNTIME_DIR)"; \
	cd "$(UPSTREAM)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=$(WARLOCK_ACCOUNT) \
	VANILLA_WOW_PLAYER_PASSWORD=$(WARLOCK_PASS) \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=$(WARLOCK_CHARACTER) \
	VANILLA_WOW_PLAYER_CHARACTER_RACE=$(WARLOCK_RACE) \
	VANILLA_WOW_PLAYER_CHARACTER_CLASS=$(WARLOCK_CLASS) \
	VANILLA_WOW_PLAYER_CHARACTER_GENDER=$(WARLOCK_GENDER) \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=$(WARLOCK_SLOT) \
	WOW_SDK_NIM_RUNTIME_DIR=$(WARLOCK_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# Launch the native client for HUMAN play against OUR local persistent realm.
#
# The old --login-screen/--realm-host/--realm-port/--world-port flags are gone
# from upstream's launcher (renderedSessionRoute, launch_nim_player.nim:300).
# A bare launch now means "hosted persistent-practice gateway" and dies on DNS.
# The local realm is reached by the direct-WebSocket route instead: set BOTH
# VANILLA_WOW_LOGIN_WS_URL and VANILLA_WOW_GAME_WS_URL (setting one alone is a
# hard error) and the launcher picks renderedDirectWebSockets, which also skips
# the practice grant.
#
# The bridges are the canonical /tcp/realmd:3724 + /tcp/world:8085 proxies on
# the realm's HTTP port (game/config.py:1357). Both take slot+token; the realm
# ships a single token, so only slot 0 authenticates.
#
# --username/--password are not launcher options; they fall through to the
# player runtime (launch_nim_player.nim:439, player_runtime.nim:102-103), which
# logs in and stops at CharacterSelect — no character is forced, so we still
# pick a seat by hand. Creds reuse ACCOUNT_USER/ACCOUNT_PASS (make account).
# Do not run unattended (opens a GUI).
PLAY_WS ?= ws://127.0.0.1:8080
PLAY_SLOT ?= 0
PLAY_TOKEN ?= token-0
PLAY_OWNER ?= monofuel
# Runs from OUR fork so human sessions carry the fork's client fixes
# (F9 movement-evidence logging); data env vars above still point at the
# upstream checkout's local_data.
play:
	@set -e; \
	if [ ! -d "$(FORK_CLIENT)" ]; then \
		echo "error: fork checkout missing: $(FORK_CLIENT)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	cd "$(FORK_CLIENT)"; \
	nix shell nixpkgs\#nginx --command sh -c \
		'. "$(WOW_ENV)"; \
		export VANILLA_WOW_LOGIN_WS_URL="$(PLAY_WS)/tcp/realmd?slot=$(PLAY_SLOT)&token=$(PLAY_TOKEN)"; \
		export VANILLA_WOW_GAME_WS_URL="$(PLAY_WS)/tcp/world?slot=$(PLAY_SLOT)&token=$(PLAY_TOKEN)"; \
		nim r tools/launch_nim_player.nim -- \
			--controller=human \
			--presentation=headed \
			--owner=$(PLAY_OWNER) \
			--username=$(ACCOUNT_USER) \
			--password=$(ACCOUNT_PASS) $(EXTRA)'

# Pull hosted Traverse league episodes into local_data/traverse/ for the System
# dashboard Hosted replays table (version + score + replay/obs links).
traverse-field:
	@tools/pull_traverse_field.sh

# Open the latest local traverse league replay (headed native viewer).
# Finds newest run/replay.json.z or run/history/replay-*.json.z (from pack).
# Override: TRAVERSE_REPLAY=/path TRAVERSE_REPLAY_WATCH=Northbound
traverse-replay:
	@tools/traverse_replay.sh

# Pack latest traverse godview/worldwire → run/replay.json.z (also auto on pol EXIT).
traverse-pack-replay:
	@tools/pack_traverse_replay.sh

# Petrel on the lua-bot host (docs/traverse/README.md). Headless full run.
# The wet chain runs by default: traverse/traverse-headed attempt the
# ENTIRE course (desert + swim). SWIM=0 opts out; traverse-desert and
# traverse-pol pin land-only semantics themselves.
SWIM ?=
# CHECKPOINT=<name> SOAP-teleports the character after login (local debug;
# names from `make traverse-checkpoints`). The episode realm is recreated
# per launch, so SOAP is enabled at birth and a background watcher waits
# for the traverse container before applying — it never touches the
# persistent realm. A checkpoint run is a wet run: PETREL_SWIM defaults on
# (override with SWIM=0). wet_start lands swimming; water_entry lands DRY
# on the sand (the shoreline entry is a known-open gap on the lua-bot
# host — you will see the bot work the waterline, not the ribbon).
# END_CHECKPOINT=<name> turns either launcher into a bounded segment test. It
# waits until the start tele is observed, records idle/swim/death metrics, and
# terminates the launcher successfully at 50 yd from the named endpoint.
CHECKPOINT ?=
END_CHECKPOINT ?=
END_TIMEOUT ?=2700
TRAVERSE_SEGMENT_RESULT := $(CURDIR)/local_data/traverse-segment-result.json
TRAVERSE_SWIM_EFFECTIVE = $(or $(SWIM),1)
define TRAVERSE_CHECKPOINT_PRELUDE
	if [ -n "$(END_CHECKPOINT)" ] && [ -z "$(CHECKPOINT)" ]; then \
		echo "error: END_CHECKPOINT requires CHECKPOINT" >&2; exit 2; \
	fi; \
	if [ -n "$(END_CHECKPOINT)" ]; then \
		python3 tools/traverse_checkpoint.py resolve "$(CHECKPOINT)" >/dev/null; \
		python3 tools/traverse_checkpoint.py resolve "$(END_CHECKPOINT)" >/dev/null; \
		rm -f "$(TRAVERSE_SEGMENT_RESULT)"; \
	fi; \
	if [ -n "$(CHECKPOINT)" ]; then \
		mkdir -p local_data/traverse-status; \
		rm -f local_data/lua-bot-status.json local_data/traverse-status/status.json; \
		prior_cid="$$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep -E '(traverse|race).*coworld-game' | awk '{print $$1}' | head -1)"; \
		VMANGOS_MANGOSD_CONFIG_OVERRIDES="$$(python3 tools/traverse_soap.py env)"; \
		export VMANGOS_MANGOSD_CONFIG_OVERRIDES; \
		( for _ in $$(seq 1 200); do \
			cid="$$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep -E '(traverse|race).*coworld-game' | awk '{print $$1}' | head -1)"; \
			if [ -n "$$cid" ] && [ "$$cid" != "$$prior_cid" ]; then break; fi; \
			sleep 2; \
		  done; \
		  python3 tools/traverse_checkpoint.py apply "$(CHECKPOINT)" \
			--character Northbound >> local_data/health-logs/traverse-tele.log 2>&1 ) & \
	fi
endef

define TRAVERSE_RUN
	mkdir -p "$(CURDIR)/local_data/traverse-status"; \
	if [ -n "$(END_CHECKPOINT)" ]; then \
		cd $(FORK_CLIENT); \
		PETREL_SWIM=$(TRAVERSE_SWIM_EFFECTIVE) setsid sh -c '$(TRAVERSE_LAUNCH) --presentation=$(1) 2>&1 | tee "$(CURDIR)/local_data/traverse-status/run.log"' & \
		run_pid=$$!; \
		cleanup() { \
			kill -TERM -- -$$run_pid 2>/dev/null || true; \
			wait $$run_pid 2>/dev/null || true; \
		}; \
		trap cleanup EXIT INT TERM; \
		python3 "$(CURDIR)/tools/traverse_checkpoint.py" wait \
			"$(CHECKPOINT)" "$(END_CHECKPOINT)" \
			--timeout "$(END_TIMEOUT)" \
			--result "$(TRAVERSE_SEGMENT_RESULT)"; \
		segment_rc=$$?; \
		trap - EXIT INT TERM; \
		cleanup; \
		exit $$segment_rc; \
	else \
		cd $(FORK_CLIENT) && set -o pipefail && \
		PETREL_SWIM=$(TRAVERSE_SWIM_EFFECTIVE) $(TRAVERSE_LAUNCH) --presentation=$(1) 2>&1 | \
			tee "$(CURDIR)/local_data/traverse-status/run.log"; \
	fi
endef
traverse:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	$(call TRAVERSE_RUN,headless)

# Headed Petrel run for manual verification (opens a window — human use).
traverse-headed:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	$(call TRAVERSE_RUN,headed)

# Fast regression: proof-of-life (level 60, map 1, movement + inputs).
traverse-pol:
	@cd $(FORK_CLIENT) && PETREL_SWIM=0 $(TRAVERSE_LAUNCH) --proof-of-life

# Land-leg proof: spawn → desert ocean coast (water_entry), with client CPU
# sampling for the streaming-starvation investigation. Readback at exit.
traverse-desert:
	@tools/traverse_desert.sh

# Wet lab: SOAP-tele to water_entry, swim the cheese ribbon to Dustwallow.
# Local debug only; reports best_planar_to_duskwallow_wet at exit.
traverse-wet:
	@tools/traverse_wet.sh

# List SOAP tele checkpoints (does not launch).
traverse-checkpoints:
	@python3 tools/traverse_checkpoint.py list

# Great Lift reference session: tele a seeded bot character to a lift dock
# on the 1x local realm (never a personal character). Then drive the headed
# nim client yourself with:  make play ACCOUNT_USER=bot1 ACCOUNT_PASS=bot1
# Ride up, ride down; logs land in the usual observer/journal paths.
# Override: LIFT_CHARACTER=Botpriest LIFT_CHECKPOINT=great_lift_upper
LIFT_CHARACTER ?= Botwarrior
LIFT_CHECKPOINT ?= great_lift_lower
lift-tele:
	@python3 tools/traverse_checkpoint.py apply $(LIFT_CHECKPOINT) \
		--character $(LIFT_CHARACTER) --no-wait

# Launch the GENUINE 1.12.1 client under wine against the local realm
# (see docs/play-classic.md). First run assembles local_classic/ (Data/
# symlinked from wow-classic-data, WTF/Interface copied) and inits a wine
# prefix. Login monofuel / password. Do not run unattended (opens a GUI).
play-classic:
	@nix develop --command tools/play_classic.sh

# play-classic with a loopback packet capture: realm (3724) + world (8085)
# traffic is saved to captures/play-classic-<timestamp>.pcap for offline
# protocol analysis (see docs/play-classic.md). Capture needs CAP_NET_RAW,
# so sudo prompts once up front. Do not run unattended (opens a GUI).
play-classic-netlog:
	@nix develop --command tools/play_classic_netlog.sh

# Launch the native client from the XR fork checkout in VR (OpenXR PoC,
# branch monofuel/xr). Quick play on purpose: no --login-screen, so the
# launcher drops straight into the world with the local-realm credentials.
# --xr makes the launcher build the player with -d:xr (stereo OpenXR path;
# SteamVR must be running, otherwise the client falls back to flat). The
# xr library links with -lopenxr_loader, which wow_env.sh does not carry,
# so the recipe puts nixpkgs#openxr-loader on LIBRARY_PATH — the nix gcc
# wrapper turns that into -L plus a baked RUNPATH for runtime resolution.
# libuuid + vulkan-loader ride along on LD_LIBRARY_PATH because the OpenXR
# loader dlopens SteamVR's vrclient.so, which needs both (verified via ldd;
# same set as the xr repo flake's shellHook).
# --http-port/--ws-port are pinned below the kernel ephemeral range
# (32768-60999): the launcher default 44590 lives inside it, so any outgoing
# TCP connection can transiently squat the port and fail the launch with
# "already in use by a process this checkout does not own".
# Do not run unattended (opens a GUI).
XR_FORK := $(abspath ../coworld-vanilla-wow-xr)
play-xr:
	@set -e; \
	if [ ! -d "$(XR_FORK)" ]; then \
		echo "error: xr fork checkout missing: $(XR_FORK)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	if [ ! -e "$(XR_FORK)/local_data/coworld-bundle" ] && \
			[ -d "$(UPSTREAM)/local_data/coworld-bundle" ]; then \
		mkdir -p "$(XR_FORK)/local_data"; \
		ln -sfn "$(UPSTREAM)/local_data/coworld-bundle" \
			"$(XR_FORK)/local_data/coworld-bundle"; \
		echo "linked client bundle from upstream local_data (read-only source)"; \
	fi; \
	cd "$(XR_FORK)"; \
	nix shell nixpkgs\#nginx --command sh -c \
		'. "$(WOW_ENV)"; \
		xrlibs=""; \
		for p in $$(nix build --no-link --print-out-paths \
				nixpkgs#openxr-loader nixpkgs#util-linux.lib \
				nixpkgs#vulkan-loader); do \
			xrlibs="$$p/lib$${xrlibs:+:$$xrlibs}"; \
		done; \
		export LIBRARY_PATH="$$xrlibs$${LIBRARY_PATH:+:$$LIBRARY_PATH}"; \
		export LD_LIBRARY_PATH="$$xrlibs$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"; \
		nim r tools/launch_nim_player.nim -- \
			--realm-host=127.0.0.1 \
			--realm-port=3724 \
			--world-port=8085 \
			--http-port=18590 \
			--ws-port=18591 \
			--xr'

# ---------------------------------------------------------------------------
# Igris — testbed UNDEAD WARLOCK for the indoor-navigation fix
# (docs/indoor-navigation-plan.md). Identical seat pattern to warlock-bot,
# except the reference player runs from OUR FORK worktree (branch
# indoor-wmo-navigation) against the stock realm — so the patched client can
# be A/B'd (fork main = baseline, fix branch = patched) without touching the
# upstream checkout or the realm image. Character auto-creates over the wire
# on first login (CMSG_CHAR_CREATE), spawning in the Shadow Grave crypt —
# the indoor-nav reproduce case.
IGRIS_ACCOUNT := shadow2
IGRIS_PASS := shadow2
IGRIS_CHARACTER := Igris
IGRIS_RACE := undead
IGRIS_CLASS := warlock
IGRIS_GENDER := male
# Slot map (docs/control-plane.md): 0=Botwarrior, 1=Botpriest, 2=Shadowfel,
# 3=Igris. Control socket 41114 + slot = 127.0.0.1:41117.
IGRIS_SLOT := 3
IGRIS_RUNTIME_DIR := $(CURDIR)/local_data/nim-runtime-slot$(IGRIS_SLOT)

.PHONY: igris-account igris-bot
igris-account:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(IGRIS_ACCOUNT):$(IGRIS_ACCOUNT):$(IGRIS_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 \
		--port 3306 \
		--db-user mangos \
		--db-password mangos \
		--apply; \
	echo "account ready: $(IGRIS_ACCOUNT) / $(IGRIS_PASS)"

# Foreground. Detach with:
#   nohup make igris-bot > local_data/igris-bot.log 2>&1 &
# Ready at: "Nim binary control socket listening on 127.0.0.1:41117."
igris-bot:
	@set -e; \
	if [ ! -d "$(FORK)" ]; then \
		echo "error: fork checkout missing: $(FORK) (see docs/coworld-fork.md)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	mkdir -p "$(IGRIS_RUNTIME_DIR)"; \
	cd "$(FORK)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=$(IGRIS_ACCOUNT) \
	VANILLA_WOW_PLAYER_PASSWORD=$(IGRIS_PASS) \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=$(IGRIS_CHARACTER) \
	VANILLA_WOW_PLAYER_CHARACTER_RACE=$(IGRIS_RACE) \
	VANILLA_WOW_PLAYER_CHARACTER_CLASS=$(IGRIS_CLASS) \
	VANILLA_WOW_PLAYER_CHARACTER_GENDER=$(IGRIS_GENDER) \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=$(IGRIS_SLOT) \
	WOW_SDK_NIM_RUNTIME_DIR=$(IGRIS_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# Shadowfel on the FORK build (same env tuple as warlock-bot, cd FORK) —
# for play sessions that need fork-carried client fixes on both seats
# (e.g. party-invite-observation). Stock target remains `warlock-bot`.
.PHONY: warlock-bot-fork
warlock-bot-fork:
	@set -e; \
	if [ ! -d "$(FORK)" ]; then \
		echo "error: fork checkout missing: $(FORK)" >&2; exit 1; \
	fi; \
	mkdir -p "$(WARLOCK_RUNTIME_DIR)"; \
	cd "$(FORK)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=$(WARLOCK_ACCOUNT) \
	VANILLA_WOW_PLAYER_PASSWORD=$(WARLOCK_PASS) \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=$(WARLOCK_CHARACTER) \
	VANILLA_WOW_PLAYER_CHARACTER_RACE=$(WARLOCK_RACE) \
	VANILLA_WOW_PLAYER_CHARACTER_CLASS=$(WARLOCK_CLASS) \
	VANILLA_WOW_PLAYER_CHARACTER_GENDER=$(WARLOCK_GENDER) \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=$(WARLOCK_SLOT) \
	WOW_SDK_NIM_RUNTIME_DIR=$(WARLOCK_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# ---------------------------------------------------------------------------
# Tusk — undead WARRIOR (tank) for the 5-man cast (docs/personas/tusk.md).
# Same wire-create seat pattern as Igris/Shadowfel. Slot 4 → :41118.
TUSK_ACCOUNT := shadow3
TUSK_PASS := shadow3
TUSK_CHARACTER := Tusk
TUSK_RACE := undead
TUSK_CLASS := warrior
TUSK_GENDER := male
TUSK_SLOT := 4
TUSK_RUNTIME_DIR := $(CURDIR)/local_data/nim-runtime-slot$(TUSK_SLOT)

tusk-account:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(TUSK_ACCOUNT):$(TUSK_ACCOUNT):$(TUSK_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 \
		--port 3306 \
		--db-user mangos \
		--db-password mangos \
		--apply; \
	echo "account ready: $(TUSK_ACCOUNT) / $(TUSK_PASS)"

# Foreground. Detach with:
#   nohup make tusk-bot > local_data/tusk-bot.log 2>&1 &
# Ready at: "Nim binary control socket listening on 127.0.0.1:41118."
tusk-bot:
	@set -e; \
	if [ ! -d "$(FORK)" ]; then \
		echo "error: fork checkout missing: $(FORK) (see docs/coworld-fork.md)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	mkdir -p "$(TUSK_RUNTIME_DIR)"; \
	cd "$(FORK)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=$(TUSK_ACCOUNT) \
	VANILLA_WOW_PLAYER_PASSWORD=$(TUSK_PASS) \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=$(TUSK_CHARACTER) \
	VANILLA_WOW_PLAYER_CHARACTER_RACE=$(TUSK_RACE) \
	VANILLA_WOW_PLAYER_CHARACTER_CLASS=$(TUSK_CLASS) \
	VANILLA_WOW_PLAYER_CHARACTER_GENDER=$(TUSK_GENDER) \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=$(TUSK_SLOT) \
	WOW_SDK_NIM_RUNTIME_DIR=$(TUSK_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# ---------------------------------------------------------------------------
# Beru — undead PRIEST (healer) for the 5-man cast (docs/personas/beru.md).
# Same wire-create seat pattern. Slot 5 → :41119.
BERU_ACCOUNT := shadow4
BERU_PASS := shadow4
BERU_CHARACTER := Beru
BERU_RACE := undead
BERU_CLASS := priest
BERU_GENDER := male
BERU_SLOT := 5
BERU_RUNTIME_DIR := $(CURDIR)/local_data/nim-runtime-slot$(BERU_SLOT)

beru-account:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	cid=$$(docker compose -f "$(COMPOSE_FILE)" --profile coworld ps -q coworld-game); \
	if [ -z "$$cid" ]; then \
		echo "error: coworld-game is not running; make start-server first" >&2; exit 1; \
	fi; \
	uv run python server/scripts/manage_coworld_accounts.py \
		--entrant "$(BERU_ACCOUNT):$(BERU_ACCOUNT):$(BERU_PASS)" \
		--mysql-container "$$cid" \
		--host 127.0.0.1 \
		--port 3306 \
		--db-user mangos \
		--db-password mangos \
		--apply; \
	echo "account ready: $(BERU_ACCOUNT) / $(BERU_PASS)"

# Foreground. Detach with:
#   nohup make beru-bot > local_data/beru-bot.log 2>&1 &
# Ready at: "Nim binary control socket listening on 127.0.0.1:41119."
beru-bot:
	@set -e; \
	if [ ! -d "$(FORK)" ]; then \
		echo "error: fork checkout missing: $(FORK) (see docs/coworld-fork.md)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	mkdir -p "$(BERU_RUNTIME_DIR)"; \
	cd "$(FORK)"; \
	. "$(WOW_ENV)"; \
	VANILLA_WOW_PLAYER_REALM_HOST=127.0.0.1 \
	VANILLA_WOW_PLAYER_REALM_PORT=3724 \
	VANILLA_WOW_PLAYER_USERNAME=$(BERU_ACCOUNT) \
	VANILLA_WOW_PLAYER_PASSWORD=$(BERU_PASS) \
	VANILLA_WOW_PLAYER_CHARACTER_NAME=$(BERU_CHARACTER) \
	VANILLA_WOW_PLAYER_CHARACTER_RACE=$(BERU_RACE) \
	VANILLA_WOW_PLAYER_CHARACTER_CLASS=$(BERU_CLASS) \
	VANILLA_WOW_PLAYER_CHARACTER_GENDER=$(BERU_GENDER) \
	VANILLA_WOW_PLAYER_AUTONOMOUS=0 \
	WOW_SDK_NIM_RUNTIME_SLOT=$(BERU_SLOT) \
	WOW_SDK_NIM_RUNTIME_DIR=$(BERU_RUNTIME_DIR) \
	WOW_SDK_NIM_CONTROL_HOST=127.0.0.1 \
	nim r player/reference_player/reference_player.nim --scenario=nim-control

# Rotate non-empty client/brain logs so restarts never clobber fair-play proof.
# Creates local_data/audit/ for army_host fair-play JSONL.
.PHONY: rotate-client-logs
rotate-client-logs:
	@mkdir -p "$(CURDIR)/local_data" "$(CURDIR)/local_data/brain-logs" "$(CURDIR)/local_data/audit"
	@ts=$$(date -u +%Y%m%dT%H%M%SZ); \
	for f in warlock-bot igris-bot tusk-bot beru-bot murist-bot botwarrior-bot; do \
		p="$(CURDIR)/local_data/$$f.log"; \
		if [ -s "$$p" ]; then mv "$$p" "$$p.$$ts"; echo "rotated $$f.log → $$f.log.$$ts"; fi; \
	done; \
	for p in "$(CURDIR)"/local_data/brain-logs/army-slot{2,3,4,5}.log \
	         "$(CURDIR)"/local_data/brain-logs/grind-slot{2,3,4,5}.log; do \
		if [ -s "$$p" ]; then mv "$$p" "$$p.$$ts"; echo "rotated $$(basename $$p)"; fi; \
	done

# Bring the full 5-man bot side online (accounts if needed + 4 headless seats).
# Human (Murist) is still classic client. Does NOT start escort brains —
# run `make escort-army` after seats print "listening".
# Client logs are rotated first (append-only history for fair-play greps).
party-army: rotate-client-logs
	@set -e; \
	$(MAKE) tusk-account; \
	$(MAKE) beru-account; \
	mkdir -p "$(CURDIR)/local_data/brain-logs" "$(CURDIR)/local_data/audit"; \
	echo "starting headless seats (fork): Shadowfel:2 Igris:3 Tusk:4 Beru:5"; \
	nohup $(MAKE) warlock-bot-fork > local_data/warlock-bot.log 2>&1 & echo $$! > local_data/brain-logs/warlock-bot.pid; \
	nohup $(MAKE) igris-bot > local_data/igris-bot.log 2>&1 & echo $$! > local_data/brain-logs/igris-bot.pid; \
	nohup $(MAKE) tusk-bot > local_data/tusk-bot.log 2>&1 & echo $$! > local_data/brain-logs/tusk-bot.pid; \
	nohup $(MAKE) beru-bot > local_data/beru-bot.log 2>&1 & echo $$! > local_data/brain-logs/beru-bot.pid; \
	echo "bot pids: $$(cat local_data/brain-logs/warlock-bot.pid) $$(cat local_data/brain-logs/igris-bot.pid) $$(cat local_data/brain-logs/tusk-bot.pid) $$(cat local_data/brain-logs/beru-bot.pid)"; \
	echo "wait for :41116–:41119 listening, then: make escort-army"; \
	echo "fair-play audit: local_data/audit/fair-play.jsonl (written by army_host)"; \
	echo "invite order in-game (Murist): Shadowfel, Igris, Tusk, Beru"

# ---------------------------------------------------------------------------
# Our fork of coworld-vanilla-wow (docs/coworld-fork.md): thin rebase layer
# carrying the SMSG_SET_FACTION_STANDING crash fix. Builds the three
# shadow-army-tagged images serially (each can saturate the box). Never
# touches the stock :local tags or the running realm — switch-over is a
# human-run retag, see docs/coworld-fork.md.
FORK := $(abspath ../monofuel-vanilla-wow)
.PHONY: fork-images
fork-images:
	@set -e; \
	if [ ! -d "$(FORK)" ]; then \
		echo "error: fork checkout missing: $(FORK) (see docs/coworld-fork.md)" >&2; exit 1; \
	fi; \
	cd "$(FORK)"; \
	docker build -f infra/docker/vmangos/Dockerfile.native \
		--target vmangos_native_runtime \
		-t coworld-vmangos-native-runtime:shadow-army .; \
	docker build -f player/Dockerfile --ssh default \
		--target reference_player_runtime_artifact \
		-t coworld-reference-player-runtime:shadow-army .; \
	docker build -f infra/docker/vmangos/Dockerfile --ssh default \
		--build-arg COWORLD_NIM_PARALLEL_BUILD=8 \
		--build-context vmangos_native_runtime=docker-image://coworld-vmangos-native-runtime:shadow-army \
		--build-context reference_player_runtime=docker-image://coworld-reference-player-runtime:shadow-army \
		-t coworld-vmangos:shadow-army .; \
	echo ""; \
	echo "shadow-army images built. Switch-over is human-run: docs/coworld-fork.md"
