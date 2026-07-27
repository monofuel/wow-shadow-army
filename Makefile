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

# Upstream coworld-vanilla-wow checkout (sibling; read-only — never write there).
UPSTREAM := $(abspath ../coworld-vanilla-wow)
# Vendored NixOS client library env (from coworld-playbook/tools/wow_env.sh).
WOW_ENV := $(CURDIR)/tools/wow_env.sh

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

OPERATOR := uv run python server/scripts/docker_vmangos_server.py
COMPOSE_FILE := infra/compose.vmangos.yml
# Human playtest account (type at the GlueXML login screen).
ACCOUNT_USER := monofuel
ACCOUNT_PASS := password

.PHONY: test test-lua test-python test-nim system pin-check integration-test start-server stop-server server-logging logs account soap-account play play-classic shadow escort escort-army grind party-form breadcrumbs quest-data warlock-account warlock-bot botwarrior-bot tusk-account tusk-bot beru-account beru-bot party-army navmesh-helper navmesh-status

# Unit tier only. test-python is stdlib-only (projection + intent_mapping + optional
# lua_runner smoke); it is wired into `make test` because it needs no venv/network.
test: test-lua test-python

test-lua:
	@rc=0; for t in lua/tests/test_*.lua; do \
		echo "== $$t"; LUA_PATH="lua/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
	done; exit $$rc

# Python unit tier: plain dicts + stdlib unittest. No pydantic/msgpack required.
# Runtime brain (brain.shadow) needs upstream deps — use:
#   uv run --project $(UPSTREAM) python -m brain.shadow ...
# breadcrumbs: DB poller diff logic (fixture dicts only; no mariadb in unit tier).
test-python:
	@python3 -m unittest discover -s brain/tests -p 'test_*.py' -v
	@python3 -m unittest discover -s breadcrumbs/tests -p 'test_*.py' -v

# Optional Nim unit tier (enum maps / pure parsers). Not part of `make test`
# so CI and bare hosts without nim stay green. PATH-nim first, else nix develop
# if a flake appears later (same pattern as crewrift-prime-bots).
test-nim:
	@if command -v nim >/dev/null 2>&1; then \
		rc=0; \
		for t in system/tests/test_*.nim; do \
			echo "== $$t =="; \
			nim r --hints:off --warnings:off "$$t" || rc=1; \
		done; \
		exit $$rc; \
	elif [ -f flake.nix ] || [ -f shell.nix ]; then \
		rc=0; \
		for t in system/tests/test_*.nim; do \
			echo "== $$t =="; \
			nix develop --command nim r --hints:off --warnings:off "$$t" || rc=1; \
		done; \
		exit $$rc; \
	else \
		echo "error: nim not on PATH and no flake/shell.nix fallback" >&2; exit 1; \
	fi

# The System: mummy dashboard + MCPort on :7777 (see system/README.md).
# Needs a running realm for live roster data (docker exec → mariadb SELECT).
system:
	@if command -v nim >/dev/null 2>&1; then \
		nim r system/system_server.nim; \
	elif [ -f flake.nix ] || [ -f shell.nix ]; then \
		nix develop --command nim r system/system_server.nim; \
	else \
		echo "error: nim not on PATH and no flake/shell.nix fallback" >&2; exit 1; \
	fi

# Pin-drift only: HEAD of ../coworld-vanilla-wow must match upstream.lock.
# Also checks files brain/upstream.py imports still exist.
pin-check:
	@if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi
	@cd "$(CURDIR)" && uv run --project "$(UPSTREAM)" python -m unittest \
		tests.integration.test_pin_drift -v

# Integration tier: pin-check + recorded wire_*.bin replay through real
# EnvironmentFrame (upstream client) → frame_projection → lua tools → intent_mapping.
# No live services, no docker, no realm. Needs uv + upstream project deps + lua5.3.
# Never wired into `make test` (unit stays instant / stdlib-only).
integration-test: pin-check
	@cd "$(CURDIR)" && uv run --project "$(UPSTREAM)" python -m unittest discover \
		-s tests/integration -p 'test_*.py' -v

# Live shadow brain against a running nim_control socket (not unit tier).
# Requires: realm up, headless reference player, uv + upstream project deps.
# Example:
#   make shadow SLOT=0 LEADER=Botpriest PARTY=Botpriest,Botwarrior EXTRA='--move-fallback --max-seconds 60'
SLOT ?= 0
LEADER ?= Botpriest
PARTY ?= Botpriest,Botwarrior
EXTRA ?=
shadow:
	@cd "$(CURDIR)" && uv run --project "$(UPSTREAM)" python -m brain.shadow \
		--slot $(SLOT) --leader-name $(LEADER) --party-members $(PARTY) $(EXTRA)

# Escort army: Nim host + Lua escort_leader (NO PYTHON decide path).
# Accept invites + follow formation + assist/attack leader target.
# Do NOT also run party_butler on the same slot.
# Docs: docs/rolling-issues-2026-07-26.md
#
#   make escort SLOT=2 EXTRA='--max-seconds 120'
#   make escort-army
#
# Legacy Python host (brain.shadow) kept as escort-python for one-off debug only.
ESCORT_LEADER ?= Murist
# Full 5-man cast: human + 2 locks + warrior tank + priest healer.
ESCORT_PARTY ?= Murist,Shadowfel,Igris,Tusk,Beru
ESCORT_ACCEPT_FROM ?= Murist
# Prefer fork SDK when the fork checkout exists (matches igris/warlock-bot-fork seats).
ESCORT_UPSTREAM ?= $(shell if [ -d "$(abspath ../coworld-vanilla-wow-fork)" ]; then echo $(abspath ../coworld-vanilla-wow-fork); else echo $(UPSTREAM); fi)

# Nim army host (no Python decide loop). Binary: tools/army_host
.PHONY: army-host army-host-build escort-army-nim grind-army-nim escort escort-army escort-python
army-host-build:
	@nim c --hints:off -o:tools/army_host tools/army_host.nim

army-host: army-host-build
	@./tools/army_host --slot=$(SLOT) --tool=$(or $(TOOL),escort_leader) --leader=$(or $(ESCORT_LEADER),Murist) \
		--party=$(or $(ESCORT_PARTY),Murist,Shadowfel,Igris,Tusk,Beru) --goal-id=army-slot-$(SLOT) \
		--cadence=$(or $(CADENCE),0.35) --accept-from=$(or $(ESCORT_ACCEPT_FROM),Murist) $(EXTRA)

# Single-seat escort (default standing path: Nim + Lua).
escort: army-host-build
	@./tools/army_host --slot=$(SLOT) --tool=escort_leader --leader=$(or $(ESCORT_LEADER),Murist) \
		--party=$(or $(ESCORT_PARTY),Murist,Shadowfel,Igris,Tusk,Beru) --goal-id=army-slot-$(SLOT) \
		--cadence=$(or $(CADENCE),0.35) --accept-from=$(or $(ESCORT_ACCEPT_FROM),Murist) $(EXTRA)

# Legacy Python escort (debug only — not the standing army path).
escort-python:
	@cd "$(CURDIR)" && \
	UP=$${WOW_SHADOW_UPSTREAM:-$(ESCORT_UPSTREAM)}; \
	uv run --project "$$UP" env WOW_SHADOW_UPSTREAM="$$UP" python -m brain.shadow \
		--slot $(SLOT) --leader-name $(ESCORT_LEADER) --party-members $(ESCORT_PARTY) \
		--tool escort_leader --accept-from $(ESCORT_ACCEPT_FROM) \
		--goal-id escort-slot-$(SLOT) $(EXTRA)

# Standing army on Nim host (kills legacy python shadows first).
escort-army-nim: army-host-build
	@mkdir -p local_data/brain-logs
	@-pkill -f 'brain.shadow --slot [2345]' 2>/dev/null || true
	@-pkill -f 'tools/army_host --slot' 2>/dev/null || true
	@sleep 1
	@for s in 2 3 4 5; do \
		nohup ./tools/army_host --slot=$$s --tool=escort_leader --leader=$(or $(ESCORT_LEADER),Murist) \
			--party=Murist,Shadowfel,Igris,Tusk,Beru --goal-id=army-slot-$$s --cadence=0.35 \
			--accept-from=$(or $(ESCORT_ACCEPT_FROM),Murist) > local_data/brain-logs/army-slot$$s.log 2>&1 & \
		echo $$! > local_data/brain-logs/army-slot$$s.pid; \
	done; \
	echo "army_host pids: $$(cat local_data/brain-logs/army-slot{2,3,4,5}.pid 2>/dev/null)"; \
	echo "logs: local_data/brain-logs/army-slot{2,3,4,5}.log"

# Default standing-army launch = Nim (alias of escort-army-nim).
escort-army: escort-army-nim

grind-army-nim: army-host-build
	@mkdir -p local_data/brain-logs
	@-pkill -f 'tools/army_host --slot' 2>/dev/null || true
	@-pkill -f 'brain.shadow --slot [2345]' 2>/dev/null || true
	@sleep 1
	@for s in 2 3 4 5; do \
		nohup ./tools/army_host --slot=$$s --tool=grind_nearest --leader=$(or $(ESCORT_LEADER),Murist) \
			--party=Murist,Shadowfel,Igris,Tusk,Beru --goal-id=grind-slot-$$s --cadence=0.3 \
			> local_data/brain-logs/grind-slot$$s.log 2>&1 & \
		echo $$! > local_data/brain-logs/grind-slot$$s.pid; \
	done; \
	echo "grind army started"

# Mob-grinding brain (docs/warlock-seat.md). Drives a seat entirely from OUR
# policy using the goal-independent generic action masks, so it works for
# classes the upstream leveling planner refuses (an undead warlock resolves
# `unsupported_profile` and the planner noops forever — that only silences
# `recommended_action`, it does not close the masks).
#
#   make grind SLOT=2 CHARACTER=Shadowfel EXTRA='--max-seconds 600'
#
# Safety: `--avoid-names` defaults to Murist. Bots never address the human's
# character. `--leash` keeps the bot near its anchor so a chase cannot walk it
# into his play area.
CHARACTER ?= Shadowfel
grind:
	@cd "$(CURDIR)" && uv run --project "$(UPSTREAM)" python -m brain.grind \
		--slot $(SLOT) --character $(CHARACTER) $(EXTRA)

# Form a real party across two or more of OUR headless seats (docs/party-formation.md).
# `invite_party` is only unmasked while the leader seat holds a dungeon goal whose
# declared roster is incomplete (upstream environment_frame.nim:1230 is the only
# enabler); `accept_party` needs nothing but a pending invite plus any goal.
# Requires: realm up + one running reference player per slot below.
#
#   make party-form LEADER_SLOT=0 LEADER=Botwarrior MEMBERS=Botwarrior,Botpriest MEMBER_SLOTS=1
#
# MEMBER_SLOTS lists only the seats WE drive; leave it empty for members we do
# not control. NEVER put a human character in MEMBERS — bots do not address the
# human's character (see docs/party-formation.md).
# PARTY_LEADER is separate from `shadow`'s LEADER on purpose: it must name the
# character logged in on LEADER_SLOT, or the reducer stays at noop.
LEADER_SLOT ?= 0
PARTY_LEADER ?= Botwarrior
MEMBERS ?= Botwarrior,Botpriest
MEMBER_SLOTS ?= 1
party-form:
	@cd "$(CURDIR)" && uv run --project "$(UPSTREAM)" python -m brain.party \
		--leader-slot $(LEADER_SLOT) --leader $(PARTY_LEADER) \
		--members $(MEMBERS) --member-slots $(MEMBER_SLOTS) $(EXTRA)

# Build the Detour navmesh helper (docs/navmesh.md). Compile-only: it links
# VMaNGOS's vendored Detour against the mmaps we already extracted — no mmap
# generation, no server build. Idempotent; ~30s. Needs the sparse vmangos/core
# checkout in $(VMANGOS_CORE_DIR) (see docs/navmesh.md for the clone recipe).
navmesh-helper:
	@set -e; \
	if [ ! -d "$(VMANGOS_CORE_DIR)/dep/recastnavigation/Detour" ]; then \
		echo "error: Detour sources missing: $(VMANGOS_CORE_DIR)/dep/recastnavigation/Detour" >&2; \
		echo "see docs/navmesh.md for the sparse vmangos/core clone recipe" >&2; \
		exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	VMANGOS_CORE_DIR="$(VMANGOS_CORE_DIR)" \
	nim r player/sdk/helpers/build_vmangos_navmesh.nim -- "$(VANILLA_WOW_NAVMESH_HELPER)"

# One-shot readiness probe: helper binary + mmap inventory, no realm needed.
navmesh-status:
	@printf '{"op":"status","mmaps_dir":"%s/mmaps"}' "$(VANILLA_WOW_EXTRACTED_DATA_DIR)" \
		| "$(VANILLA_WOW_NAVMESH_HELPER)"

# DB breadcrumb poller: JSONL session stream from characters MariaDB while a
# human plays. Requires realm up (docker exec → mariadb). Not unit tier.
# Example: make breadcrumbs CHARACTER=Murist
CHARACTER ?= Murist
breadcrumbs:
	@python3 breadcrumbs/poller.py --character "$(CHARACTER)"

# Regenerate addons/ShadowArmy/QuestData.lua from the world DB + WorldMapArea.dbc
# (docs/quest-data.md). Read-only DB access; requires the realm up. Deterministic,
# so a no-op rerun leaves the file byte-identical. Scope with:
#   make quest-data QUEST_DATA_ARGS="--max-level 20"
#   make quest-data QUEST_DATA_ARGS="--zones 85,130,12"
QUEST_DATA_ARGS ?=
quest-data:
	@python3 tools/gen_quest_data.py \
		--dbc-dir "$(VANILLA_WOW_EXTRACTED_DATA_DIR)/dbc" $(QUEST_DATA_ARGS)

# Bring up the local VMaNGOS/Coworld realm, then attach to container logs.
# Operator `up` is detached (compose up -d). Ctrl-C only detaches from logs;
# containers keep running. Use `make stop-server` to stop cleanly.
# Idempotent when already up. No --build (use upstream rebuild workflows if
# images are missing).
start-server:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	$(OPERATOR) up; \
	echo ""; \
	echo "Realm up (detached). Attaching logs for coworld-game."; \
	echo "Ctrl-C detaches logs only — containers keep running."; \
	echo "Stop cleanly with: make stop-server"; \
	echo ""; \
	docker compose -f "$(COMPOSE_FILE)" --profile coworld logs -f coworld-game

# Stop the coworld-game service (compose rm --stop). Does not wipe volumes
# (character/account DB state persists). Never docker kill.
stop-server:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	$(OPERATOR) down

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

# Launch the native client for HUMAN play against the local realm.
# --login-screen: land at GlueXML login (no auto world entry). Credentials are
# omitted on purpose — with --login-screen the launcher does not forward
# --username/--password to the player; without --login-screen a local realm
# fills COWORLD/Nightsun for direct world entry. Type monofuel/password at
# the door (see make account). Do not run unattended (opens a GUI).
play:
	@set -e; \
	if [ ! -d "$(UPSTREAM)" ]; then \
		echo "error: upstream checkout missing: $(UPSTREAM)" >&2; exit 1; \
	fi; \
	if [ ! -f "$(WOW_ENV)" ]; then \
		echo "error: missing $(WOW_ENV)" >&2; exit 1; \
	fi; \
	cd "$(UPSTREAM)"; \
	nix shell nixpkgs\#nginx --command sh -c \
		'. "$(WOW_ENV)"; nim r tools/launch_nim_player.nim -- \
			--login-screen \
			--realm-host=127.0.0.1 \
			--realm-port=3724 \
			--world-port=8085'

# Launch the GENUINE 1.12.1 client under wine against the local realm
# (see docs/play-classic.md). First run assembles local_classic/ (Data/
# symlinked from wow-classic-data, WTF/Interface copied) and inits a wine
# prefix. Login monofuel / password. Do not run unattended (opens a GUI).
play-classic:
	@nix develop --command tools/play_classic.sh

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

# Bring the full 5-man bot side online (accounts if needed + 4 headless seats).
# Human (Murist) is still classic client. Does NOT start escort brains —
# run `make escort-army` after seats print "listening".
party-army:
	@set -e; \
	$(MAKE) tusk-account; \
	$(MAKE) beru-account; \
	mkdir -p "$(CURDIR)/local_data/brain-logs"; \
	echo "starting headless seats (fork): Shadowfel:2 Igris:3 Tusk:4 Beru:5"; \
	nohup $(MAKE) warlock-bot-fork > local_data/warlock-bot.log 2>&1 & echo $$! > local_data/brain-logs/warlock-bot.pid; \
	nohup $(MAKE) igris-bot > local_data/igris-bot.log 2>&1 & echo $$! > local_data/brain-logs/igris-bot.pid; \
	nohup $(MAKE) tusk-bot > local_data/tusk-bot.log 2>&1 & echo $$! > local_data/brain-logs/tusk-bot.pid; \
	nohup $(MAKE) beru-bot > local_data/beru-bot.log 2>&1 & echo $$! > local_data/brain-logs/beru-bot.pid; \
	echo "bot pids: $$(cat local_data/brain-logs/warlock-bot.pid) $$(cat local_data/brain-logs/igris-bot.pid) $$(cat local_data/brain-logs/tusk-bot.pid) $$(cat local_data/brain-logs/beru-bot.pid)"; \
	echo "wait for :41116–:41119 listening, then: make escort-army"; \
	echo "invite order in-game (Murist): Shadowfel, Igris, Tusk, Beru"

# ---------------------------------------------------------------------------
# Our fork of coworld-vanilla-wow (docs/coworld-fork.md): thin rebase layer
# carrying the SMSG_SET_FACTION_STANDING crash fix. Builds the three
# shadow-army-tagged images serially (each can saturate the box). Never
# touches the stock :local tags or the running realm — switch-over is a
# human-run retag, see docs/coworld-fork.md.
FORK := $(abspath ../coworld-vanilla-wow-fork)
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
