# modules/default.nix
#
# nixwatch's ALARM half: the mechanism for deciding a thing is unhealthy and raising an alarm
# about it -- named checks, each with a probe (or, for a heartbeat, no probe at all), an
# interval, a staleness deadline, a severity, and a nixpush channel to dispatch on.
#
# The repo owns a second half, in-cluster observability (metrics, dashboards, traces), which is
# a different JOB from this one and is not implemented here or anywhere yet -- see README's
# "Two jobs, one subject". The constraint that half places on THIS file is one-directional and
# permanent: this module may never acquire a dependency on it. A probe that has to query a
# time-series database to decide whether something is up has moved itself inside the thing it
# was supposed to be outside of, which is the failure the incident below IS.
#
# GENERALIZED FROM a private operator's own systemd-timer watchdog engine, born from an
# incident where a host memory-wedged overnight -- every service on it, including SSH, went
# unresponsive -- and NOTHING noticed, because nothing watching it was independent of it: the
# alerting path itself depended on infrastructure that lived on the same box that had just gone
# dark. The fix that implementation landed on: probe every plane from OUTSIDE the thing being
# watched, alert only on a state TRANSITION (not every failing tick), and push a heartbeat
# unconditionally so silence itself becomes detectable. This module is that mechanism, with the
# operator-specific probe list, hostnames, and delivery bespoke-queue logic all stripped out --
# see README's "What changed vs. the implementation this generalizes" for exactly what was cut
# and why.
#
# WHAT THIS MODULE DOES:
#   * Runs each declared check on ITS OWN systemd timer, at its own `interval`.
#   * For a "probe" check: runs a shell snippet whose last command's exit status is the
#     verdict, tracks a persisted last-known-good timestamp, and alerts on a TRANSITION only
#     -- DOWN once when a failure has persisted past `deadline` (real elapsed time, never a
#     tick count), RECOVERED once when it next succeeds. A still-failing or still-healthy tick
#     never re-alerts.
#   * For a "heartbeat" check: sends an unconditional beacon every tick, full stop -- the
#     dead-man's-switch shape, for the one thing naive "alert on failure" monitoring always
#     misses: silence. See "What this does NOT do" below for the honest limit on this.
#   * Lets any check `gatedBy` another: while the named gate reads DOWN, the dependent
#     check's tick is frozen (no probe run, no alert) -- a shared root cause pages once, at
#     its own check, not once per dependent.
#   * Dispatches every alert/beacon through a named nixpush channel (`nixpush send`) -- see
#     "What this does NOT do" for why nixwatch never delivers a notification itself.
#
# WHAT THIS DOES NOT DO (stated here, and in README.md, on purpose):
#   * It is not a notification transport -- and that exclusion is permanent, unaffected by the
#     repo also owning dashboards now. Every `send()` call in the generated script shells out
#     to the real `nixpush` CLI (or a bare `nixpush` resolved off $PATH, if `nixpush.package`
#     isn't present in this config at all -- see `nixpushCmd` below); this module has no idea
#     what a "provider" is, holds no API key, and never will.
#   * It is not where the repo's observability half lives, and never reads from it. One
#     persisted UP/DOWN + last-known-good timestamp per check is the ENTIRE state this module
#     keeps, on purpose: the path that raises the alarm has to survive the death of the thing
#     it watches, and an in-cluster time-series stack cannot (see this file's own header).
#   * It is not the POLICY of what any one operator watches. This repo ships the mechanism and
#     generic examples only; which checks exist, what their probes actually run, and which
#     channels they page belongs in a private, per-operator configuration -- never in this repo.
#   * It cannot detect its own death. A heartbeat check's `deadline` is a PROMISE folded into
#     the beacon's own message text ("expect one at least every ..."), not an enforced value
#     -- nixwatch's tick is what would have to notice a missed deadline, and a timer that has
#     stopped firing cannot also raise the alarm that it stopped firing. Closing that loop
#     needs a receiver, a human, or a process outside this module's own timer, entirely. This
#     is a structural fact about any local watchdog, not a gap this module could fix by trying
#     harder.
#
# EVAL SAFETY / CROSS-REPO CONTRACT: `nixpush.*` is read defensively
# (`config.nixpush.enable or false`, `.channels or { }`, `.package or null`) and is NEVER a
# flake input of this repo -- the house convention this whole design-system family uses for a
# PEER repo (as opposed to a genuinely lower layer): read the sibling's option surface by
# name, at eval time, and degrade gracefully to "unchecked" when it isn't imported at all
# (see the `channel` assertion below, and its own "unvalidated when nixpush is absent" check
# in checks/assertions.nix). `config.nixpush.enable or false` is safe even when NO module
# anywhere declares `options.nixpush` at all -- Nix's `or` attaches to the WHOLE dotted
# selection `config.nixpush.enable`, not just its last segment, so a completely absent
# `nixpush` top-level attribute is caught by the same `or`, not just a missing `.enable` leaf.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixwatch;

  durationLib = import ../lib/duration.nix { inherit lib; };
  runnerLib = import ../lib/runner.nix { inherit pkgs lib durationLib; };

  # Read the nixpush sibling defensively -- see this file's own header. `nixpushEnabled` and
  # `nixpushChannels` feed the `channel` assertion below; `nixpushCmd` is what the generated
  # script actually invokes.
  nixpushEnabled = config.nixpush.enable or false;
  nixpushChannels = config.nixpush.channels or { };
  nixpushPackage = config.nixpush.package or null;
  nixpushCmd =
    if nixpushPackage != null
    then "${nixpushPackage}/bin/nixpush"
    # Falls back to a bare `nixpush` resolved off $PATH -- correct only if some OTHER means
    # installed the real CLI (nixpush's own core module already does this via
    # `environment.systemPackages`, and NixOS's default unit PATH includes
    # /run/current-system/sw/bin, so a check still dispatches correctly even when this
    # module never read a `nixpush.package` value at eval time at all).
    else "nixpush";

  checkType = lib.types.submodule ({ config, ... }: {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [ "probe" "heartbeat" ];
        default = "probe";
        description = ''
          "probe" (default): run `probe`'s script every `interval`; alert DOWN once a failure
          has persisted past `deadline`, RECOVERED once it next succeeds. "heartbeat": ignore
          `probe` entirely and send an unconditional "still alive" beacon every `interval`,
          full stop -- the dead-man's-switch shape (see the module header). Getting this
          backwards on a check meant to be a heartbeat (leaving the "probe" default with no
          `probe` script) fails the build outright (see `probe`'s own description) rather than
          silently ticking a check that can never detect anything.
        '';
      };

      probe = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = ''
          Shell snippet whose LAST command's exit status is the verdict (0 = healthy).
          Required when `kind = "probe"` (asserted) -- a probe check with nothing to run would
          tick forever on its own timer and never once report unhealthy, which is a silent,
          permanent false "all clear", exactly the failure this whole module exists to
          prevent. Forbidden when `kind = "heartbeat"` (asserted) -- a heartbeat ignores this
          field entirely at runtime, so setting it here can only mislead whoever reads this
          configuration into believing it is evaluated. Runs under `timeout -k 5s <timeout>`
          (see `timeout`'s own description for why the kill-after grace matters), never under
          `set -e` (a nonzero exit here is the verdict, not an engine crash) -- reference any
          tool this snippet needs by absolute Nix store path (`${pkgs.curl}/bin/curl`, not
          bare `curl`), the same convention the implementation this module generalizes used
          for its own probes.

          This is the generic vehicle for ANY liveness question, not just plain reachability
          -- an HTTP/TCP endpoint (`curl -sf --max-time N http://...`, `nc -z -w N host port`)
          and a mount that reports itself active without actually answering (`systemctl
          is-active --quiet <unit> && stat <mountpoint>`, the "unit active is not proof the
          mount is usable" shape a frozen FUSE/network session produces) are both ordinary
          probes; neither needs its own check `kind` here, since the only thing that varies
          between them is the one-line shell snippet.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        description = ''
          How often this check's own systemd timer fires, as a plain duration ("30s", "5m",
          "2h", "1d", or a bare integer of seconds) -- never a shared, module-wide cadence.
          Too long here and real downtime accumulates silently between ticks with nothing
          evaluating it; too short burns cycles for no detection benefit. Must never exceed
          `deadline` (asserted, in both directions, in checks/assertions.nix) -- see
          `deadline`'s own description for exactly why a shorter deadline is a hard build
          error, not a warning.
        '';
      };

      deadline = lib.mkOption {
        type = lib.types.str;
        description = ''
          How long this check may read unhealthy (or, for a heartbeat, how long its receiver
          should expect silence to be tolerable) before it counts as genuinely DOWN -- the
          staleness threshold, never the tick rate. Same duration grammar as `interval`.
          Setting this SHORTER than `interval` is asserted to fail the build: with a tick only
          ever arriving every `interval`, a shorter `deadline` can never be observed as
          satisfied, even by a probe that recovers on its very first retry -- the check would
          read as permanently DOWN from the moment it is switched on, forever, which trains
          whoever watches its channel to ignore it the same way a perpetually-red gatus pane
          does (see nixstorage's own backups.nix module for the sibling-domain version of
          exactly this "a check that can never go green gets ignored" lesson).
        '';
      };

      recoverAfter = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Symmetric recovery hysteresis: once a DOWN probe starts succeeding again, it must
          keep succeeding continuously for this long (real elapsed time, same duration grammar
          as `interval`/`deadline` -- never a consecutive-tick count) before this check
          actually flips back to UP and alerts RECOVERED. `null` (the default) flips UP, and
          alerts, on the very first success after a DOWN state -- unchanged from before this
          option existed.

          WHY THIS EXISTS: a probe that flaps right around its own `deadline` boundary
          otherwise alerts DOWN/RECOVERED/DOWN/RECOVERED on every flap -- exactly the noise
          that trains whoever watches the channel to stop trusting, or stop reading, it. Set
          this on a check whose dependency is known to flap on recovery rather than come back
          cleanly; leave it null on one that doesn't, since every set value delays a genuine,
          clean recovery's own RECOVERED alert by this long, which is a real cost to pay only
          where flapping is an actual, observed risk.

          Forbidden when `kind = "heartbeat"` (asserted) -- a heartbeat has no UP/DOWN state
          machine at all, so recovery hysteresis has nothing to apply to.
        '';
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = ''
          Wall-clock limit on one run of `probe`'s script, same duration grammar as
          `interval`/`deadline`. A probe with no bound on its own running time can wedge
          inside the very tick that is supposed to detect a hang -- occupying this check's
          systemd unit indefinitely (or until systemd's own unit-level timeout, if that is
          even long enough) instead of promptly reporting DOWN. Unused when
          `kind = "heartbeat"` (there is no probe to bound), but still required to parse as a
          valid duration regardless of `kind`, for the same reason every duration field here
          is validated uniformly rather than only when it happens to matter this run.

          Enforced as `timeout -k 5s <timeout> bash -c '<probe>'`, never a plain
          `timeout <timeout>` -- see `lib/runner.nix`'s own comment on why the kill-after
          grace is load-bearing: a probe that merely catches or cannot immediately act on the
          first signal can otherwise make `timeout` itself wait past its own deadline, which
          defeats the one option that exists to guarantee this check's tick returns promptly.
        '';
      };

      severity = lib.mkOption {
        type = lib.types.enum [ "info" "warning" "critical" ];
        default = "warning";
        description = ''
          Folded into the alert/beacon title and mapped to the nixpush dispatch priority
          (info -> low, warning -> default, critical -> urgent). Leaving a genuinely critical
          check at the "warning" default means its alert can arrive throttled, batched, or
          silently muted by whatever push-client policy treats non-urgent priority as
          safe-to-defer -- exactly the wrong outcome for the one check that was supposed to
          escalate loudest.
        '';
      };

      channel = lib.mkOption {
        type = lib.types.str;
        description = ''
          Name of a `nixpush.channels.<name>` this check dispatches every alert (or, for a
          heartbeat, every beacon) through. Asserted to exist in `nixpush.channels` whenever
          `nixpush.enable` is true (checked defensively -- this module never depends on
          nixpush as a flake input, see the module header). Pointing this at a channel that
          does not exist means every alert this check will ever raise fails silently at the
          `nixpush send` invocation, at 3am, with nothing here having said so at build time --
          the exact class of mistake an eval-time assertion exists to catch instead.
        '';
      };

      gatedBy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of another check in this same `nixwatch.checks` set whose CURRENT failure
          freezes this check's tick entirely -- no probe run, no state change, no alert --
          for as long as the named gate itself reads DOWN. Exists so one shared root cause (a
          dead network path, a dead cluster API every other check happens to probe through)
          cannot fan out into every dependent check paging independently for the same
          underlying reason; the gate's own check already alerts once for it. Leaving this
          unset on a check that is only ever meaningful in the presence of some shared
          precondition means a single upstream outage pages every one of its dependents at
          once, burying the one alert (the gate's own) that actually explains why.
        '';
      };

      title = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Human-readable label folded into the alert/beacon title in place of the raw check
          name. Leaving this unset on a check named for an internal implementation detail (a
          probe's own shorthand, a config key) means whoever reads the alert on their phone at
          3am has to go source-dive this module's configuration just to figure out what
          actually died.
        '';
      };
    };
  });
in
{
  # nixwatch.liveness.* -- the consumer side, "is this actually live per host" -- lives in its
  # own file (modules/liveness.nix) and is pulled in here so `nixosModules.nixwatch` (this
  # file, flake.nix's own single entry point) stays the one thing a consumer ever needs to
  # import; see that file's own header for why it is a separate option surface from
  # `nixwatch.checks.*` rather than a third check `kind`.
  imports = [ ./liveness.nix ];

  options.nixwatch = {
    enable = lib.mkEnableOption "nixwatch liveness checks (probe/heartbeat + alert-on-transition, dispatched via nixpush)";

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixwatch";
      description = ''
        Directory holding one persisted "STATUS LAST_KNOWN_GOOD_EPOCH" file per check name.
        Losing this directory's contents (a stray `rm -rf`, a tmpfs that doesn't survive a
        reboot) does not lose any DATA -- every check just restarts from a clean "UP, as of
        now" baseline, silently re-arming its own `deadline` grace period from the next tick,
        the same recovery-from-nothing behavior a brand-new check gets on its very first run.
      '';
    };

    checks = lib.mkOption {
      type = lib.types.attrsOf checkType;
      default = { };
      description = ''
        Named liveness checks. Each attribute name becomes one systemd service + timer pair
        (`nixwatch-check-<name>`) and one persisted state file
        (`nixwatch.stateDir/<name>`).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.concatMap
        (name:
          let
            check = cfg.checks.${name};
            intervalSeconds = durationLib.toSeconds check.interval;
            deadlineSeconds = durationLib.toSeconds check.deadline;
            timeoutSeconds = durationLib.toSeconds check.timeout;
            recoverAfterSeconds =
              if check.recoverAfter != null then durationLib.toSeconds check.recoverAfter else null;
          in
          [
            {
              assertion = intervalSeconds != null;
              message = ''
                nixwatch.checks.${name}.interval = "${check.interval}" does not parse as a
                duration (expected a bare integer of seconds, or a number suffixed with
                s/m/h/d, e.g. "30s", "5m", "2h", "1d").
              '';
            }
            {
              assertion = deadlineSeconds != null;
              message = ''
                nixwatch.checks.${name}.deadline = "${check.deadline}" does not parse as a
                duration (same grammar as .interval -- see that option's own error).
              '';
            }
            {
              assertion = timeoutSeconds != null;
              message = ''
                nixwatch.checks.${name}.timeout = "${check.timeout}" does not parse as a
                duration (same grammar as .interval).
              '';
            }
            {
              assertion = intervalSeconds == null || deadlineSeconds == null || deadlineSeconds >= intervalSeconds;
              message = ''
                nixwatch.checks.${name}: deadline ("${check.deadline}") is shorter than
                interval ("${check.interval}"). With a tick only ever arriving every
                ${check.interval}, a shorter deadline can never be observed as satisfied --
                this check would read as permanently DOWN from the moment it starts, forever.
                Raise deadline to at least ${check.interval}, or lower interval.
              '';
            }
            {
              assertion = check.kind != "probe" || check.probe != null;
              message = ''
                nixwatch.checks.${name} has kind = "probe" but no probe script set -- a probe
                check with nothing to run can never detect anything; see `probe`'s own
                description.
              '';
            }
            {
              assertion = check.kind != "heartbeat" || check.probe == null;
              message = ''
                nixwatch.checks.${name} has kind = "heartbeat" but also sets probe -- a
                heartbeat check ignores probe entirely at runtime (see `kind`'s own
                description); leaving it set here can only mislead a future reader.
              '';
            }
            {
              assertion = check.recoverAfter == null || recoverAfterSeconds != null;
              message = ''
                nixwatch.checks.${name}.recoverAfter = "${toString check.recoverAfter}" does
                not parse as a duration (same grammar as .interval -- see that option's own
                error).
              '';
            }
            {
              assertion = check.kind != "heartbeat" || check.recoverAfter == null;
              message = ''
                nixwatch.checks.${name} has kind = "heartbeat" but also sets recoverAfter -- a
                heartbeat has no UP/DOWN state machine at all (see `kind`'s own description),
                so recovery hysteresis has nothing to apply to; leaving it set here can only
                mislead a future reader.
              '';
            }
            {
              assertion = check.gatedBy == null || check.gatedBy != name;
              message = ''
                nixwatch.checks.${name}.gatedBy references itself -- a check can never gate
                its own tick (it would either freeze the instant it first failed, or never
                gate at all, and neither is a sensible reading of "gated by itself").
              '';
            }
            {
              assertion = check.gatedBy == null || lib.hasAttr check.gatedBy cfg.checks;
              message = ''
                nixwatch.checks.${name}.gatedBy = "${toString check.gatedBy}" does not name a
                check declared in nixwatch.checks. Known checks: ${
                  lib.concatStringsSep ", " (lib.attrNames cfg.checks)
                }.
              '';
            }
            {
              assertion = !nixpushEnabled || lib.hasAttr check.channel nixpushChannels;
              message = ''
                nixwatch.checks.${name}.channel is set to "${check.channel}", but
                nixpush.enable is true and no such key exists in nixpush.channels. Every alert
                or heartbeat this check would ever raise fails silently at the `nixpush send`
                call, at 3am, with nothing here having said so at build time. Declare
                nixpush.channels.${check.channel}, or point this check at a channel that
                already exists (known channels: ${
                  if nixpushChannels == { }
                  then "none declared"
                  else lib.concatStringsSep ", " (lib.attrNames nixpushChannels)
                }).
              '';
            }
          ])
        (lib.attrNames cfg.checks);

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root - -"
    ];

    systemd.services = lib.mapAttrs'
      (name: check: lib.nameValuePair "nixwatch-check-${name}" {
        description = "nixwatch check: ${if check.title != null then check.title else name}";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = runnerLib.mkCheckRunner {
            inherit name check;
            stateDir = cfg.stateDir;
            nixpushCmd = nixpushCmd;
          };
          # Bounded generously above the probe's own `timeout` so the unit's own enforcement
          # is never what fires first -- the probe's `timeout` is meant to be the check's own,
          # readable-in-the-alert-message limit; this is only the last-resort backstop.
          TimeoutStartSec = toString ((durationLib.toSeconds check.timeout) + 60);
          MemoryMax = "128M";
        };
        # The timer drives every re-run; never restart mid-switch (harmless, keeps switches quiet).
        restartIfChanged = false;
      })
      cfg.checks;

    systemd.timers = lib.mapAttrs'
      (name: check:
        let
          intervalSeconds = durationLib.toSeconds check.interval;
          # Jitter proportional to interval, capped at 30s and floored at 1s -- a fixed 30s
          # jitter (fine for a 5-minute tick) would dwarf a 10-second one.
          jitterSeconds =
            if intervalSeconds == null then 1
            else if intervalSeconds >= 150 then 30
            else if intervalSeconds <= 5 then 1
            else intervalSeconds / 5;
        in
        lib.nameValuePair "nixwatch-check-${name}" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            # Seed recurrence from when THIS timer becomes active, not from kernel boot.
            # A machine can spend longer than `interval` in its initrd; in that case a
            # boot-relative seed is already in the past when timers.target is reached. With
            # a persistent stamp from the previous boot, systemd can then leave the timer
            # active(elapsed), and OnUnitActiveSec has no current-boot activation to anchor
            # to -- the check never runs once. OnActiveSec always supplies that first
            # current-boot activation regardless of how long pre-userspace boot took.
            OnActiveSec = check.interval;
            OnUnitActiveSec = check.interval;
            RandomizedDelaySec = toString jitterSeconds;
            # Persistent= is a catch-up mechanism for OnCalendar timers. These are monotonic
            # interval timers: their state machine already measures real elapsed health, and
            # replaying a missed tick after power-off says nothing about present health.
            Persistent = false;
          };
        })
      cfg.checks;
  };
}
