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
# Hosted league is still "accelerated"; local launcher profile is ten-x.
LUA_BOT_LAUNCH = nix develop $(FORK_CLIENT) --command \
	nim r tools/launch_nim_player.nim -- --league=ten-x \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=$(ENTRY)
# Same host, traverse league: Petrel runs as lua/entry/traverse.lua.
TRAVERSE_LAUNCH = nix develop $(FORK_CLIENT) --command \
	nim r tools/launch_nim_player.nim -- --league=traverse \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=traverse

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

# Persistent-home bot runtime. All four seats connect to the already-running
# local realm through its direct WebSocket bridges; starting the realm never
# starts the bots. Each seat owns a separate observer/status directory so The
# System and operators can inspect liveness without the retired TCP control
# sockets.
HOME_WS ?= ws://127.0.0.1:8080
HOME_SLOT ?= 0
HOME_TOKEN ?= token-0
HOME_ENTRY ?= home
HOME_ARMY_DIR := $(CURDIR)/local_data/home-army
HOME_STATUS_MAX_AGE ?= 30

define launch_home_seat
	@set -e; \
	seat_dir="$(HOME_ARMY_DIR)/$(1)"; \
	mkdir -p "$$seat_dir/status" "$$seat_dir/observer"; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_LOGIN_WS_URL="$(HOME_WS)/tcp/realmd?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_GAME_WS_URL="$(HOME_WS)/tcp/world?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	COWORLD_PLAYER_OBSERVER_DIR="$$seat_dir/observer" \
	nix develop --command nim r tools/launch_nim_player.nim -- \
		--controller=embedded --presentation=headless --bot=lua-bot \
		--owner=home-$(1) \
		--lua-repo="$(CURDIR)" --lua-entry="$(HOME_ENTRY)" \
		--lua-status-dir="$$seat_dir/status" \
		--username="$(2)" --password="$(3)" --character-name="$(1)" \
		--skip-cinematic
endef

define start_home_seat
	@set -e; \
	seat_dir="$(HOME_ARMY_DIR)/$(1)"; \
	pid_file="$$seat_dir/launcher.pid"; \
	mkdir -p "$$seat_dir"; \
	if [ -s "$$pid_file" ]; then \
		pid=$$(cat "$$pid_file"); \
		if kill -0 "$$pid" 2>/dev/null; then \
			echo "$(1) already running (pid $$pid)"; exit 0; \
		fi; \
	fi; \
	rm -f "$$pid_file" "$$seat_dir/status/status.json"; \
	if [ -s "$$seat_dir/launcher.log" ]; then \
		mv "$$seat_dir/launcher.log" "$$seat_dir/launcher.log.$$(date -u +%Y%m%dT%H%M%SZ)"; \
	fi; \
	setsid $(MAKE) --no-print-directory $(2) >"$$seat_dir/launcher.log" 2>&1 < /dev/null & \
	pid=$$!; echo "$$pid" > "$$pid_file"; \
	echo "starting $(1) (pid $$pid; log $$seat_dir/launcher.log)"
endef

define stop_home_seat
	@set -e; \
	seat_dir="$(HOME_ARMY_DIR)/$(1)"; \
	pid_file="$$seat_dir/launcher.pid"; \
	if [ ! -s "$$pid_file" ]; then echo "$(1) is stopped"; exit 0; fi; \
	pid=$$(cat "$$pid_file"); \
	if ! kill -0 "$$pid" 2>/dev/null; then \
		rm -f "$$pid_file"; echo "$(1) is stopped (removed stale pid)"; exit 0; \
	fi; \
	kill -TERM -- "-$$pid" 2>/dev/null || kill -TERM "$$pid"; \
	i=0; while kill -0 "$$pid" 2>/dev/null && [ $$i -lt 30 ]; do sleep 0.5; i=$$((i + 1)); done; \
	if kill -0 "$$pid" 2>/dev/null; then \
		echo "error: $(1) did not stop after 15 seconds (pid $$pid)" >&2; exit 1; \
	fi; \
	rm -f "$$pid_file"; echo "stopped $(1)"
endef

.PHONY: test test-lua test-nim system pin-check start-server stop-server server-logging logs account soap-account play play-classic play-classic-netlog play-xr traverse traverse-field traverse-replay traverse-pack-replay traverse-headed traverse-pol traverse-desert traverse-wet traverse-checkpoints lift-tele quest-data warlock-account warlock-bot botwarrior-bot tusk-account tusk-bot beru-account beru-bot party-army home-army-start home-army-stop home-army-restart home-army-status shadowfel-start shadowfel-stop igris-start igris-stop tusk-start tusk-stop beru-start beru-stop navmesh-helper navmesh-status map-browser map-browser-once map-browser-debug map-browser-probe

# Unit tier: Lua tools + Nim host/system tests only (v2 DoD: no Python required
# for bot correctness). If nim is missing, test-nim-soft skips rather than
# failing bare CI hosts. Smoke tier parse/compile-checks code no unit test
# executes (including addon Lua) — doctrine: a cheap compile-check is a
# legitimate leg for a binary with no unit tests yet.
test: test-lua test-nim-soft test-smoke test-traverse-soap test-traverse-checkpoint

.PHONY: test-traverse-soap test-traverse-checkpoint
test-traverse-soap:
	@python3 tools/tests/test_traverse_soap.py
test-traverse-checkpoint:
	@python3 tools/tests/test_traverse_checkpoint.py

# Every maintained Nim entrypoint/module must at least compile (`nim check`),
# even where no unit suite imports it yet.
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

EXTRA ?=
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

# ---------------------------------------------------------------------------
# Peregrine: hosted Accelerated policy image (rendered lua-bot + this lua/).
# Base binary from monofuel-vanilla-wow target lua_bot_player_runtime; this
# worktree only bakes lua/ and locks --lua-entry=accelerated.
# Does NOT upload or submit — see playbooks/upload-bot.md.
# ---------------------------------------------------------------------------
LUA_BOT_PLAYER_IMAGE ?= coworld-lua-bot-player:latest
PEREGRINE_IMAGE ?= peregrine:latest
.PHONY: lua-bot-player-image peregrine-image
lua-bot-player-image:
	@set -e; \
	if [ ! -d "$(FORK_CLIENT)" ]; then \
		echo "error: fork checkout missing: $(FORK_CLIENT)" >&2; exit 1; \
	fi; \
	cd "$(FORK_CLIENT)"; \
	docker build --platform linux/amd64 --ssh default \
		-f player/Dockerfile \
		--target lua_bot_player_runtime \
		-t $(LUA_BOT_PLAYER_IMAGE) .; \
	test "$$(docker image inspect $(LUA_BOT_PLAYER_IMAGE) --format '{{.Architecture}}')" = amd64

peregrine-image: lua-bot-player-image
	@set -e; \
	docker build --platform linux/amd64 \
		-f Dockerfile.peregrine \
		--build-arg LUA_BOT_PLAYER_IMAGE=$(LUA_BOT_PLAYER_IMAGE) \
		-t $(PEREGRINE_IMAGE) .; \
	test "$$(docker image inspect $(PEREGRINE_IMAGE) --format '{{.Architecture}}')" = amd64; \
	echo "built $(PEREGRINE_IMAGE) (policy name: peregrine)"

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
# The account and character already live in the persistent realm; account
# creation and bot launch remain separate explicit operations.
WARLOCK_ACCOUNT := shadow1
WARLOCK_PASS := shadow1
WARLOCK_CHARACTER := Shadowfel
WARLOCK_RACE := undead
WARLOCK_CLASS := warlock
WARLOCK_GENDER := male

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

# Run Shadowfel's embedded home policy in the foreground. The detached
# operator surface is `make shadowfel-start` / `make shadowfel-stop`.
warlock-bot:
	$(call launch_home_seat,$(WARLOCK_CHARACTER),$(WARLOCK_ACCOUNT),$(WARLOCK_PASS))

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
CHECKPOINT ?=
TRAVERSE_SWIM_EFFECTIVE = $(or $(SWIM),1)
define TRAVERSE_CHECKPOINT_PRELUDE
	if [ -n "$(CHECKPOINT)" ]; then \
		rm -f local_data/lua-bot-status.json; \
		prior_cid="$$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep 'traverse.*coworld-game' | awk '{print $$1}' | head -1)"; \
		VMANGOS_MANGOSD_CONFIG_OVERRIDES="$$(python3 tools/traverse_soap.py env)"; \
		export VMANGOS_MANGOSD_CONFIG_OVERRIDES; \
		( for _ in $$(seq 1 200); do \
			cid="$$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep 'traverse.*coworld-game' | awk '{print $$1}' | head -1)"; \
			if [ -n "$$cid" ] && [ "$$cid" != "$$prior_cid" ]; then break; fi; \
			sleep 2; \
		  done; \
		  python3 tools/traverse_checkpoint.py apply "$(CHECKPOINT)" \
			--character Northbound >> local_data/health-logs/traverse-tele.log 2>&1 ) & \
	fi
endef
traverse:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	cd $(FORK_CLIENT) && PETREL_SWIM=$(TRAVERSE_SWIM_EFFECTIVE) $(TRAVERSE_LAUNCH) --presentation=headless

# Headed Petrel run for manual verification (opens a window — human use).
traverse-headed:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	cd $(FORK_CLIENT) && PETREL_SWIM=$(TRAVERSE_SWIM_EFFECTIVE) $(TRAVERSE_LAUNCH) --presentation=headed

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
# Igris — undead warlock DPS seat.
IGRIS_ACCOUNT := shadow2
IGRIS_PASS := shadow2
IGRIS_CHARACTER := Igris
IGRIS_RACE := undead
IGRIS_CLASS := warlock
IGRIS_GENDER := male

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

# Run Igris's embedded home policy in the foreground.
igris-bot:
	$(call launch_home_seat,$(IGRIS_CHARACTER),$(IGRIS_ACCOUNT),$(IGRIS_PASS))

# Compatibility alias: every home bot now runs from the fork.
.PHONY: warlock-bot-fork
warlock-bot-fork: warlock-bot

# ---------------------------------------------------------------------------
# Tusk — undead WARRIOR (tank) for the 5-man cast (docs/personas/tusk.md).
TUSK_ACCOUNT := shadow3
TUSK_PASS := shadow3
TUSK_CHARACTER := Tusk
TUSK_RACE := undead
TUSK_CLASS := warrior
TUSK_GENDER := male

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

# Run Tusk's embedded home policy in the foreground.
tusk-bot:
	$(call launch_home_seat,$(TUSK_CHARACTER),$(TUSK_ACCOUNT),$(TUSK_PASS))

# ---------------------------------------------------------------------------
# Beru — undead PRIEST (healer) for the 5-man cast (docs/personas/beru.md).
BERU_ACCOUNT := shadow4
BERU_PASS := shadow4
BERU_CHARACTER := Beru
BERU_RACE := undead
BERU_CLASS := priest
BERU_GENDER := male

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

# Run Beru's embedded home policy in the foreground.
beru-bot:
	$(call launch_home_seat,$(BERU_CHARACTER),$(BERU_ACCOUNT),$(BERU_PASS))

# Explicit bot lifecycle. These targets do not start or stop the persistent
# realm and do not create accounts; character/server state stays untouched.
shadowfel-start:
	$(call start_home_seat,$(WARLOCK_CHARACTER),warlock-bot)
igris-start:
	$(call start_home_seat,$(IGRIS_CHARACTER),igris-bot)
tusk-start:
	$(call start_home_seat,$(TUSK_CHARACTER),tusk-bot)
beru-start:
	$(call start_home_seat,$(BERU_CHARACTER),beru-bot)

shadowfel-stop:
	$(call stop_home_seat,$(WARLOCK_CHARACTER))
igris-stop:
	$(call stop_home_seat,$(IGRIS_CHARACTER))
tusk-stop:
	$(call stop_home_seat,$(TUSK_CHARACTER))
beru-stop:
	$(call stop_home_seat,$(BERU_CHARACTER))

home-army-start: shadowfel-start igris-start tusk-start beru-start
	@echo "home army requested; use 'make home-army-status' while clients connect"

home-army-stop: beru-stop tusk-stop igris-stop shadowfel-stop

home-army-restart: home-army-stop home-army-start

home-army-status:
	@now=$$(date +%s); \
	for seat in $(WARLOCK_CHARACTER) $(IGRIS_CHARACTER) $(TUSK_CHARACTER) $(BERU_CHARACTER); do \
		seat_dir="$(HOME_ARMY_DIR)/$$seat"; pid_file="$$seat_dir/launcher.pid"; status_file="$$seat_dir/status/status.json"; \
		state=stopped; detail=""; \
		if [ -s "$$pid_file" ]; then \
			pid=$$(cat "$$pid_file"); \
			if kill -0 "$$pid" 2>/dev/null; then state=starting; detail="pid=$$pid"; \
			else detail="stale_pid=$$pid"; fi; \
		fi; \
		if [ "$$state" = starting ] && [ -s "$$status_file" ]; then \
			age=$$((now - $$(stat -c %Y "$$status_file"))); \
			if [ $$age -le $(HOME_STATUS_MAX_AGE) ]; then \
				state=running; mode=$$(jq -r '.bot.mode // "unknown"' "$$status_file" 2>/dev/null || echo unreadable); \
				detail="$$detail mode=$$mode status_age=$${age}s"; \
			else detail="$$detail stale_status=$${age}s"; fi; \
		fi; \
		printf '%-10s %-8s %s\n' "$$seat" "$$state" "$$detail"; \
	done

# Compatibility name retained for operators and The System.
party-army: home-army-start

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
