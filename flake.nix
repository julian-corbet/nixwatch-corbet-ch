{
  description = "Both halves of knowing whether a host is healthy: the outside-in alarm half -- named liveness checks (probe or heartbeat), a staleness deadline per check, gate relationships so one shared root cause pages once instead of fanning out, dispatched through a named nixpush channel -- and the in-cluster observability half, metrics and dashboards and traces, which explains afterwards what the alarm only announced. Never a notification transport (delivery is nixpush's job, no API keys here), and never any one operator's monitoring policy -- see README.md.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Deliberately NO nixpush input. nixwatch names a nixpush channel and reads
    # `config.nixpush.{enable,channels,package}` defensively at eval time (see
    # modules/default.nix's own header) -- the same "read a sibling by name, never as a flake
    # input" convention this design-system family uses between PEER repos, reserved for
    # genuinely lower layers instead (this family's own examples: nixvps, nixtest).

    # CHECKS-ONLY, both of them, and that is the point being proven rather than a shortcut. A
    # consumer of the cluster half imports the app grammar itself, exactly as it imports this
    # flake; these inputs exist so `nix flake check` can render modules/cluster.nix through the
    # REAL grammar and the REAL renderer and then assert the manifests that come out -- instead
    # of asserting that a module which merely mentions `nixk3s.apps` evaluates.
    #
    # Nothing this flake EXPORTS reaches into either of them, so a host importing
    # `nixosModules.nixwatch` never pulls a renderer into its closure.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # THE CLUSTER CHECKS EXIST ON ONE SYSTEM, DELIBERATELY, and it is worth being precise about
      # why rather than letting it look like an oversight.
      #
      # The renderer parses schemas through import-from-derivation: EVALUATING the cluster checks
      # requires BUILDING a YAML parser for the system they are declared under. A machine cannot
      # build for another architecture without emulation, so declaring them for both would not check
      # anything twice -- it would make `nix flake check --all-systems` fail on whichever
      # architecture CI is not running, with a platform mismatch that says nothing about this
      # repository.
      #
      # And there is nothing to gain from the second copy: what these checks assert is rendered
      # YAML, whose content does not vary by architecture at all. That is exactly NOT true of the
      # host half, which composes a real NixOS system, so those checks stay on both.
      clusterCheckSystem = "x86_64-linux";
    in
    {
      # The ALARM half: each host's own timers, outside everything they watch.
      nixosModules.nixwatch = ./modules/default.nix;
      nixosModules.default = self.nixosModules.nixwatch;

      # The OBSERVABILITY half, plus the one piece of the alarm path that lives in a cluster.
      # Composed into a nixidy environment ALONGSIDE the app grammar, which declares the options
      # this module defines into -- see modules/cluster.nix's own header. The two halves share no
      # evaluation, which is the strongest possible form of "the alarm path does not depend on the
      # observability path": there is no import between them in either direction.
      nixidyModules.nixwatch = ./modules/cluster.nix;
      nixidyModules.default = self.nixidyModules.nixwatch;

      # The cluster catalogue, for inspection without re-reading the file.
      lib.observability = import ./lib/observability.nix { };

      # The pure duration parser, exposed standalone -- the same "expose the builder function
      # for anyone who wants it without the module system" reasoning nixstorage uses for its
      # own `lib.buildLayoutImage`/`lib.partitionRoles`.
      lib.parseDurationSeconds = (import ./lib/duration.nix { inherit lib; }).toSeconds;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system nixidy;
          withCluster = system == clusterCheckSystem;
          nixwatchModule = self.nixosModules.nixwatch;
          clusterModule = self.nixidyModules.nixwatch;
          appsModule = nixk3s.nixidyModules.apps;
          addressingModule = nixk3s.nixidyModules.addressing;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
