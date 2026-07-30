{
  description = "The mechanism for deciding a thing is unhealthy and raising an alarm about it: named liveness checks (probe or heartbeat), a staleness deadline per check, gate relationships so one shared root cause pages once instead of fanning out, and dispatch through a named nixpush channel. Not a notification transport, not a metrics/observability stack, not any one estate's monitoring policy -- see README.md.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Deliberately NO nixpush input. nixwatch names a nixpush channel and reads
    # `config.nixpush.{enable,channels,package}` defensively at eval time (see
    # modules/default.nix's own header) -- the same "read a sibling by name, never as a flake
    # input" convention this design-system family uses between PEER repos, reserved for
    # genuinely lower layers instead (this family's own examples: nixvps, nixtest).
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      nixosModules.nixwatch = ./modules/default.nix;
      nixosModules.default = self.nixosModules.nixwatch;

      # The pure duration parser, exposed standalone -- the same "expose the builder function
      # for anyone who wants it without the module system" reasoning nixstorage uses for its
      # own `lib.buildLayoutImage`/`lib.partitionRoles`.
      lib.parseDurationSeconds = (import ./lib/duration.nix { inherit lib; }).toSeconds;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixwatchModule = self.nixosModules.nixwatch;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
