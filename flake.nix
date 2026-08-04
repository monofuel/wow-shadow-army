{
  # Dev shell for wow-shadow-army. Today: wine (32+64-bit) for the genuine
  # 1.12 client (make play-classic). Structured to grow — nim/lua can join
  # the same shell later.
  description = "wow-shadow-army dev tooling";

  # Pinned to the host's nixpkgs rev (26.05) so wineWowPackages comes from
  # the binary cache — nixos-unstable resolved to a rev that builds wine
  # from source (~an hour). Bump deliberately, not by re-locking blind.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b3fe9581c9061c749abef42b6d4ee7b7c05c33fa";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          # WoW 1.12 is a 32-bit exe; wineWowPackages ships both arches.
          pkgs.wineWowPackages.stable
          # Loopback capture for make play-classic-netlog (run under sudo —
          # the store binary carries no CAP_NET_RAW file capability).
          pkgs.tcpdump
        ];
      };
    };
}
