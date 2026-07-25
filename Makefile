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

OPERATOR := uv run python server/scripts/docker_vmangos_server.py
COMPOSE_FILE := infra/compose.vmangos.yml
# Human playtest account (type at the GlueXML login screen).
ACCOUNT_USER := monofuel
ACCOUNT_PASS := password

.PHONY: test test-lua test-python test-nim system pin-check integration-test start-server stop-server server-logging logs account soap-account play play-classic shadow breadcrumbs

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

# DB breadcrumb poller: JSONL session stream from characters MariaDB while a
# human plays. Requires realm up (docker exec → mariadb). Not unit tier.
# Example: make breadcrumbs CHARACTER=Murist
CHARACTER ?= Murist
breadcrumbs:
	@python3 breadcrumbs/poller.py --character "$(CHARACTER)"

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
