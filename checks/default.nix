# checks/default.nix
#
# Three kinds of test, combined into the flake outputs `nix flake check` runs:
#
#   EVAL-TIME assertion tests (checks/assertions.nix, folded into `eval-tests` below): each
#   evaluates a real configuration through NixOS's own eval-config.nix and asks whether
#   forcing `system.build.toplevel` fails. Nothing here runs a generated script.
#
#   PURE FUNCTION tests (checks/duration.nix, folded into the same `eval-tests`): no NixOS
#   eval anywhere -- `lib/duration.nix`'s `toSeconds` is a plain function, tested as one.
#
#   checks/liveness-assertions.nix (also folded into `eval-tests`): the same eval-time
#   assertion shape as checks/assertions.nix, for `modules/liveness.nix`'s own option surface
#   (`nixwatch.liveness.*`) instead of `nixwatch.checks.*`.
#
#   A BUILD-LEVEL behavioral proof (checks/behavior.nix, exported separately as
#   `behavior-proof`): the one thing this repo has that an eval-only test cannot see --
#   `lib/runner.nix`'s generated script's actual, repeated-invocation, stateful behavior.
#   See that file's own header for why it calls the plain builder function directly rather
#   than going through a NixOS eval-config. checks/liveness-behavior.nix (exported separately
#   as `liveness-behavior-proof`) is the same idea for `lib/liveness.nix`'s generated
#   `nixwatch-is-it-live` script.
#
#   A TWO-BOOT VM proof (`checks/timer-reboot.nix`) delays timers.target beyond a check's
#   interval on both boots, preserving /var between them. It proves the timer still runs in
#   the second boot rather than becoming `active (elapsed)` against cross-boot state.
#
# PLUS `modules-evaluate`: the composed-host check (examples/host/configuration.nix), the
# same "every real, implemented option, once" shape nixstorage's own checks/default.nix uses.
#
# AND THE CLUSTER HALF, which needs neither NixOS nor a host at all: `cluster-eval` and
# `cluster-render` compose modules/cluster.nix into a real nixidy environment beside the real app
# grammar (checks/cluster-eval.nix, checks/cluster-render.nix -- see their own headers). They are
# built from examples/cluster/values.nix, so a module that stops evaluating, or that grows a
# required value nobody supplies, fails in CI rather than in somebody's cluster. `withCluster` is
# false on every system but the one they are declared under -- see flake.nix for why declaring them
# twice would check nothing twice and break `--all-systems` instead.
{ pkgs
, lib
, nixpkgs
, system
, nixwatchModule
, nixidy
, clusterModule
, appsModule
, addressingModule
, withCluster
}:

let
  durationResults = import ./duration.nix { inherit lib; };
  assertionResults = import ./assertions.nix {
    inherit pkgs lib nixpkgs system nixwatchModule;
  };
  livenessAssertionResults = import ./liveness-assertions.nix {
    inherit pkgs lib nixpkgs system nixwatchModule;
  };

  results = durationResults ++ assertionResults ++ livenessAssertionResults;

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixwatch eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
    # Depending on `passedCount` forces `results`, so the tests genuinely run under
    # `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixwatch-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixwatch eval tests passed"
          touch $out
        '';

  # The composed-host check: nixwatch alone (no nixpush anywhere -- see
  # examples/host/configuration.nix's own header for why that absence is itself the point)
  # against every real, implemented option at once.
  composedHost = lib.nixosSystem {
    inherit system;
    modules = [
      nixwatchModule
      ../examples/host/configuration.nix
    ];
  };

  modules-evaluate =
    pkgs.writeText "nixwatch-host-drvpath"
      (builtins.unsafeDiscardStringContext composedHost.config.system.build.toplevel.drvPath);

  # The cluster half, rendered through the real grammar and the real renderer, from the placeholder
  # values in examples/. Building the environment package forces the whole manifest tree.
  clusterEnv = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [
      appsModule
      addressingModule
      clusterModule
      ../examples/cluster/values.nix
    ];
  };
in
{
  inherit eval-tests modules-evaluate;
  behavior-proof = import ./behavior.nix { inherit pkgs lib system; };
  liveness-behavior-proof = import ./liveness-behavior.nix { inherit pkgs lib system; };
}
// lib.optionalAttrs (system == "x86_64-linux") {
  timer-reboot-proof = import ./timer-reboot.nix { inherit pkgs nixwatchModule; };
}
  // lib.optionalAttrs withCluster {
  cluster-eval = import ./cluster-eval.nix {
    inherit pkgs lib nixidy clusterModule appsModule addressingModule;
  };

  cluster-render = import ./cluster-render.nix { inherit pkgs lib; env = clusterEnv; };
}
