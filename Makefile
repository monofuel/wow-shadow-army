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
# League policy entries (lua/entry/<module>.lua). Peregrine (ten-x) and
# Raven (persistent) run the deployed leveler with quests off; Petrel (race)
# runs the deployed traverse brain, whose route tables are local inputs under
# lua/config/petrel/. Override to run another entry (accelerated, traverse,
# home) through the same league launch.
ENTRY ?= peregrine
PERSISTENT_ENTRY ?= $(ENTRY)
TRAVERSE_ENTRY ?= petrel
# League launches (ten-x, persistent, race) run the fork launcher, which
# provisions its own league realm. Home-realm and session overrides from this
# Makefile or the calling shell are scrubbed so they cannot steer that realm
# (the root health check list plus the home debug port, eval slot and SOAP
# config override), and the extracted data is the current
# side-by-side install rather than the home realm's data directory.
# CHECKPOINT runs keep the SOAP config override their prelude exports.
LEAGUE_DATA_DIR ?= $(CURDIR)/local_data/vmangos-5875-data-current
LEAGUE_DATA = $(realpath $(LEAGUE_DATA_DIR))
NATIVE_LAUNCH_UNSET = VMANGOS_DB_DIR VMANGOS_MYSQL_DUMPS_DIR \
	VMANGOS_MIGRATION_BACKUP_DIR VMANGOS_CAPTURES_DIR COWORLD_CONFIG_DIR \
	COWORLD_RUN_DIR COWORLD_RECORD_DIR VANILLA_WOW_LOGIN_WS_URL \
	VANILLA_WOW_GAME_WS_URL COWORLD_PLAYER_WS_URL WOW_SDK_NIM_RUNTIME_DIR \
	VANILLA_WOW_NAVMESH_HELPER VMANGOS_IMAGE VMANGOS_NATIVE_IMAGE \
	COWORLD_VMANGOS_FEATURES COMPOSE_PROJECT_NAME COMPOSE_FILE \
	VMANGOS_COMPOSE_FILE VANILLA_WOW_LUA_DEBUG_DIR COWORLD_EVAL_SLOT \
	$(if $(CHECKPOINT),,VMANGOS_MANGOSD_CONFIG_OVERRIDES)
NATIVE_LAUNCH = $(if $(and $(wildcard $(LEAGUE_DATA)/dbc/.),$(wildcard $(LEAGUE_DATA)/mmaps/.)),,$(error league data dir is not an extracted-data install (needs dbc/ and mmaps/): $(LEAGUE_DATA_DIR))) \
	$(if $(findstring /vmangos-db/,$(abspath $(LEAGUE_DATA_DIR))/ $(LEAGUE_DATA)/),$(error refusing league data inside vmangos-db: $(LEAGUE_DATA_DIR))) \
	env $(addprefix -u ,$(NATIVE_LAUNCH_UNSET)) \
	VANILLA_WOW_EXTRACTED_DATA_DIR=$(LEAGUE_DATA) \
	nix develop $(FORK_CLIENT) --command nim r tools/launch_nim_player.nim --
# $(call <X>_LAUNCH,<options>): lua-bot options and the call argument (e.g.
# --presentation or --proof-of-life) are launcher options; the character a
# league creates follows the second `--` as ordinary player options. The race
# league keeps its premade character, so TRAVERSE_LAUNCH creates none and
# targets append launcher options to it directly.
# Hosted Accelerated is "accelerated"; local 10x launcher profile is ten-x.
PEREGRINE_CHARACTER = --create-character-name=Peregrine \
	--create-character-race=tauren --create-character-class=druid \
	--create-character-gender=male
RAVEN_CHARACTER = --create-character-name=Raven \
	--create-character-race=undead --create-character-class=warlock \
	--create-character-gender=male
LUA_BOT_LAUNCH = $(NATIVE_LAUNCH) --league=ten-x \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=$(ENTRY) \
	--lua-status-dir=$(CURDIR)/local_data/accelerated-status $(1) \
	-- $(PEREGRINE_CHARACTER)
# Persistent league local proof / smoke (1x durable profile).
PERSISTENT_LAUNCH = $(NATIVE_LAUNCH) --league=persistent \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=$(PERSISTENT_ENTRY) \
	--lua-status-dir=$(CURDIR)/local_data/persistent-status $(1) \
	-- $(RAVEN_CHARACTER)
# Same host, traverse league: Petrel runs as lua/entry/petrel.lua.
# Upstream renamed the leagues in the hosted-session protocol update
# (2026-08-10): traverse -> race (same kalimdor_traversal scenario).
TRAVERSE_LAUNCH = $(NATIVE_LAUNCH) --league=race \
	--bot=lua-bot --lua-repo=$(CURDIR) --lua-entry=$(TRAVERSE_ENTRY) \
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
# Every seat start runs this after its live-pid guard: it rotates launcher.log
# and keeps the stopped client's heartbeats, status and runtime manifest under
# one rotation id before anything is deleted or rewritten.
RETAIN_SEAT_RUNTIME := $(CURDIR)/tools/retain_seat_runtime.sh
HOME_STATUS_MAX_AGE ?= 30

# Live Lua debug port for home seats (docs/lua-debug-port.md, ticket 0053).
# EMPTY = OFF, and off means the seat env carries no control dir and no admin
# process exists — the feature is absent, not idle. HOME LANE ONLY: league,
# traverse, and every hosted policy image must never set this.
#
#   make home-army-start HOME_DEBUG_PORT_BASE=7788
#
# Ports are base + seat index: shadowfel 7788, igris 7789, tusk 7790,
# beru 7791. A seat reads its control dir from the environment AT LAUNCH, so a
# already-running seat gains nothing until its next restart.
HOME_DEBUG_PORT_BASE ?=

# Home seats log in to EXISTING characters only: the realm must already hold
# exactly that name on that account with that class
# (tools/private_seat_identity.sh), character creation stays off, the client
# runs unheaded (no window, display, GPU or renderer), and its geometry comes
# from the same current extracted-data install as make play. Like make play,
# it runs in this repo's dev shell: the fork's pinned Nim and Lua prefix plus
# the nginx the local asset path needs.
HOME_SEAT_PREFLIGHT = \
	if [ ! -d "$(LEAGUE_DATA)/dbc" ] || [ ! -d "$(LEAGUE_DATA)/mmaps" ]; then \
		echo "error: extracted client data missing (needs dbc/ and mmaps/): $(LEAGUE_DATA_DIR)" >&2; exit 1; \
	fi; \
	$(MAKE) --no-print-directory home-assets-ready; \
	"$(CURDIR)/tools/private_seat_identity.sh"
define launch_home_seat
	@set -e; \
	$(HOME_SEAT_PREFLIGHT) "$(1)" "$(2)" "$(4)"; \
	seat_dir="$(HOME_ARMY_DIR)/$(1)"; \
	mkdir -p "$$seat_dir/status" "$$seat_dir/observer"; \
	debug_dir=""; \
	if [ -n "$(HOME_DEBUG_PORT_BASE)" ]; then \
		debug_dir="$$seat_dir/control"; mkdir -p "$$debug_dir/acks"; \
	fi; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_LOGIN_WS_URL="$(HOME_WS)/tcp/realmd?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_GAME_WS_URL="$(HOME_WS)/tcp/world?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_LUA_DEBUG_DIR="$$debug_dir" \
	VANILLA_WOW_PLAYER_CHARACTER_CREATION=0 \
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(LEAGUE_DATA)" \
	SHADOW_SEAT_DIR="$$seat_dir" \
	COWORLD_PLAYER_OBSERVER_DIR="$$seat_dir/observer" \
	nix develop "$(CURDIR)" --command nim r tools/launch_nim_player.nim -- \
		--controller=embedded --presentation=unheaded --bot=lua-bot \
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
	$(RETAIN_SEAT_RUNTIME) "$$seat_dir"; \
	rm -f "$$pid_file" "$$seat_dir/status/status.json" "$$seat_dir/control/request.json"; \
	setsid $(MAKE) --no-print-directory $(2) >"$$seat_dir/launcher.log" 2>&1 < /dev/null & \
	pid=$$!; echo "$$pid" > "$$pid_file"; \
	echo "starting $(1) (pid $$pid; log $$seat_dir/launcher.log)"; \
	if [ -n "$(HOME_DEBUG_PORT_BASE)" ]; then \
		port=$$(($(HOME_DEBUG_PORT_BASE) + $(3))); \
		admin_pid="$$seat_dir/lua-debug-admin.pid"; \
		mkdir -p "$$seat_dir/control/acks"; \
		if [ -s "$$admin_pid" ] && kill -0 "$$(cat $$admin_pid)" 2>/dev/null; then \
			echo "  debug admin already running (pid $$(cat $$admin_pid))"; \
		else \
			setsid nix develop --command nim r tools/lua_debug_admin.nim -- \
				--seat="$(1)" --port="$$port" \
				--control-dir="$$seat_dir/control" \
				--status-dir="$$seat_dir/status" \
				>"$$seat_dir/lua-debug-admin.log" 2>&1 < /dev/null & \
			echo "$$!" > "$$admin_pid"; \
			echo "  debug port http://127.0.0.1:$$port (log $$seat_dir/lua-debug-admin.log)"; \
		fi; \
	fi
endef

# Stop a seat living under an arbitrary runtime root: (1) root, (2) seat name.
# stop_home_seat is this with the home-army root baked in; the quest-QA seat
# passes its own root so it can never signal a home seat by name collision.
define stop_home_seat_dir
	@set -e; \
	seat_dir="$(1)/$(2)"; \
	pid_file="$$seat_dir/launcher.pid"; \
	admin_pid="$$seat_dir/lua-debug-admin.pid"; \
	if [ -s "$$admin_pid" ]; then \
		apid=$$(cat "$$admin_pid"); \
		if kill -0 "$$apid" 2>/dev/null; then \
			kill -TERM -- "-$$apid" 2>/dev/null || kill -TERM "$$apid" 2>/dev/null || true; \
			echo "stopped $(2) debug admin (pid $$apid)"; \
		fi; \
		rm -f "$$admin_pid"; \
	fi; \
	if [ ! -s "$$pid_file" ]; then echo "$(2) is stopped"; exit 0; fi; \
	pid=$$(cat "$$pid_file"); \
	if ! kill -0 "$$pid" 2>/dev/null; then \
		rm -f "$$pid_file"; echo "$(2) is stopped (removed stale pid)"; exit 0; \
	fi; \
	kill -TERM -- "-$$pid" 2>/dev/null || kill -TERM "$$pid"; \
	i=0; while kill -0 "$$pid" 2>/dev/null && [ $$i -lt 30 ]; do sleep 0.5; i=$$((i + 1)); done; \
	if kill -0 "$$pid" 2>/dev/null; then \
		echo "error: $(2) did not stop after 15 seconds (pid $$pid)" >&2; exit 1; \
	fi; \
	rm -f "$$pid_file"; echo "stopped $(2)"
endef

define stop_home_seat
	@set -e; \
	seat_dir="$(HOME_ARMY_DIR)/$(1)"; \
	pid_file="$$seat_dir/launcher.pid"; \
	admin_pid="$$seat_dir/lua-debug-admin.pid"; \
	if [ -s "$$admin_pid" ]; then \
		apid=$$(cat "$$admin_pid"); \
		if kill -0 "$$apid" 2>/dev/null; then \
			kill -TERM -- "-$$apid" 2>/dev/null || kill -TERM "$$apid" 2>/dev/null || true; \
			echo "stopped $(1) debug admin (pid $$apid)"; \
		fi; \
		rm -f "$$admin_pid"; \
	fi; \
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

.PHONY: test test-lua test-nim system pin-check start-server stop-server server-logging logs account soap-account play play-classic play-classic-netlog play-xr traverse traverse-field traverse-replay traverse-pack-replay traverse-headed traverse-pol traverse-desert traverse-wet traverse-checkpoints traverse-lint traverse-lint-soft lift-tele quest-data item-data road-data bot-road-data bot-quest-hubs warlock-account warlock-bot botwarrior-bot tusk-account tusk-bot beru-account beru-bot party-army home-army-start home-army-stop home-army-restart home-army-status shadowfel-start shadowfel-stop igris-start igris-stop tusk-start tusk-stop beru-start beru-stop navmesh-helper navmesh-status map-browser map-browser-once map-browser-debug map-browser-probe

# Unit tier: Lua tools + Nim host/system tests only (v2 DoD: no Python required
# for bot correctness). If nim is missing, test-nim-soft skips rather than
# failing bare CI hosts. Smoke tier parse/compile-checks code no unit test
# executes (including addon Lua) — doctrine: a cheap compile-check is a
# legitimate leg for a binary with no unit tests yet.
test: test-lua test-nim-soft test-smoke test-traverse-soap test-traverse-checkpoint traverse-lint-soft

.PHONY: test-traverse-soap test-traverse-checkpoint test-road-artifacts traverse-lint traverse-lint-soft
test-traverse-soap:
	@python3 tools/tests/test_traverse_soap.py
test-traverse-checkpoint:
	@python3 tools/tests/test_traverse_checkpoint.py
	@python3 tools/tests/test_traverse_scorecard.py
	@python3 tools/tests/test_traverse_route_lint.py
	@python3 tools/tests/test_road_mask.py
	@python3 tools/tests/test_minimap_mask.py
	@python3 tools/tests/test_road_artifacts.py
test-road-artifacts:
	@python3 tools/tests/test_road_artifacts.py
# Offline land-beat corridor lint (Detour helper + spawn TSV). Exits 0 on SKIP
# when helper/mmaps are missing so bare CI hosts stay green. make test uses
# --warn-only so corridor FAILs do not red the unit suite; traverse-lint is strict.
# The beat files are local-only route data (gitignored, see AGENTS.md copyright
# hygiene), so the soft lint names and skips each one a checkout lacks.
TRAVERSE_LINT_BEATS = lua/config/traverse_land_beats.json \
	lua/config/traverse_connector_land_beats.json \
	lua/config/traverse_finale_beats.json
traverse-lint-soft:
	@for b in $(TRAVERSE_LINT_BEATS); do \
		if [ -f "$$b" ]; then \
			python3 tools/traverse_route_lint.py --warn-only --beats "$$b" || exit 1; \
		else \
			echo "traverse-lint-soft: SKIP $$b (local route data not present)"; \
		fi; \
	done
traverse-lint:
	@python3 tools/traverse_route_lint.py
	@python3 tools/traverse_route_lint.py \
		--beats lua/config/traverse_connector_land_beats.json
	@python3 tools/traverse_route_lint.py \
		--beats lua/config/traverse_finale_beats.json

# Every maintained Nim entrypoint/module must at least compile (`nim check`),
# even where no unit suite imports it yet.
NIM_CHECK_FILES = system/system_server.nim \
	tools/fair_play_audit.nim tools/party_promote.nim \
	tools/lua_debug_admin.nim \
	src/conductor.nim

.PHONY: test-smoke test-smoke-lua test-smoke-nim test-smoke-nim-soft test-smoke-sh
test-smoke: test-smoke-lua test-smoke-nim-soft test-smoke-sh

# Cheap parse-only gate for the operator shell scripts (same doctrine as
# test-smoke-lua: a compile-check is a legitimate leg for code with no unit
# suite). `bash -n` never executes a line.
SH_CHECK_FILES = tools/home_army_scale.sh tools/soap.sh tools/realm_op.sh tools/private_seat_identity.sh \
	tools/home_assets.sh tools/retain_seat_runtime.sh
test-smoke-sh:
	@rc=0; for f in $(SH_CHECK_FILES); do \
		[ -f "$$f" ] || continue; \
		bash -n "$$f" || { echo "PARSE FAIL: $$f"; rc=1; }; \
	done; \
	if [ $$rc -eq 0 ]; then echo "test-smoke-sh: all shell parses clean"; fi; \
	exit $$rc

# Parse-only check of every non-test Lua file (addon files are Lua 5.0-style
# but 5.3 luac still catches syntax errors; the addon itself is never run by
# lua/tests, so this is its only automated gate).
test-smoke-lua:
	@rc=0; for f in addons/*/*.lua lua/*.lua lua/data/*.lua lua/tools/*.lua lua/entry/*.lua; do \
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

# Traverse and petrel tests run on the local recorded route when present
# (under WSA_PRIVATE_INPUTS, default the repo root); the second pass keeps the
# synthetic route fixture exercised in that case too.
test-lua:
	@rc=0; for t in lua/tests/test_*.lua; do \
		echo "== $$t"; LUA_PATH="lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
	done; \
	if [ -f "$${WSA_PRIVATE_INPUTS:-.}/lua/config/traverse_beats.lua" ]; then \
		for t in lua/tests/test_traverse.lua lua/tests/test_traverse_wet.lua; do \
			echo "== $$t (synthetic route)"; TRAVERSE_ROUTE=synthetic \
				LUA_PATH="lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
		done; \
	fi; \
	if [ -f "$${WSA_PRIVATE_INPUTS:-.}/lua/config/petrel/traverse_beats.lua" ]; then \
		for t in lua/tests/test_petrel*.lua; do \
			echo "== $$t (synthetic route)"; TRAVERSE_ROUTE=synthetic \
				LUA_PATH="lua/?.lua;lua/entry/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
		done; \
	fi; exit $$rc

# Optional Nim unit tier (enum maps / pure parsers). Not part of `make test`
# so CI and bare hosts without nim stay green. PATH-nim first, else nix develop
# if a flake appears later (same pattern as crewrift-prime-bots).
test-nim:
	@if command -v nim >/dev/null 2>&1; then \
		rc=0; \
		for t in system/tests/test_*.nim tools/tests/test_*.nim; do \
			[ -f "$$t" ] || continue; \
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

# Map browser: standalone bird's-eye WDL terrain viewer (no fork renderer).
# MAP_BROWSER_STATS / MAP_BROWSER_AUTO are the agent-facing instrumentation
# (formerly also MAP_BROWSER_DEBUG zone-drill probe — that era is gone).
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

map-browser-probe:
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
	VANILLA_WOW_CLIENT_DATA_DIR="$${VANILLA_WOW_CLIENT_DATA_DIR:-$(CLASSIC_CLIENT)}" \
		MAP_BROWSER_AUTO="$${MAP_BROWSER_AUTO:-seconds=8,screenshot=local_data/map_browser_probe.png}" \
		MAP_BROWSER_STATS=local_data/map_browser_stats.json \
		nix develop --command nim r src/tools/map_browser.nim

.PHONY: minimap-atlas
minimap-atlas:
	nix-shell -p python3Packages.pillow --run 'python3 tools/bake_minimap_atlas.py --map kalimdor && python3 tools/bake_minimap_atlas.py --map azeroth'

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
	@cd $(FORK_CLIENT) && timeout 900 $(call LUA_BOT_LAUNCH,--presentation=unheaded) || true
	@python3 tools/episode_score.py
# Unheaded accelerated run of the lua-bot (ENTRY=<module>, default peregrine).
accelerated:
	@cd $(FORK_CLIENT) && $(call LUA_BOT_LAUNCH,--presentation=unheaded)

# Bounded proof-of-life receipt for the lua-bot: the league admission gate.
accelerated-pol:
	@cd $(FORK_CLIENT) && $(call LUA_BOT_LAUNCH,--proof-of-life)

# Watch the lua-bot play (opens a window; run only when asked).
accelerated-headed:
	@cd $(FORK_CLIENT) && $(call LUA_BOT_LAUNCH,--presentation=headed)

# ---------------------------------------------------------------------------
# Peregrine: hosted Accelerated policy image (unheaded lua-bot + this lua/).
# Base binary from monofuel-vanilla-wow target lua_bot_player_runtime, built
# by the fork's own image owner (clean tracked checkout, SSH-forwarded nimby
# sync, checkout revision stamped). Policy images bake only tracked lua code;
# see the Dockerfile.* headers for the private route data they do not carry.
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
	uv run python tools/build_player_image.py $(LUA_BOT_PLAYER_IMAGE) \
		--platform linux/amd64 --target lua_bot_player_runtime

peregrine-image: lua-bot-player-image
	@set -e; \
	docker build --platform linux/amd64 \
		-f Dockerfile.peregrine \
		--build-arg LUA_BOT_PLAYER_IMAGE=$(LUA_BOT_PLAYER_IMAGE) \
		-t $(PEREGRINE_IMAGE) .; \
	test "$$(docker image inspect $(PEREGRINE_IMAGE) --format '{{.Architecture}}')" = amd64; \
	echo "built $(PEREGRINE_IMAGE) (policy name: peregrine)"

# Petrel: hosted Traverse policy image (unheaded lua-bot + this lua/,
# entry=petrel). Same shape as Peregrine; see Dockerfile.petrel and
# playbooks/upload-bot.md. Does NOT upload or submit.
PETREL_IMAGE ?= petrel:latest
.PHONY: petrel-image
petrel-image: lua-bot-player-image
	@set -e; \
	docker build --platform linux/amd64 \
		-f Dockerfile.petrel \
		--build-arg LUA_BOT_PLAYER_IMAGE=$(LUA_BOT_PLAYER_IMAGE) \
		-t $(PETREL_IMAGE) .; \
	test "$$(docker image inspect $(PETREL_IMAGE) --format '{{.Architecture}}')" = amd64; \
	echo "built $(PETREL_IMAGE) (policy name: petrel)"

# ---------------------------------------------------------------------------
# Raven: hosted Persistent policy (peregrine entry; undead warlock at submit).
# ---------------------------------------------------------------------------
RAVEN_IMAGE ?= raven:latest
.PHONY: raven-image persistent-pol persistent persistent-headed
raven-image: lua-bot-player-image
	@set -e; \
	docker build --platform linux/amd64 \
		-f Dockerfile.raven \
		--build-arg LUA_BOT_PLAYER_IMAGE=$(LUA_BOT_PLAYER_IMAGE) \
		-t $(RAVEN_IMAGE) .; \
	test "$$(docker image inspect $(RAVEN_IMAGE) --format '{{.Architecture}}')" = amd64; \
	echo "built $(RAVEN_IMAGE) (policy name: raven; submit undead/warlock)"

persistent-pol:
	@cd $(FORK_CLIENT) && $(call PERSISTENT_LAUNCH,--proof-of-life)

persistent:
	@cd $(FORK_CLIENT) && $(call PERSISTENT_LAUNCH,--presentation=unheaded)

persistent-headed:
	@cd $(FORK_CLIENT) && $(call PERSISTENT_LAUNCH,--presentation=headed)

# Regenerate addons/ShadowArmy/QuestData.lua from the world DB + WorldMapArea.dbc
# (docs/quest-data.md). Read-only DB access; requires the realm up. Deterministic,
# so a no-op rerun leaves the file byte-identical. Scope with:
#   make quest-data QUEST_DATA_ARGS="--max-level 20"
#   make quest-data QUEST_DATA_ARGS="--zones 85,130,12"
QUEST_DATA_ARGS ?=
quest-data:
	@python3 tools/gen_quest_data.py \
		--dbc-dir "$(VANILLA_WOW_EXTRACTED_DATA_DIR)/dbc" $(QUEST_DATA_ARGS)

# Regenerate addons/ShadowArmy/ItemData.lua from the world DB (docs/item-data.md).
# Read-only DB access; requires the realm up. Deterministic, so a no-op rerun
# leaves the file byte-identical. Whole game, no DBCs needed.
ITEM_DATA_ARGS ?=
item-data:
	@python3 tools/gen_item_data.py $(ITEM_DATA_ARGS)

# Regenerate addons/ShadowArmy/RoadData.lua from the baked road waypoints
# (docs/road-data.md). No DB and no realm — tools/data/road_waypoints_*.jsonl
# plus the DBCs and the maps/*.map area grids are the whole input (the grids
# arbitrate which zone a point is in; --map-dir defaults to maps/ beside
# --dbc-dir). Deterministic, so a no-op rerun
# leaves the file byte-identical.
ROAD_DATA_ARGS ?=
road-data:
	@python3 tools/gen_road_data.py \
		--dbc-dir "$(VANILLA_WOW_EXTRACTED_DATA_DIR)/dbc" $(ROAD_DATA_ARGS)

# Regenerate lua/data/bot_roads.lua from the same baked road waypoints, in
# WORLD coordinates for the bots (lua/tools/road_route.lua). No DBCs, no maps,
# no realm — the two JSONL artifacts are the whole input, because bots speak
# world coords and never need the zone projection the addon is stuck with.
# Deterministic, so a no-op rerun leaves the file byte-identical.
BOT_ROAD_DATA_ARGS ?=
bot-road-data:
	@python3 tools/gen_bot_road_data.py $(BOT_ROAD_DATA_ARGS)

# Regenerate lua/data/bot_quest_hubs.lua: quest id -> the WORLD position of the
# creature that starts it and the creature that ends it. Reads the world DB
# read-only through the same docker shell-out gen_quest_data.py uses (whose
# relation/spawn loaders this imports rather than re-derives). The bots' own
# questgiver memory only holds NPCs a seat has SEEN and dies on reload, so
# without this table a completed quest in a giver-free field has nothing to
# walk back to. Deterministic: a no-op rerun leaves the file byte-identical.
BOT_QUEST_HUBS_ARGS ?=
bot-quest-hubs:
	@python3 tools/gen_bot_quest_hubs.py $(BOT_QUEST_HUBS_ARGS)

# Real icons for the dashboard bag grid. Pillow (BLP decode) comes from nix —
# the one sanctioned deviation from the stdlib-only generator rule.
.PHONY: item-icons
item-icons:
	@nix shell --impure --expr "with import <nixpkgs> {}; python3.withPackages (ps: [ ps.pillow ])" \
		--command python3 tools/gen_item_icons.py $(ITEM_ICONS_ARGS)

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

# Stop the private coworld-game service, retaining its validated container.
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
	$(call launch_home_seat,$(WARLOCK_CHARACTER),$(WARLOCK_ACCOUNT),$(WARLOCK_PASS),$(WARLOCK_CLASS))

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
# (F9 movement-evidence logging). Client geometry comes from the current
# extracted-data install the league launches use (LEAGUE_DATA_DIR); the
# upstream checkout's older extraction fails the launcher's release check.
# This repo's dev shell supplies the runtime libraries (ssl, GL, X11, the
# jemalloc the headed player links) and the nginx and uv the launcher's local
# asset path needs. The fork's config.nims requires the Nim pinned by its
# player/Dockerfile, so that Nimby-installed compiler is selected and verified
# before compiling. tools/wow_env.sh is not sourced here: its global Nim and
# fixed store paths override the dev shell.
# `make play EXTRA=--check` validates the launch path without opening a client.
play:
	@set -e; \
	if [ ! -d "$(FORK_CLIENT)" ]; then \
		echo "error: fork checkout missing: $(FORK_CLIENT)" >&2; exit 1; \
	fi; \
	if [ ! -d "$(LEAGUE_DATA)/dbc" ] || [ ! -d "$(LEAGUE_DATA)/mmaps" ]; then \
		echo "error: extracted client data missing (needs dbc/ and mmaps/): $(LEAGUE_DATA_DIR)" >&2; exit 1; \
	fi; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(LEAGUE_DATA)" \
	nix develop "$(CURDIR)" --command sh -c \
		'set -e; \
		pin=$$(sed -n "s/^ARG NIM_VERSION=//p" player/Dockerfile); \
		if [ -z "$$pin" ]; then \
			echo "error: player/Dockerfile does not pin NIM_VERSION" >&2; exit 1; \
		fi; \
		for bin in "$$NIMBY_HOME/nim-$$pin/bin" "$$HOME/.nimby/nim-$$pin/bin"; do \
			if [ -x "$$bin/nim" ]; then PATH="$$bin:$$PATH"; export PATH; break; fi; \
		done; \
		found=$$(nim --version | head -n 1); \
		case "$$found" in \
			*"Version $$pin "*) ;; \
			*) echo "error: play requires Nim $$pin under $$NIMBY_HOME/nim-$$pin/bin; found: $$found" >&2; exit 1;; \
		esac; \
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
# The wet chain is unconditional (the PETREL_SWIM gate is gone, ticket
# 0015): every traverse run is the full course — desert, swim, connector,
# finale. The harness passes NO behavior-changing env vars; what runs
# locally is what ships.
# CHECKPOINT=<name> SOAP-teleports the character after login (local debug;
# names from `make traverse-checkpoints`). The episode realm is recreated
# per launch, so SOAP is enabled at birth and a background watcher waits
# for the traverse container before applying — it never touches the
# persistent realm. wet_start lands swimming; water_entry lands DRY
# on the sand (the shoreline entry is a known-open gap on the lua-bot
# host — you will see the bot work the waterline, not the ribbon).
# END_CHECKPOINT=<name> turns either launcher into a bounded segment test. It
# waits until the start tele is observed, records idle/swim/death metrics, and
# terminates the launcher successfully at 50 yd from the named endpoint.
CHECKPOINT ?=
END_CHECKPOINT ?=
END_TIMEOUT ?=2700
TRAVERSE_SEGMENT_RESULT := $(CURDIR)/local_data/traverse-segment-result.json
TRAVERSE_LIVE_LOCK := $(CURDIR)/local_data/traverse-live.lock
define TRAVERSE_ACQUIRE_LOCK
	mkdir -p "$(CURDIR)/local_data"; \
	exec 8>"$(TRAVERSE_LIVE_LOCK)"; \
	if ! flock -n 8; then \
		echo "error: another live Traverse run owns $(TRAVERSE_LIVE_LOCK)" >&2; \
		exit 2; \
	fi
endef
define TRAVERSE_CHECKPOINT_PRELUDE
	$(TRAVERSE_ACQUIRE_LOCK); \
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
		setsid sh -c '$(TRAVERSE_LAUNCH) --presentation=$(1) 2>&1 | tee "$(CURDIR)/local_data/traverse-status/run.log"' & \
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
		$(TRAVERSE_LAUNCH) --presentation=$(1) 2>&1 | \
			tee "$(CURDIR)/local_data/traverse-status/run.log"; \
	fi
endef
traverse:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	$(call TRAVERSE_RUN,unheaded)

# Headed Petrel run for manual verification (opens a window — human use).
traverse-headed:
	@mkdir -p local_data/health-logs
	@$(TRAVERSE_CHECKPOINT_PRELUDE); \
	$(call TRAVERSE_RUN,headed)

# Fast regression: proof-of-life (level 60, map 1, movement + inputs).
traverse-pol:
	@$(TRAVERSE_ACQUIRE_LOCK); \
	cd $(FORK_CLIENT) && $(TRAVERSE_LAUNCH) --proof-of-life

# Land-leg proof: spawn → desert ocean coast (water_entry), with client CPU
# sampling for the streaming-starvation investigation. Readback at exit.
traverse-desert:
	@$(TRAVERSE_ACQUIRE_LOCK); \
	tools/traverse_desert.sh

# Wet lab: SOAP-tele to water_entry, swim the cheese ribbon to Dustwallow.
# Local debug only; reports best_planar_to_duskwallow_wet at exit.
traverse-wet:
	@$(TRAVERSE_ACQUIRE_LOCK); \
	tools/traverse_wet.sh

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
	$(call launch_home_seat,$(IGRIS_CHARACTER),$(IGRIS_ACCOUNT),$(IGRIS_PASS),$(IGRIS_CLASS))

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
	$(call launch_home_seat,$(TUSK_CHARACTER),$(TUSK_ACCOUNT),$(TUSK_PASS),$(TUSK_CLASS))

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
	$(call launch_home_seat,$(BERU_CHARACTER),$(BERU_ACCOUNT),$(BERU_PASS),$(BERU_CLASS))

# Explicit bot lifecycle. These targets do not start or stop the persistent
# realm and do not create accounts; character/server state stays untouched.
shadowfel-start:
	$(call start_home_seat,$(WARLOCK_CHARACTER),warlock-bot,0)
igris-start:
	$(call start_home_seat,$(IGRIS_CHARACTER),igris-bot,1)
tusk-start:
	$(call start_home_seat,$(TUSK_CHARACTER),tusk-bot,2)
beru-start:
	$(call start_home_seat,$(BERU_CHARACTER),beru-bot,3)

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
# Scale-out home seats — PARAMETERIZED, roster-driven.
#
# The original four (Shadowfel/Igris/Tusk/Beru) keep their hand-written
# targets above and are never touched by anything in this block. Extra seats
# are one generic target family instead of N copy-pasted pairs:
#
#   make seat-account SEAT=Bellion SEAT_USER=shadow5
#   make seat-start   SEAT=Bellion SEAT_USER=shadow5 SEAT_CLASS=mage
#   make seat-status  SEAT=Bellion
#   make seat-stop    SEAT=Bellion
#
# The roster table (tools/data/home_army_roster.tsv) plus the STAGGERED
# rollout live in tools/home_army_scale.sh — one seat at a time with a gap,
# because all seats share one nginx asset server on 127.0.0.1:25608
# (docs/postmortems/2026-08-15-asset-server-connection-drops.md).
#
#   make army-scale-start    # staggered launch of the whole roster
#   make army-scale-status   # roster + status.json freshness
#   make army-scale-stop
#
# CHARACTER CREATION is the ordinary client flow, not a DB insert: with
# VANILLA_WOW_PLAYER_CHARACTER_CREATION=1 a character name absent from
# SMSG_CHAR_ENUM is rolled via CMSG_CHAR_CREATE, and the appearance tuple
# comes from VANILLA_WOW_PLAYER_CHARACTER_{RACE,CLASS,GENDER} — that env var
# IS the class picker (docs/warlock-seat.md "Why no seed script"). Defaults
# are troll/shaman/male, so all three are always set.
#
# WS bridge: these seats reuse the proven slot=0/token-0 pair the original
# four share. /tcp/realmd and /tcp/world are raw byte proxies that keep a SET
# of tasks per slot (no one-owner rule, no connection counter) and carry each
# seat's own account credentials over the wire, so one slot serves all of
# them. Realm PlayerLimit is 100.
#
# NO DEBUG PORT by default: 7788..7791 belong to the original four and 7800
# to the quest-QA seat. Opt a single seat in with SEAT_DEBUG_PORT=7801+.
#
# OFF-DISPLAY BY DEFAULT — this is what makes scaling past five seats legal.
# The launcher's machine-local `seat` lease has a hard capacity of FIVE shared
# lanes (agents/agent_lease.py SHARED_CAPACITIES in the fork), and it exists to
# ration the HOST GPU/X display: requiresSeatLease() is
# `rendered and (not headless or hostDisplayAvailable)`. A headless seat that
# can see DISPLAY grabs a real GLX context on monofuel's desktop — five of
# those is the cap, and the original four plus the traverse lane already fill
# it. Launch with DISPLAY/XAUTHORITY cleared and nativeDisplayAvailable() is
# false, so the launcher takes its own documented branch: xvfb-run + software
# GL, and requiresSeatLease() returns false. No lease, no lane contention with
# the human's desktop or with sibling lanes — the launcher's design, not a
# workaround. Cost is CPU (software rasterizer), which is why the rollout is
# staggered and guarded. Set SEAT_HOST_DISPLAY=1 to put a seat back on the
# host display (it will then queue for one of the five lanes).
SEAT_HOST_DISPLAY ?=
# llvmpipe spawns a rasterizer thread per core by default — N software seats
# times 32 threads is self-inflicted thrash. Bots render pixels nobody sees;
# cap them hard.
SEAT_LP_THREADS ?= 4
SEAT ?=
SEAT_USER ?=
SEAT_PASS ?= $(SEAT_USER)
SEAT_RACE ?= undead
SEAT_CLASS ?= warrior
SEAT_GENDER ?= male
SEAT_ENTRY ?= $(HOME_ENTRY)
SEAT_SLOT ?= $(HOME_SLOT)
SEAT_TOKEN ?= $(HOME_TOKEN)
SEAT_DEBUG_PORT ?=
ARMY_ROSTER ?= $(CURDIR)/tools/data/home_army_roster.tsv
ARMY_SCALE := $(CURDIR)/tools/home_army_scale.sh

# Every parameterized recipe re-exports its inputs to the detached child.
SEAT_ARGS = SEAT="$(SEAT)" SEAT_USER="$(SEAT_USER)" SEAT_PASS="$(SEAT_PASS)" \
	SEAT_RACE="$(SEAT_RACE)" SEAT_CLASS="$(SEAT_CLASS)" \
	SEAT_GENDER="$(SEAT_GENDER)" SEAT_ENTRY="$(SEAT_ENTRY)" \
	SEAT_SLOT="$(SEAT_SLOT)" SEAT_TOKEN="$(SEAT_TOKEN)" \
	SEAT_DEBUG_PORT="$(SEAT_DEBUG_PORT)"

.PHONY: seat-guard seat-account seat-character seat-provision seat-bot \
	seat-start seat-stop seat-status \
	army-scale-start army-scale-stop army-scale-status army-scale-provision

seat-guard:
	@if [ -z "$(SEAT)" ]; then \
		echo "error: SEAT=<Name> is required (e.g. make seat-start SEAT=Bellion SEAT_USER=shadow5 SEAT_CLASS=mage)" >&2; \
		exit 1; \
	fi; \
	seat_lc=$$(printf '%s' "$(SEAT)" | tr 'A-Z' 'a-z'); \
	case " shadowfel igris tusk beru kaisel murist " in *" $$seat_lc "*) \
		echo "error: $(SEAT) is a protected seat — use its dedicated targets" >&2; \
		exit 1;; \
	esac

# Idempotent, same SOAP path as qa-account (the upstream provisioning script
# the older *-account targets call is gone from the upstream checkout).
seat-account: seat-guard
	@if [ -z "$(SEAT_USER)" ]; then echo "error: SEAT_USER=<account> is required" >&2; exit 1; fi; \
	$(CURDIR)/tools/soap.sh account create $(SEAT_USER) $(SEAT_PASS) || true; \
	echo "account ready: $(SEAT_USER) / $(SEAT_PASS)"

# Roll the seat's level-1 character through the ORDINARY client protocol.
#
# This step is separate because the rendered client CANNOT do it: its world
# entry resolves the name through requireExistingCharacter (select-only), so a
# name absent from SMSG_CHAR_ENUM is a hard error, not a create.
# VANILLA_WOW_PLAYER_CHARACTER_CREATION is only read by the Reference Player
# and hosted coworld-session routes, neither of which serves a local
# direct-WebSocket lua-bot seat — the quest-QA seat hit exactly this wall on
# 2026-08-15 (local_data/qa-seat/Kaisel/launcher.log.*).
#
# tools/roll_seat_character.nim in the fork sends real CMSG_CHAR_CREATE over
# the realm's published ports: server-validated race/class, fresh level 1, no
# DB write and no GM command. Idempotent — an existing name is skipped.
# SEAT_CLASS is the class selector.
SEAT_REALM_HOST ?= 127.0.0.1
SEAT_REALM_PORT ?= 3724
SEAT_WORLD_PORT ?= 8085
seat-character: seat-guard
	@set -e; \
	if [ -z "$(SEAT_USER)" ]; then echo "error: SEAT_USER=<account> is required" >&2; exit 1; fi; \
	cd "$(FORK_CLIENT)"; \
	nix develop --command nim r --hints:off --warnings:off \
		tools/roll_seat_character.nim -- \
		--host="$(SEAT_REALM_HOST)" --port="$(SEAT_REALM_PORT)" \
		--world-port="$(SEAT_WORLD_PORT)" \
		--username="$(SEAT_USER)" --password="$(SEAT_PASS)" \
		--name="$(SEAT)" --race="$(SEAT_RACE)" --class="$(SEAT_CLASS)" \
		--gender="$(SEAT_GENDER)"

seat-provision: seat-account seat-character

# Foreground seat, same runtime root as the original four so The System's
# roster control-plane column and the home-army-status pattern both find it.
seat-bot: seat-guard
	@set -e; \
	if [ -z "$(SEAT_USER)" ]; then echo "error: SEAT_USER=<account> is required" >&2; exit 1; fi; \
	$(HOME_SEAT_PREFLIGHT) "$(SEAT)" "$(SEAT_USER)" "$(SEAT_CLASS)"; \
	seat_dir="$(HOME_ARMY_DIR)/$(SEAT)"; \
	mkdir -p "$$seat_dir/status" "$$seat_dir/observer"; \
	debug_dir=""; \
	if [ -n "$(SEAT_DEBUG_PORT)" ]; then \
		debug_dir="$$seat_dir/control"; mkdir -p "$$debug_dir/acks"; \
	fi; \
	if [ -z "$(SEAT_HOST_DISPLAY)" ]; then \
		unset DISPLAY XAUTHORITY WAYLAND_DISPLAY; \
		export LP_NUM_THREADS="$(SEAT_LP_THREADS)"; \
	fi; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_LOGIN_WS_URL="$(HOME_WS)/tcp/realmd?slot=$(SEAT_SLOT)&token=$(SEAT_TOKEN)" \
	VANILLA_WOW_GAME_WS_URL="$(HOME_WS)/tcp/world?slot=$(SEAT_SLOT)&token=$(SEAT_TOKEN)" \
	VANILLA_WOW_LUA_DEBUG_DIR="$$debug_dir" \
	VANILLA_WOW_PLAYER_CHARACTER_CREATION=0 \
	VANILLA_WOW_EXTRACTED_DATA_DIR="$(LEAGUE_DATA)" \
	SHADOW_SEAT_DIR="$$seat_dir" \
	COWORLD_PLAYER_OBSERVER_DIR="$$seat_dir/observer" \
	nix develop "$(CURDIR)" --command nim r tools/launch_nim_player.nim -- \
		--controller=embedded --presentation=unheaded --bot=lua-bot \
		--owner=home-$(SEAT) \
		--lua-repo="$(CURDIR)" --lua-entry="$(SEAT_ENTRY)" \
		--lua-status-dir="$$seat_dir/status" \
		--username="$(SEAT_USER)" --password="$(SEAT_PASS)" \
		--character-name="$(SEAT)" \
		--skip-cinematic

# Shared checkout assets for every home seat: one nginx owned by the
# wow-home-assets user unit (app.slice), never by a seat launcher, so stopping
# any one seat leaves terrain reads working for the rest. Seat preflight starts
# it on demand and waits until it serves the asset version the unit prepared;
# launchers then only reuse it.
HOME_ASSETS_UNIT ?= wow-home-assets
HOME_ASSETS_URL_FILE := $(HOME_ARMY_DIR)/assets-url
HOME_ASSETS_VERSION_FILE := $(HOME_ARMY_DIR)/assets-version
HOME_ASSETS_READY_SECONDS ?= 180
HOME_ASSETS_START_RACE_SECONDS ?= 30
HOME_USER_BUS = XDG_RUNTIME_DIR="$${XDG_RUNTIME_DIR:-/run/user/$$(id -u)}"

# A unit started before the version file existed recorded the version it
# prepared only in its journal ("serving asset version V at URL"); adopt that
# line when it names the current URL. A parallel seat that loses the
# systemd-run race accepts the winner's unit once it is active.
home-assets-start:
	@set -e; \
	if $(HOME_USER_BUS) systemctl --user is-active --quiet $(HOME_ASSETS_UNIT); then \
		if [ ! -s "$(HOME_ASSETS_VERSION_FILE)" ] && [ -s "$(HOME_ASSETS_URL_FILE)" ]; then \
			url=$$(cat "$(HOME_ASSETS_URL_FILE)"); \
			version=$$($(HOME_USER_BUS) journalctl --user -u $(HOME_ASSETS_UNIT) -o cat --no-pager 2>/dev/null | \
				sed -n "s|^home_assets: serving asset version \([^ ]*\) at $$url\$$|\1|p" | tail -n 1); \
			if [ -n "$$version" ]; then \
				printf "%s\n" "$$version" >"$(HOME_ASSETS_VERSION_FILE)"; \
				echo "adopted $(HOME_ASSETS_UNIT) asset version $$version"; \
			fi; \
		fi; \
		echo "$(HOME_ASSETS_UNIT) already running"; exit 0; \
	fi; \
	mkdir -p "$(HOME_ARMY_DIR)"; rm -f "$(HOME_ASSETS_URL_FILE)" "$(HOME_ASSETS_VERSION_FILE)"; \
	$(HOME_USER_BUS) systemctl --user reset-failed $(HOME_ASSETS_UNIT) 2>/dev/null || true; \
	if ! $(HOME_USER_BUS) systemd-run --user --unit=$(HOME_ASSETS_UNIT) --slice=app.slice --collect \
		-p Restart=on-failure -p RestartSec=2 \
		--working-directory="$(CURDIR)" \
		--setenv=HOME="$$HOME" --setenv=PATH="$$PATH" \
		--setenv=VANILLA_WOW_EXTRACTED_DATA_DIR="$(LEAGUE_DATA)" \
		nix develop "$(CURDIR)" --command "$(CURDIR)/tools/home_assets.sh" \
		"$(FORK_CLIENT)" "$(HOME_ASSETS_URL_FILE)" "$(HOME_ASSETS_VERSION_FILE)"; then \
		i=0; \
		while :; do \
			state=$$($(HOME_USER_BUS) systemctl --user show -p ActiveState --value $(HOME_ASSETS_UNIT) 2>/dev/null); \
			if [ "$$state" = active ] || [ "$$state" = activating ]; then \
				echo "$(HOME_ASSETS_UNIT) started by a parallel seat"; exit 0; \
			fi; \
			if [ $$i -ge $(HOME_ASSETS_START_RACE_SECONDS) ]; then \
				echo "error: could not start $(HOME_ASSETS_UNIT) (journalctl --user -u $(HOME_ASSETS_UNIT))" >&2; exit 1; \
			fi; \
			sleep 1; i=$$((i + 1)); \
		done; \
	fi; \
	echo "started $(HOME_ASSETS_UNIT); logs: journalctl --user -u $(HOME_ASSETS_UNIT)"

# Ready only when the listener serves exactly the version the unit prepared:
# during a port takeover an older launcher-owned listener can still answer.
home-assets-ready: home-assets-start
	@i=0; \
	while :; do \
		if [ -s "$(HOME_ASSETS_URL_FILE)" ] && [ -s "$(HOME_ASSETS_VERSION_FILE)" ]; then \
			served=$$(curl -fsS --max-time 2 "$$(cat "$(HOME_ASSETS_URL_FILE)")/asset_version.txt" 2>/dev/null || true); \
			if [ -n "$$served" ] && [ "$$served" = "$$(cat "$(HOME_ASSETS_VERSION_FILE)")" ]; then \
				exit 0; \
			fi; \
		fi; \
		state=$$($(HOME_USER_BUS) systemctl --user show -p ActiveState --value $(HOME_ASSETS_UNIT) 2>/dev/null); \
		if [ "$$state" != active ] && [ "$$state" != activating ]; then \
			echo "error: $(HOME_ASSETS_UNIT) is not running (journalctl --user -u $(HOME_ASSETS_UNIT))" >&2; exit 1; \
		fi; \
		if [ $$i -ge $(HOME_ASSETS_READY_SECONDS) ]; then \
			echo "error: shared home assets not serving the prepared version after $(HOME_ASSETS_READY_SECONDS)s" >&2; exit 1; \
		fi; \
		sleep 1; i=$$((i + 1)); \
	done

# Stops terrain reads for every running home seat; stop the seats first.
home-assets-stop:
	@$(HOME_USER_BUS) systemctl --user stop $(HOME_ASSETS_UNIT) 2>/dev/null || true; \
	rm -f "$(HOME_ASSETS_URL_FILE)" "$(HOME_ASSETS_VERSION_FILE)"; echo "stopped $(HOME_ASSETS_UNIT)"

.PHONY: home-assets-start home-assets-ready home-assets-stop

# Reuses the original detach/pid/log-rotate machinery. HOME_DEBUG_PORT_BASE is
# NOT consulted here (index 0 is passed only to satisfy the macro arity); this
# lane opts in per seat via SEAT_DEBUG_PORT instead.
seat-start: seat-guard
	$(call start_home_seat,$(SEAT),seat-bot $(SEAT_ARGS),0)

seat-stop: seat-guard
	$(call stop_home_seat,$(SEAT))

seat-status: seat-guard
	@seat_dir="$(HOME_ARMY_DIR)/$(SEAT)"; \
	if [ -s "$$seat_dir/status/status.json" ]; then \
		jq -c '{intent_kind,intent_reason,summary,bot}' "$$seat_dir/status/status.json"; \
	else echo "no status yet"; fi

army-scale-provision:
	@$(ARMY_SCALE) provision
army-scale-start:
	@$(ARMY_SCALE) start
army-scale-stop:
	@$(ARMY_SCALE) stop
army-scale-status:
	@$(ARMY_SCALE) status

# ---------------------------------------------------------------------------
# Kaisel — DISPOSABLE quest-QA scenario seat (ticket 0057,
# docs/quest-qa-2026-08-15.md).
#
# Not a home seat: its own account, its own runtime tree under
# local_data/qa-seat/, its own debug port (7800 by default, clear of the
# 7788..7791 home block), and it is never started by home-army-start. Agents
# own it end to end — start it, /lua/reload it while iterating on the
# soft-quest path, stop it when the run is done. The four home seats are never
# reloaded from this loop.
QA_ACCOUNT := shadow9
QA_PASS := shadow9
QA_CHARACTER := Kaisel
QA_RACE := undead
QA_CLASS := warlock
QA_GENDER := male
QA_SEAT_DIR := $(CURDIR)/local_data/qa-seat
QA_DEBUG_PORT ?= 7800
QA_ENTRY ?= home

.PHONY: qa-account qa-character qa-character-check qa-bot qa-seat-start qa-seat-stop qa-seat-status
# Idempotent: the GM console reports "Account already exists" on a re-run.
# Uses SOAP rather than the upstream provisioning script the older *-account
# targets call — that script is gone from the current upstream checkout
# (docs/quest-qa-2026-08-15.md).
qa-account:
	@$(CURDIR)/tools/soap.sh account create $(QA_ACCOUNT) $(QA_PASS) || true; \
	echo "account ready: $(QA_ACCOUNT) / $(QA_PASS)"

# One-time character roll through the ordinary client flow — no
# characters-table insert. The CLI world-entry route
# (player/runtime/glue_connect.nim startConnect) requires the character to
# already exist; only the GlueXML managed-character route creates one, and it
# is selected by OMITTING --character-name (that missing field is what turns
# the front door on) while supplying the --create-character-* prefill. Runs
# until the seat is in world; interrupt it once `make qa-character-check`
# shows the row.
qa-character:
	@set -e; \
	seat_dir="$(QA_SEAT_DIR)/$(QA_CHARACTER)"; \
	mkdir -p "$$seat_dir/status" "$$seat_dir/observer"; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_LOGIN_WS_URL="$(HOME_WS)/tcp/realmd?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_GAME_WS_URL="$(HOME_WS)/tcp/world?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	COWORLD_PLAYER_OBSERVER_DIR="$$seat_dir/observer" \
	nix develop --command nim r tools/launch_nim_player.nim -- \
		--controller=embedded --presentation=headless --bot=lua-bot \
		--owner=qa-$(QA_CHARACTER)-create \
		--lua-repo="$(CURDIR)" --lua-entry="$(QA_ENTRY)" \
		--lua-status-dir="$$seat_dir/status" \
		--username="$(QA_ACCOUNT)" --password="$(QA_PASS)" \
		--create-character-name="$(QA_CHARACTER)" \
		--create-character-race="$(QA_RACE)" \
		--create-character-class="$(QA_CLASS)" \
		--create-character-gender="$(QA_GENDER)" \
		--skip-cinematic

qa-character-check:
	@docker exec coworld-vmangos-coworld-game-1 mariadb -umangos -pmangos \
		characters -e "SELECT guid,name,race,class,level,map,zone FROM characters WHERE name='$(QA_CHARACTER)';"

# Foreground seat — identical launch shape to launch_home_seat so the QA seat
# exercises the same path the home seats do, only with its own dirs and port.
qa-bot:
	@set -e; \
	seat_dir="$(QA_SEAT_DIR)/$(QA_CHARACTER)"; \
	mkdir -p "$$seat_dir/status" "$$seat_dir/observer" "$$seat_dir/control/acks"; \
	cd "$(FORK_CLIENT)"; \
	VANILLA_WOW_LOGIN_WS_URL="$(HOME_WS)/tcp/realmd?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_GAME_WS_URL="$(HOME_WS)/tcp/world?slot=$(HOME_SLOT)&token=$(HOME_TOKEN)" \
	VANILLA_WOW_LUA_DEBUG_DIR="$$seat_dir/control" \
	COWORLD_PLAYER_OBSERVER_DIR="$$seat_dir/observer" \
	nix develop --command nim r tools/launch_nim_player.nim -- \
		--controller=embedded --presentation=headless --bot=lua-bot \
		--owner=qa-$(QA_CHARACTER) \
		--lua-repo="$(CURDIR)" --lua-entry="$(QA_ENTRY)" \
		--lua-status-dir="$$seat_dir/status" \
		--username="$(QA_ACCOUNT)" --password="$(QA_PASS)" \
		--character-name="$(QA_CHARACTER)" \
		--skip-cinematic

qa-seat-start:
	@set -e; \
	seat_dir="$(QA_SEAT_DIR)/$(QA_CHARACTER)"; \
	pid_file="$$seat_dir/launcher.pid"; \
	mkdir -p "$$seat_dir/control/acks" "$$seat_dir/status"; \
	if [ -s "$$pid_file" ] && kill -0 "$$(cat $$pid_file)" 2>/dev/null; then \
		echo "$(QA_CHARACTER) already running (pid $$(cat $$pid_file))"; exit 0; \
	fi; \
	$(RETAIN_SEAT_RUNTIME) "$$seat_dir"; \
	rm -f "$$pid_file" "$$seat_dir/status/status.json" "$$seat_dir/control/request.json"; \
	setsid $(MAKE) --no-print-directory qa-bot >"$$seat_dir/launcher.log" 2>&1 < /dev/null & \
	pid=$$!; echo "$$pid" > "$$pid_file"; \
	echo "starting $(QA_CHARACTER) (pid $$pid; log $$seat_dir/launcher.log)"; \
	admin_pid="$$seat_dir/lua-debug-admin.pid"; \
	if [ -s "$$admin_pid" ] && kill -0 "$$(cat $$admin_pid)" 2>/dev/null; then \
		echo "  debug admin already running (pid $$(cat $$admin_pid))"; \
	else \
		setsid nix develop --command nim r tools/lua_debug_admin.nim -- \
			--seat="$(QA_CHARACTER)" --port="$(QA_DEBUG_PORT)" \
			--control-dir="$$seat_dir/control" \
			--status-dir="$$seat_dir/status" \
			>"$$seat_dir/lua-debug-admin.log" 2>&1 < /dev/null & \
		echo "$$!" > "$$admin_pid"; \
		echo "  debug port http://127.0.0.1:$(QA_DEBUG_PORT)"; \
	fi

qa-seat-stop:
	$(call stop_home_seat_dir,$(QA_SEAT_DIR),$(QA_CHARACTER))

qa-seat-status:
	@seat_dir="$(QA_SEAT_DIR)/$(QA_CHARACTER)"; \
	if [ -s "$$seat_dir/status/status.json" ]; then \
		jq -c '{intent_kind,intent_reason,nav_progress,summary,bot}' \
			"$$seat_dir/status/status.json"; \
	else echo "no status yet"; fi

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
