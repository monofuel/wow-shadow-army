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
      ];
      libPath = pkgs.lib.makeLibraryPath runtimeLibs;
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
          which
        ];

        shellHook = ''
          export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
          export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          export LIBRARY_PATH="${pkgs.openssl.out}/lib:${pkgs.bzip2.out}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export C_INCLUDE_PATH="${pkgs.openssl.dev}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
        '';
      };
    };
}
