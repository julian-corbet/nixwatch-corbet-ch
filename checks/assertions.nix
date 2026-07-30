# checks/assertions.nix
#
# Eval-time checks for modules/default.nix: each evaluates a real configuration through
# NixOS's own eval-config.nix and asks whether forcing `system.build.toplevel` fails. Nothing
# here boots or runs anything -- these are entirely about assertions, which are eval-time
# properties (NixOS enforces `config.assertions` when `system.build.toplevel` is forced, not
# on a bare read of the list itself).
#
# `nixpushStub` below is a small, hand-written fake of nixpush's OWN option surface
# (`nixpush.enable`/`.channels`/`.package`) -- never the real nixpush flake. This repo's own
# house rule ("read a sibling defensively, never as a flake input") applies in its strongest
# form to test code: pulling in the real nixpush flake as a checks-only input would make a
# test-only dependency look like a real one, and nixstorage's own checks/layout.nix documents
# hitting exactly this question before landing on the same answer -- fake the CONTRACT
# inline, not the dependency.
{ pkgs, lib, nixpkgs, system, nixwatchModule }:

let
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  # A minimal stand-in for nixpush's own option surface -- just enough
  # (`enable`/`channels`/`package`) for nixwatch's own `channel` assertion to exercise both
  # branches. `channels` only needs to be a name -> anything table for `lib.hasAttr` to work
  # against; it does not need to mirror nixpush's real submodule shape.
  nixpushStub = { lib, ... }: {
    options.nixpush = {
      enable = lib.mkEnableOption "fake nixpush stand-in, checks-only, never the real thing";
      package = lib.mkOption { type = lib.types.package; default = pkgs.hello; };
      channels = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
    };
  };

  # `evalNixwatch`: nixwatch alone, no nixpush stub anywhere in the composed system --
  # proves nixwatch's own claim that it works standalone, with no sibling present at all
  # (the same "does this module survive a host that never imported X" question
  # nixstorage's own modules/layout.nix answers for `nixstorage.disks`).
  evalNixwatch = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [ nixwatchModule extraConfig bareStubs ];
    }).config;

  buildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixwatch extraConfig).system.build.toplevel true)).success;

  # `evalNixwatchWithNixpush`: nixwatch PLUS the fake nixpush stub -- used only by the
  # fixtures below that specifically exercise the `channel` assertion's "nixpush IS present"
  # branch.
  evalNixwatchWithNixpush = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [ nixwatchModule nixpushStub extraConfig bareStubs ];
    }).config;

  buildFailsWithNixpush = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixwatchWithNixpush extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # A small, complete, VALID check -- every "and one thing about it is wrong" fixture below
  # starts from this and mutates exactly one field.
  validCheck = {
    probe = "exit 0";
    interval = "5m";
    deadline = "10m";
    channel = "example";
  };
in
[
  # --- the non-negotiable #1: deadline shorter than interval can never pass ----------------
  (check "checks/deadline-shorter-than-interval-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { interval = "5m"; deadline = "1m"; };
    })
    "expected a deadline shorter than its own interval to fail the build, but it succeeded")

  (check "checks/deadline-equal-to-interval-builds-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { interval = "5m"; deadline = "5m"; };
    }))
    "a deadline exactly equal to interval should never fail the build on its own")

  (check "checks/deadline-longer-than-interval-builds-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { interval = "1m"; deadline = "5m"; };
    }))
    "the base valid fixture (deadline > interval) should never fail the build on its own")

  # --- malformed durations, both fields, all three duration options -----------------------
  (check "checks/malformed-interval-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { interval = "banana"; };
    })
    "expected an unparsable interval to fail the build, but it succeeded")

  (check "checks/malformed-deadline-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { deadline = "banana"; };
    })
    "expected an unparsable deadline to fail the build, but it succeeded")

  (check "checks/malformed-timeout-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { timeout = "banana"; };
    })
    "expected an unparsable timeout to fail the build, but it succeeded")

  (check "checks/well-formed-durations-build-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { timeout = "10s"; };
    }))
    "well-formed interval/deadline/timeout should never fail the build on their own")

  # --- kind = "probe" without a probe script ------------------------------------------------
  (check "checks/probe-kind-without-probe-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = builtins.removeAttrs validCheck [ "probe" ] // { kind = "probe"; };
    })
    "expected kind = \"probe\" with no probe script to fail the build, but it succeeded")

  (check "checks/probe-kind-with-probe-builds-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { kind = "probe"; };
    }))
    "kind = \"probe\" with a probe script set should never fail the build on its own")

  # --- kind = "heartbeat" must not also set probe -------------------------------------------
  (check "checks/heartbeat-kind-with-probe-set-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { kind = "heartbeat"; probe = "exit 0"; };
    })
    "expected kind = \"heartbeat\" with a probe script set to fail the build, but it succeeded")

  (check "checks/heartbeat-kind-without-probe-builds-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = builtins.removeAttrs validCheck [ "probe" ] // { kind = "heartbeat"; };
    }))
    "kind = \"heartbeat\" with no probe script should never fail the build on its own")

  # --- gatedBy: self-reference, unknown reference, valid reference ------------------------
  (check "checks/gatedby-self-reference-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { gatedBy = "example"; };
    })
    "expected a check gating itself to fail the build, but it succeeded")

  (check "checks/gatedby-unknown-check-fails-the-build"
    (buildFails {
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { gatedBy = "does-not-exist"; };
    })
    "expected gatedBy naming an undeclared check to fail the build, but it succeeded")

  (check "checks/gatedby-valid-reference-builds-fine"
    (!(buildFails {
      nixwatch.enable = true;
      nixwatch.checks.gate = validCheck;
      nixwatch.checks.example = validCheck // { gatedBy = "gate"; };
    }))
    "a check gated by another, real, declared check should never fail the build on its own")

  # --- channel: asserted against nixpush.channels ONLY when nixpush.enable is true ---------
  (check "checks/undeclared-channel-fails-the-build-when-nixpush-enabled"
    (buildFailsWithNixpush {
      nixpush.enable = true;
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { channel = "does-not-exist"; };
    })
    "expected an undeclared nixpush channel to fail the build when nixpush.enable = true, but it succeeded")

  (check "checks/declared-channel-builds-fine-when-nixpush-enabled"
    (!(buildFailsWithNixpush {
      nixpush.enable = true;
      nixpush.channels.example = { };
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { channel = "example"; };
    }))
    "a channel actually declared in nixpush.channels should never fail the build on its own")

  # --- the graceful, ungated path: nixpush not present in the composed system AT ALL --------
  (check "checks/unvalidated-channel-builds-fine-when-nixpush-absent"
    (!(buildFails {
      # evalNixwatch, not evalNixwatchWithNixpush: no nixpushStub anywhere in this
      # composition, so `config.nixpush` does not exist as an option path at all -- proves
      # the defensive read (`config.nixpush.enable or false`) degrades to "unchecked"
      # rather than throwing an "attribute missing" error of its own.
      nixwatch.enable = true;
      nixwatch.checks.example = validCheck // { channel = "anything-at-all"; };
    }))
    "a check's channel must never be validated against nixpush.channels when nixpush is not imported into the composed system at all")
]
