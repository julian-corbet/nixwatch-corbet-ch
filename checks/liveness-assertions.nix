# checks/liveness-assertions.nix
#
# Eval-time checks for modules/liveness.nix: each evaluates a real configuration through
# NixOS's own eval-config.nix and asks whether forcing `system.build.toplevel` fails. Same
# shape and same reasoning as checks/assertions.nix (nothing here boots or runs anything --
# assertions are an eval-time property), kept in its own file because it exercises a distinct
# option surface (`nixwatch.liveness.*`) with its own fixtures, not `nixwatch.checks.*`.
{ pkgs, lib, nixpkgs, system, nixwatchModule }:

let
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  evalNixwatch = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [ nixwatchModule extraConfig bareStubs ];
    }).config;

  buildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixwatch extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A small, complete, VALID subject -- every "and one thing about it is wrong" fixture below
  # starts from this and mutates exactly one field, same convention as checks/assertions.nix's
  # own `validCheck`.
  validSubject = {
    moduleEnabled = true;
    units = [ "example.service" ];
  };
in
[
  # --- healthFile and verifyUnit are mutually exclusive -------------------------------------
  (check "liveness/healthfile-and-verifyunit-together-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.liveness.enable = true;
      nixwatch.liveness.subjects.example = validSubject // {
        healthFile = "/run/example/health.json";
        verifyUnit = "example-verify.service";
      };
    })
    "expected a subject setting both healthFile and verifyUnit to fail the build, but it succeeded")

  (check "liveness/healthfile-alone-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.liveness.enable = true;
        nixwatch.liveness.subjects.example = validSubject // {
          healthFile = "/run/example/health.json";
        };
      })
    )
    "a subject with only healthFile set should never fail the build on its own")

  (check "liveness/verifyunit-alone-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.liveness.enable = true;
        nixwatch.liveness.subjects.example = validSubject // {
          verifyUnit = "example-verify.service";
        };
      })
    )
    "a subject with only verifyUnit set should never fail the build on its own")

  # --- healthDomain requires healthFile ------------------------------------------------------
  (check "liveness/healthdomain-without-healthfile-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.liveness.enable = true;
      nixwatch.liveness.subjects.example = validSubject // {
        healthDomain = "firewall";
      };
    })
    "expected healthDomain with no healthFile to fail the build, but it succeeded")

  (check "liveness/healthdomain-with-healthfile-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.liveness.enable = true;
        nixwatch.liveness.subjects.example = validSubject // {
          healthFile = "/run/example/health.json";
          healthDomain = "firewall";
        };
      })
    )
    "healthDomain paired with a real healthFile should never fail the build on its own")

  # --- a subject must declare at least one thing to actually check --------------------------
  (check "liveness/subject-with-nothing-to-check-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.liveness.enable = true;
      nixwatch.liveness.subjects.example = {
        moduleEnabled = true;
      };
    })
    "expected a subject with no units, healthFile, or verifyUnit to fail the build, but it succeeded")

  (check "liveness/subject-with-only-units-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.liveness.enable = true;
        nixwatch.liveness.subjects.example = {
          moduleEnabled = true;
          units = [ "example.service" ];
        };
      })
    )
    "a subject declaring only units (no healthFile/verifyUnit) should never fail the build on its own -- its artifact freshness just reads UNKNOWN at runtime")

  # --- interval: same duration grammar as checks.<name>.interval ----------------------------
  (check "liveness/malformed-interval-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.liveness.enable = true;
      nixwatch.liveness.interval = "banana";
      nixwatch.liveness.subjects.example = validSubject;
    })
    "expected an unparsable nixwatch.liveness.interval to fail the build, but it succeeded")

  (check "liveness/well-formed-interval-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.liveness.enable = true;
        nixwatch.liveness.interval = "10m";
        nixwatch.liveness.subjects.example = validSubject;
      })
    )
    "a well-formed nixwatch.liveness.interval should never fail the build on its own")

  # --- disabled module still builds fine, with no units/healthFile/verifyUnit required either
  (check "liveness/disabled-module-subject-with-nothing-declared-still-requires-a-signal"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.liveness.enable = true;
      nixwatch.liveness.subjects.example = {
        moduleEnabled = false;
      };
    })
    "expected a subject with no units/healthFile/verifyUnit to fail the build even when moduleEnabled = false -- the assertion is about what the subject CAN EVER check, not about today's enabled state, since flipping moduleEnabled later must not silently start needing a signal that was never declared")

  # --- the whole surface is optional: nixwatch.liveness left entirely unset builds fine -----
  (check "liveness/unset-liveness-builds-fine"
    (
      !(buildFails {
        nixwatch.enable = true;
        nixwatch.checks.example = {
          probe = "exit 0";
          interval = "5m";
          deadline = "10m";
          channel = "example";
        };
      })
    )
    "a host using nixwatch.checks but never touching nixwatch.liveness at all should never fail the build")
]
