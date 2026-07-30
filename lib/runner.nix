# lib/runner.nix
#
# Builds ONE check's generated shell script -- a plain function of its own arguments, not a
# closure over a NixOS config -- so `checks/behavior.nix` can call this directly and prove
# the generated script's actual runtime behavior (state transitions, alert-on-transition-only,
# the gate freeze, the heartbeat's unconditional beacon) entirely inside a build sandbox,
# without paying for a full NixOS eval-config just to extract one systemd unit's ExecStart
# path. Same shape as nixstorage's own `lib/image.nix`: the real acting logic lives in a
# plain, standalone-callable function; the NixOS module (`modules/default.nix`) is one caller
# of it, not the only one.
#
# `modules/default.nix` is the other caller, for a real host: it always passes
# `stateDir = config.nixwatch.stateDir` and a `nixpushCmd` resolved from
# `config.nixpush.package or null` (see that file's own header for why that read is
# defensive, never a flake input).
{ pkgs, lib, durationLib }:

let
  # severity -> nixpush --priority. Only three of nixpush's five priorities are used on
  # purpose -- "min"/"high" have no clean mapping from a 3-way severity without inventing a
  # meaning for them nixwatch itself has no opinion on; a channel bound to a paging provider
  # can still map "urgent" onward to whatever escalation policy it wants.
  priorityOf = severity: { info = "low"; warning = "default"; critical = "urgent"; }.${severity};

  titleOf = name: check: if check.title != null then check.title else name;
in
{
  # mkCheckRunner :: { name, check, stateDir, nixpushCmd } -> derivation
  #
  # `check` is one already-*resolved* `nixwatch.checks.<name>` submodule value -- this
  # function performs NO validation of its own; `modules/default.nix`'s assertions are the
  # only place a malformed check is ever refused, and they run before this function's result
  # can ever be forced by a real activation (NixOS checks `assertions` when
  # `system.build.toplevel` is forced, before the rest of config is acted on).
  #
  # `stateDir` and `nixpushCmd` are inserted into the generated script inside a single pair
  # of double quotes, UNESCAPED beyond that -- deliberately: this is the same convention the
  # implementation this module generalizes (a private fleet's own fleet-watchdog.nix) used
  # for its own `STATE=${cfg.stateDir}/state`, and it is what lets `checks/behavior.nix` hand
  # in a shell-EXPANDABLE value like "$PWD/state" and have it resolve at RUNTIME inside the
  # build sandbox, rather than needing to guess a writable absolute path at eval time. Never
  # pass untrusted input as `stateDir` on a real host -- it is an operator-set module option,
  # not end-user data.
  mkCheckRunner = { name, check, stateDir, nixpushCmd }:
    let
      timeoutSeconds = durationLib.toSeconds check.timeout;
      deadlineSeconds = durationLib.toSeconds check.deadline;
    in
    pkgs.writeShellScript "nixwatch-check-${name}" ''
      set -uo pipefail   # deliberately NO -e: a failing probe's own exit status is DATA (the
                         # verdict this check exists to produce), never an engine crash.
      export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bash ]}:$PATH

      STATE_DIR="${stateDir}"
      mkdir -p "$STATE_DIR"
      SF="$STATE_DIR/${name}"
      now=$(date +%s)

      send() { # $1 = event word (DOWN/RECOVERED/ALIVE), $2 = human-readable detail
        ${nixpushCmd} send --channel ${lib.escapeShellArg check.channel} \
          --priority ${priorityOf check.severity} \
          --title ${lib.escapeShellArg "nixwatch: ${titleOf name check}"} \
          --tag nixwatch --tag ${check.severity} \
          "$1: $2" \
          || echo "nixwatch-check-${name}: WARN nixpush send failed (channel ${check.channel})" >&2
      }

      ${lib.optionalString (check.gatedBy != null) ''
      # ── gate: freeze this tick entirely while the named check reads DOWN ────────────────
      # No probe run, no state write, no alert -- the gate's OWN check already alerted once
      # for the shared root cause. Generalizes the private implementation's single hardcoded
      # "control probe" (a hub-egress sanity check gating every other fleet probe) into a
      # reusable relationship any check can declare against any other, so a shared root cause
      # (a dead network path, a dead cluster API) cannot fan out into every dependent check
      # paging independently for the same underlying reason.
      GATE_SF="$STATE_DIR/${check.gatedBy}"
      if [ -f "$GATE_SF" ]; then
        gate_status=$(cut -d' ' -f1 "$GATE_SF" 2>/dev/null || echo UP)
        if [ "$gate_status" = "DOWN" ]; then
          echo "nixwatch-check-${name}: gate '${check.gatedBy}' is DOWN -- tick frozen"
          exit 0
        fi
      fi
      ''}

      ${if check.kind == "heartbeat" then ''
      # ── heartbeat: the dead-man's-switch shape ──────────────────────────────────────────
      # Unconditional beacon, every tick, regardless of anything else this script knows --
      # no probe, no up/down state machine, no "alert on transition only". Noticing this
      # beacon's own ABSENCE needs something OUTSIDE this script watching for silence; this
      # module cannot detect its own death from inside its own timer (see the repo README's
      # "what this does NOT do" for why that is a structural limit, not an oversight).
      send "ALIVE" "heartbeat (expect one at least every ${check.deadline})"
      echo "UP $now" > "$SF"
      exit 0
      '' else ''
      # ── probe: alert-on-TRANSITION only, staleness measured in real elapsed time ─────────
      # Never a tick count: a systemd timer's own RandomizedDelaySec means "N consecutive
      # ticks" is not actually a fixed span of wall-clock time, but a persisted last-known-good
      # timestamp is.
      st=UP; lastgood=$now
      if [ -f "$SF" ]; then read -r st lastgood < "$SF" 2>/dev/null || { st=UP; lastgood=$now; }; fi
      case "''${lastgood:-}" in ""|*[!0-9]*) lastgood=$now;; esac

      if timeout ${toString timeoutSeconds} bash -c ${lib.escapeShellArg check.probe} >/dev/null 2>&1; then
        echo "UP $now" > "$SF"
        if [ "$st" = DOWN ]; then
          down_for=$(( now - lastgood ))
          send "RECOVERED" "back up (was down roughly ''${down_for}s)"
        fi
      else
        if [ "$st" = UP ]; then
          age=$(( now - lastgood ))
          if [ "$age" -ge ${toString deadlineSeconds} ]; then
            echo "DOWN $lastgood" > "$SF"
            send "DOWN" "unhealthy for roughly ''${age}s (deadline ${toString deadlineSeconds}s)"
          else
            echo "UP $lastgood" > "$SF"
            echo "nixwatch-check-${name}: fail, ''${age}s/${toString deadlineSeconds}s of deadline elapsed -- not yet alerting"
          fi
        else
          echo "DOWN $lastgood" > "$SF"   # still down; no repeat alert
        fi
      fi
      ''}
    '';
}
