{
  # Dev shell for wow-shadow-army. Everything ops-related goes through
  # `nix develop --command …` so agents/systemd do not hand-roll openssl/nginx
  # paths (pattern: Softmax/metta flake — one hermetic shell, no manual fuckery).
  description = "wow-shadow-army dev tooling";

  # Pinned to the host's nixpkgs rev (26.05) so wine packages come from the
  # binary cache. Bump deliberately, not by re-locking blind.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b3fe9581c9061c749abef42b6d4ee7b7c05c33fa";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      # Runtime libs for nim clients (env_host, live admin viewer, windy stack).
      runtimeLibs = with pkgs; [
        openssl
        zlib
        bzip2
        libx11
        libxcursor
        libxrandr
        libxi
        libxext
        libGL
        # libcurl, loaded at runtime by Curly (tools/bot_requests.nim).
        curl
      ];
      libPath = pkgs.lib.makeLibraryPath runtimeLibs;
      dockerfileLines = pkgs.lib.splitString "\n" (builtins.readFile ./Dockerfile);
      nimVersionLine = pkgs.lib.findFirst
        (line: pkgs.lib.hasPrefix "ARG NIM_VERSION=" line)
        (throw "Dockerfile must pin NIM_VERSION")
        dockerfileLines;
      pinnedNim = pkgs.lib.removePrefix "ARG NIM_VERSION=" nimVersionLine;
    in {
      devShells.${system}.default = pkgs.mkShell {
        name = "wow-shadow-army";

        packages = with pkgs; [
          # Dashboard / bot host
          nim
          pkg-config
          # Lua tools (army_host decide subprocess)
          lua5_3
          # Upstream watch_bots + env-host link
          openssl
          bzip2
          nginx
          uv
          # Python tool tests; Pillow lets test_minimap_mask decode tiles
          # instead of skipping.
          (python3.withPackages (ps: [ ps.pillow ]))
          # Private headless display (Xvfb + xauth) for map_browser
          # MAP_BROWSER_AUTO renders.
          xvfb-run
          # WoW 1.12 needs multi-arch wine (32+64).
          wineWow64Packages.stable
          # Loopback capture for make play-classic-netlog (often needs sudo).
          tcpdump
          # Ops helpers used by Makefile / dashboard detaches
          coreutils
          bash
          gnumake
          git
          curl
          jq
          which
        ];

        shellHook = ''
          export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
          export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          # The fork's headed player links -l:libjemalloc.so.2. The ld wrapper
          # only derives RUNPATHs for -lname, so the jemalloc RUNPATH is explicit.
          # Never on LD_LIBRARY_PATH: it would shadow tools that carry their own
          # prefixed jemalloc (uv).
          export LIBRARY_PATH="${pkgs.openssl.out}/lib:${pkgs.bzip2.out}/lib:${pkgs.jemalloc}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export NIX_LDFLAGS="''${NIX_LDFLAGS:+$NIX_LDFLAGS }-rpath ${pkgs.jemalloc}/lib"
          export C_INCLUDE_PATH="${pkgs.openssl.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
          # Home lua-bot seats build the fork's unheaded player from this shell
          # (it carries the nginx the local asset path needs); the fork's
          # launcher adds -d:LuaBotLuaPrefix from this, as the fork's own shell
          # does.
          export COWORLD_LUA_BOT_LUA_PREFIX="${pkgs.lua5_3}"
          export LIBRARY_PATH="${pkgs.lua5_3}/lib:$LIBRARY_PATH"
          # Nim deps live in the dedicated wow-coworld Nimby global profile,
          # shared with the client fork; config.nims reads its generated
          # nim.cfg. Explicit overrides win.
          export NIMBY_HOME="''${NIMBY_HOME:-$HOME/.nimby/profiles/wow-coworld}"
          export NIMBY_PKGS_DIR="''${NIMBY_PKGS_DIR:-$NIMBY_HOME/pkgs}"
          # Prefer the Nim the Dockerfile pins (the fork's pin too) over
          # nixpkgs' nim, without touching the shared ~/.nimby/nim default.
          for pinnedNimBin in "$NIMBY_HOME/nim-${pinnedNim}/bin" "$HOME/.nimby/nim-${pinnedNim}/bin"; do
            if [ -x "$pinnedNimBin/nim" ]; then
              export PATH="$pinnedNimBin:$PATH"
              break
            fi
          done
          if [ ! -x "$pinnedNimBin/nim" ]; then
            echo "wow-shadow-army: Nim ${pinnedNim} missing; install it under $NIMBY_HOME/nim-${pinnedNim}/bin" >&2
          fi
        '';
      };
    };
}
