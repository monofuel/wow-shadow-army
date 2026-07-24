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

.PHONY: test test-lua integration-test start-server stop-server account play

test: test-lua

test-lua:
	@rc=0; for t in lua/tests/test_*.lua; do \
		echo "== $$t"; LUA_PATH="lua/?.lua;lua/tools/?.lua;;" $(RUN_LUA) $$t || rc=1; \
	done; exit $$rc

integration-test:
	@echo "integration tier not wired yet: needs local realm + a bot seat (docs/control-plane.md)"; exit 1

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
