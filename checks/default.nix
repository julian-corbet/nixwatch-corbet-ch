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
#   A BUILD-LEVEL behavioral proof (checks/behavior.nix, exported separately as
#   `behavior-proof`): the one thing this repo has that an eval-only test cannot see --
#   `lib/runner.nix`'s generated script's actual, repeated-invocation, stateful behavior.
#   See that file's own header for why it calls the plain builder function directly rather
#   than going through a NixOS eval-config.
#
# PLUS `modules-evaluate`: the composed-host check (examples/host/configuration.nix), the
# same "every real, implemented option, once" shape nixstorage's own checks/default.nix uses.
{ pkgs, lib, nixpkgs, system, nixwatchModule }:

let
  durationResults = import ./duration.nix { inherit lib; };
  assertionResults = import ./assertions.nix {
    inherit pkgs lib nixpkgs system nixwatchModule;
  };

  results = durationResults ++ assertionResults;

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
in
{
  inherit eval-tests modules-evaluate;
  behavior-proof = import ./behavior.nix { inherit pkgs lib system; };
}
