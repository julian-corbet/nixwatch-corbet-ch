# modules/liveness.nix
#
# nixwatch.liveness: the CONSUMER side of "is this actually live" -- per host, per declared
# subject (typically one nix* module's own domain), answers three questions a green probe
# check cannot: is the module even enabled, are the systemd units it depends on actually
# running right now, and is that subsystem's OWN verify/health artifact fresh -- not merely
# present. Born from a nixdeploy publisher that ran every 60s for days, signed and green, into
# ZERO receivers, and looked complete from every angle: nothing anywhere asked "does the thing
# this is supposed to prove even still exist", because a publisher succeeding at publishing is
# not evidence anyone is reading it.
#
# THIS FILE CONSUMES, NEVER REIMPLEMENTS, TWO EXISTING SHAPES (see lib/liveness.nix's own
# header for the third -- the report LINE format):
#   * nixnet's health document (BEHAVIORS.md HEALTH-1/HEALTH-2): one subject per domain, each
#     with a state, since, checked-at, and a shared validUntil so staleness is decidable by the
#     READER. `healthFile`/`healthDomain` below read exactly that shape.
#   * nixboot-verify's own convention: read every managed knob back and report what actually
#     took, via a oneshot's own exit code, no persisted artifact of its own. `verifyUnit` below
#     reads exactly that shape.
#
# WHAT THIS DOES NOT DO:
#   * It is not a second alerting engine. `nixwatch.checks.<name>.probe` is already the generic
#     vehicle for ANY liveness question (see modules/default.nix's own `probe` doc) -- wire
#     `probe = "''${config.nixwatch.liveness.package}/bin/nixwatch-is-it-live; [ $? -eq 0 ]"`
#     (or `[ $? -ne 1 ]` to tolerate UNKNOWN) to get this dispatched through nixpush on the
#     SAME alert-on-transition machinery every other check already uses. This module never
#     calls nixpush, and never will.
#   * It is not a fleet dashboard. One host, one report, printed as PASS/FAIL-shaped lines to
#     this unit's own journal. A reader that wants to render many hosts at once is, same as
#     nixnet's own HEALTH-2, a READER's job, never this module's.
#   * It cannot discover subjects on its own. `nixwatch.liveness.subjects.<name>.moduleEnabled`
#     must be HANDED IN by the operator's own configuration.nix (typically
#     `config.nixnet.enable or false`) -- nixwatch never imports nixnet, nixboot, or any other
#     nix* module as a flake input (the same house rule this repo already applies to nixpush;
#     see modules/default.nix's own header), so it has no way to read that value itself.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixwatch.liveness;
  durationLib = import ../lib/duration.nix { inherit lib; };
  livenessLib = import ../lib/liveness.nix { inherit pkgs lib; };

  subjectType = lib.types.submodule {
    options = {
      moduleEnabled = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the nix* module this subject represents is enabled on THIS host, as your own
          configuration.nix already knows it (typically `config.nixnet.enable or false`).
          nixwatch never imports nixnet, nixboot, or any other nix* module as a flake input
          (same house rule this repo already applies to nixpush -- see modules/default.nix's
          own header), so this value can only ever be handed in, never inferred. A subject
          whose `moduleEnabled` is false is reported DISABLED and none of its `units`,
          `healthFile`, or `verifyUnit` are ever queried -- a disabled module having no running
          units is expected, not evidence of anything.
        '';
      };

      title = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Human-readable label used in the report line in place of the raw subject name.
          `null` (default) uses the subject name as-is -- same convention as
          `nixwatch.checks.<name>.title`.
        '';
      };

      units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          systemd unit NAMES (e.g. "nixnetd.service") this subject expects to be `active`
          whenever `moduleEnabled` is true. Checked with `systemctl is-active`, which is a
          necessary but not sufficient condition on its own -- a unit reporting `active` is not
          proof it actually answers (a network/FUSE session can die underneath an established
          mount and leave every filesystem call hanging, which `systemctl is-active` alone
          reads as healthy forever; see modules/default.nix's own `probe` doc for the identical
          point made about probe checks). `healthFile`/`verifyUnit` are what close that gap for
          THIS subject; `units` alone only ever proves systemd's own opinion.
        '';
      };

      healthFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute path to a JSON health document following nixnet's own shape
          (BEHAVIORS.md HEALTH-1/HEALTH-2): a top-level `validUntil` (RFC3339) shared by the
          whole document, and optionally a `.subjects.<domain>.state` breakdown when the
          document reports more than one domain (see `healthDomain`). Absent, unreadable,
          missing `validUntil`, or `validUntil` that fails to parse all read as UNKNOWN, never
          as fresh -- a health document that cannot be read has proven nothing, which is a
          different fact from having proven the subject healthy. `validUntil` in the past reads
          as STALE regardless of the state it last reported (HEALTH-2: silence reads as red,
          not as whatever the last write happened to say).

          Mutually exclusive with `verifyUnit` (asserted) -- a subject has exactly one way of
          proving its own freshness, never two that could disagree.
        '';
      };

      healthDomain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Which key under `healthFile`'s own `.subjects` object this liveness subject
          corresponds to, when that document reports more than one domain under one shared
          `validUntil` (nixnet's own shape: `addressing`/`firewall`/`uplink`/...). Leave `null`
          when `healthFile` reports a single state directly with no per-domain breakdown.
          Requires `healthFile` to be set (asserted) -- naming a domain inside a document that
          was never declared cannot mean anything.
        '';
      };

      verifyUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of a oneshot systemd unit in the nixboot-verify shape: `Type = "oneshot"`,
          `RemainAfterExit = true`, run once at boot, its own exit code the verdict, no
          on-disk artifact of its own. Freshness here means "ran and passed THIS boot" --
          judged by comparing the unit's own `ExecMainStartTimestamp` against this boot's own
          `UserspaceTimestamp`, never a `validUntil` (a boot-once unit has no expiry of its own
          to read). A unit that is absent, has never run, or last ran before this boot (masked,
          disabled, or a condition that failed silently) all read as UNKNOWN or STALE, never as
          fresh by default.

          Mutually exclusive with `healthFile` (asserted) -- see that option's own doc.
        '';
      };
    };
  };
in
{
  options.nixwatch.liveness = {
    enable = lib.mkEnableOption ''
      the is-it-live survey: per declared subject, whether its nix* module is enabled, whether
      its systemd units are actually active, and whether its own verify/health artifact is
      fresh -- distinguishing UNKNOWN from healthy rather than folding one into the other'';

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = ''
        How often `nixwatch-is-it-live.timer` re-runs the survey, same duration grammar as
        `nixwatch.checks.<name>.interval` (`lib/duration.nix`). The survey also runs once at
        boot (`OnBootSec`), so a fresh report exists shortly after boot rather than only after
        the first full interval has elapsed.
      '';
    };

    subjects = lib.mkOption {
      type = lib.types.attrsOf subjectType;
      default = { };
      description = ''
        Named subjects this host's is-it-live survey reports on. Each becomes one block in
        `nixwatch-is-it-live`'s report, printed as one `STATE  title: detail` line (FRESH /
        DOWN / STALE / UNKNOWN / DISABLED) -- the same PASS/FAIL/SKIP-line shape nixboot-verify
        already uses, deliberately not a fourth format.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The built `nixwatch-is-it-live` report script (set internally; read-only). Reference it
        by absolute store path from a check's own `probe`
        (`"''${config.nixwatch.liveness.package}/bin/nixwatch-is-it-live"`) rather than the bare
        command name, even though it is also installed via `environment.systemPackages` for
        interactive use -- a systemd oneshot's own default PATH is a curated minimal list, not
        `/run/current-system/sw/bin` (see this file's own header, and nixboot-verify's, for the
        measured reason bare command names inside a generated check script are not trustworthy).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.concatMap
        (name:
          let subj = cfg.subjects.${name}; in
          [
            {
              assertion = subj.healthFile == null || subj.verifyUnit == null;
              message = ''
                nixwatch.liveness.subjects.${name} sets both healthFile and verifyUnit -- a
                subject has exactly one way of proving its own freshness, never two that could
                disagree about it. Pick whichever shape this subject's own module actually
                writes: a shared health document (healthFile/healthDomain) or a boot-time
                verify unit (verifyUnit).
              '';
            }
            {
              assertion = subj.healthDomain == null || subj.healthFile != null;
              message = ''
                nixwatch.liveness.subjects.${name}.healthDomain = "${toString subj.healthDomain}"
                is set, but healthFile is not -- a domain name inside a health document that was
                never declared cannot mean anything. Set healthFile, or drop healthDomain.
              '';
            }
            {
              assertion = subj.units != [ ] || subj.healthFile != null || subj.verifyUnit != null;
              message = ''
                nixwatch.liveness.subjects.${name} declares no units, no healthFile, and no
                verifyUnit -- a subject with nothing to check can never report anything but a
                vacuous, permanent DISABLED-or-FRESH, exactly the silent false "all clear" this
                whole module exists to prevent (the same reasoning modules/default.nix applies
                to a probe check with no probe script). Declare at least one of the three.
              '';
            }
          ])
        (lib.attrNames cfg.subjects)
      ++ [
        {
          assertion = durationLib.toSeconds cfg.interval != null;
          message = ''
            nixwatch.liveness.interval = "${cfg.interval}" does not parse as a duration
            (expected a bare integer of seconds, or a number suffixed with s/m/h/d).
          '';
        }
      ];

    nixwatch.liveness.package = livenessLib.mkLivenessReport {
      subjects = cfg.subjects;
      systemctlCmd = "${pkgs.systemd}/bin/systemctl";
      jqCmd = "${pkgs.jq}/bin/jq";
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services.nixwatch-is-it-live = {
      description = "nixwatch: is-it-live survey -- enabled modules, unit activity, verify/health freshness";
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # RemainAfterExit, same as nixboot-verify: `systemctl status nixwatch-is-it-live`
        # always shows the LAST report and its own exit code between ticks, not just the
        # instant the timer last fired.
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/nixwatch-is-it-live";
        # Generous above what a handful of `systemctl is-active`/`show`/`jq` calls per subject
        # should ever need -- a last-resort backstop, not the survey's own budget.
        TimeoutStartSec = 120;
        MemoryMax = "128M";
      };
      restartIfChanged = false;
    };

    systemd.timers.nixwatch-is-it-live = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "30";
        Persistent = true;
      };
    };
  };
}
