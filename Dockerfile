# Ibis — hosted Traverse policy (army_host + Lua Travel Form / north hop).
#
# Softmax injects COWORLD_PLAYER_WS_URL (…/player?slot=&token=). army_host
# rewrites /player → /env and attaches over WS (see coworld_manifest_template
# player protocol text). Same packaging shape as bot-crewrift-mammet /
# bot-CueNWoo-mammet: self-contained image, CMD is the policy binary.
#
#   docker build --platform=linux/amd64 -t ibis:latest .
#   uv run coworld upload-policy ibis:latest --name ibis
#   uv run --extra dev vanilla-wow submit ibis:vN \
#     --league league_0f38d762-930a-41d3-9979-1858dd52c1ae --json

# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim AS build

ARG NIMBY_VERSION=0.1.27
ARG NIM_VERSION=2.2.10
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gcc git libc6-dev libssl-dev \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.nimby/nim/bin:${PATH}"
RUN case "${TARGETARCH}" in \
      amd64|"") nimby_asset="nimby-Linux-X64" ;; \
      arm64) nimby_asset="nimby-Linux-ARM64" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL -o /usr/local/bin/nimby \
      "https://github.com/treeform/nimby/releases/download/${NIMBY_VERSION}/${nimby_asset}" \
  && chmod +x /usr/local/bin/nimby \
  && nimby use "${NIM_VERSION}"

WORKDIR /build
COPY tools/army_host.nim tools/env_transport.nim tools/msgpack_json.nim \
     tools/fair_play_audit.nim ./
RUN nim c -d:release -d:ssl --hints:off --stackTrace:on --lineTrace:on \
      -o:/build/army_host army_host.nim

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl3 lua5.3 \
  && rm -rf /var/lib/apt/lists/* \
  && ln -sf /usr/bin/lua5.3 /usr/local/bin/lua \
  && ln -sf /usr/bin/lua5.3 /usr/local/bin/lua5.3

WORKDIR /app
COPY --from=build /build/army_host /bin/army_host
COPY lua/ /app/lua/
COPY tools/ibis_entry.sh /bin/ibis_entry.sh
RUN chmod +x /bin/ibis_entry.sh /bin/army_host

# Hosted traverse defaults; COWORLD_PLAYER_WS_URL supplies host/slot/token.
ENV ARMY_MODE=traverse

CMD ["/bin/ibis_entry.sh"]
