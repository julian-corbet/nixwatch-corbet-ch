# checks/behavior.nix
#
# BUILD-LEVEL proof: nixwatch is the one repo in this design-system family whose whole
# reason to exist is RUNTIME behavior a pure eval-time check cannot see -- a state machine
# (UP/DOWN + last-known-good timestamp), alert-on-transition-only, a gate that freezes a
# dependent check's tick, and a heartbeat's unconditional beacon. checks/assertions.nix
# proves the module is wired correctly (selection/validation, eval-time); this file actually
# RUNS the generated scripts, entirely inside the Nix build sandbox, against a fake `nixpush`
# that records what it was asked to send instead of ever touching a network.
#
# Calls `lib/runner.nix`'s `mkCheckRunner` DIRECTLY -- not through a NixOS eval-config -- the
# same "call the plain builder function straight from checks/" shape nixstorage's own
# checks/layout.nix uses for its image-build and verify-drift proofs, and for the identical
# reason: this is the one place a real artifact (here, a script's OBSERVABLE BEHAVIOR across
# repeated invocations) needs proving, and going through a full NixOS toplevel eval to get
# there would cost real time for zero extra coverage.
#
# HOW TIME IS FAKED WITHOUT FAKING `date`: each generated script calls the REAL `date +%s` --
# there is no fake clock anywhere in this proof. Instead, between invocations that need to
# simulate elapsed real time (a probe that must cross its own `deadline`), this file directly
# rewrites the persisted state file's timestamp backward by hand. This is not a shortcut
# around the mechanism under test -- moving the persisted "last known good" timestamp
# backward is EXACTLY what really does happen, from the script's own point of view, between
# two ticks separated by real wall-clock time; the only thing faked is which wall-clock the
# test runs on, never the script's own logic path.
{ pkgs, lib, system }:

let
  durationLib = import ../lib/duration.nix { inherit lib; };
  runnerLib = import ../lib/runner.nix { inherit pkgs lib durationLib; };

  # A fake nixpush: records the LAST positional argument (the "$1: $2" message
  # send() always passes as its own final, single quoted argument) to
  # $NIXWATCH_TEST_LOG and exits 0, unconditionally. Never a real notification, never
  # touches a network -- used ONLY inside this one proof.
  fakeNixpush = pkgs.writeShellScriptBin "nixpush" ''
    #!${pkgs.bash}/bin/bash
    msg="''${@: -1}"
    printf '%s\n' "$msg" >> "''${NIXWATCH_TEST_LOG:?NIXWATCH_TEST_LOG not set}"
  '';
  nixpushCmd = "${fakeNixpush}/bin/nixpush";

  # `stateDir = "$PWD/state"` -- a shell-EXPANDABLE literal, not a Nix-evaluated path (see
  # lib/runner.nix's own header for why `mkCheckRunner` inserts `stateDir` unescaped). It
  # resolves, at RUNTIME, to whatever directory the runCommand builder script below happens
  # to be running in -- always writable, since it's the build's own working directory.
  stateDir = "$PWD/state";

  mkRunner = name: check: runnerLib.mkCheckRunner { inherit name check stateDir nixpushCmd; };

  # Every field `lib/runner.nix` might read is set explicitly below, even where a real
  # `nixwatch.checks.<name>` submodule would supply a default -- these are plain Nix
  # attrsets standing in for an already-*resolved* submodule value (see this file's own
  # header on why this calls `mkCheckRunner` directly), so no NixOS default machinery ever
  # fills in `title`/`gatedBy` here the way `modules/default.nix` normally would.
  probeCheck = {
    kind = "probe";
    probe = ''[ "$NIXWATCH_TEST_PROBE_OK" = "0" ]'';
    interval = "1s";
    deadline = "2s";
    recoverAfter = null;
    timeout = "5s";
    severity = "warning";
    channel = "test";
    gatedBy = null;
    title = null;
  };
  probeCheckScript = mkRunner "probe-check" probeCheck;

  heartbeatCheck = {
    kind = "heartbeat";
    probe = null;
    interval = "1s";
    deadline = "1s";
    recoverAfter = null;
    timeout = "5s";
    severity = "info";
    channel = "test";
    gatedBy = null;
    title = null;
  };
  heartbeatCheckScript = mkRunner "heartbeat-check" heartbeatCheck;

  gateCheck = probeCheck; # identical shape -- reused as the precondition below
  gateCheckScript = mkRunner "gate-check" gateCheck;

  gatedCheck = {
    kind = "probe";
    probe = "exit 1"; # ALWAYS fails -- proves it's the GATE freezing the tick, not the probe passing
    interval = "1s";
    deadline = "2s";
    recoverAfter = null;
    timeout = "5s";
    severity = "warning";
    channel = "test";
    gatedBy = "gate-check";
    title = null;
  };
  gatedCheckScript = mkRunner "gated-check" gatedCheck;

  # A probe check with symmetric RECOVERY hysteresis: recoverAfter = "10s" means a single
  # success no longer flips DOWN -> UP by itself -- the probe must keep succeeding
  # continuously for 10s (simulated the same way the deadline test below simulates elapsed
  # time: rewriting the persisted state file's own timestamp backward, never a faked clock)
  # before this check actually flips back to UP and alerts RECOVERED.
  recoverCheck = {
    kind = "probe";
    probe = ''[ "$NIXWATCH_TEST_PROBE_OK" = "0" ]'';
    interval = "1s";
    deadline = "2s";
    recoverAfter = "10s";
    timeout = "5s";
    severity = "warning";
    channel = "test";
    gatedBy = null;
    title = null;
  };
  recoverCheckScript = mkRunner "recover-check" recoverCheck;
in
pkgs.runCommand "nixwatch-behavior-proof"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.bash pkgs.gnugrep ];
}
  ''
    set -euo pipefail
    export NIXWATCH_TEST_LOG="$PWD/nixpush.log"
    : > "$NIXWATCH_TEST_LOG"

    count() { wc -l < "$NIXWATCH_TEST_LOG"; }
    lastline() { tail -n1 "$NIXWATCH_TEST_LOG"; }
    fail() { echo "FAIL: $*"; exit 1; }

    # ── probe check: healthy tick sends nothing ─────────────────────────────────────────
    export NIXWATCH_TEST_PROBE_OK=0
    ${probeCheckScript}
    [ "$(count)" -eq 0 ] || fail "a healthy first tick must never alert (got $(count) message(s))"
    grep -q '^UP ' "$PWD/state/probe-check" || fail "expected persisted state UP after a healthy tick"

    # ── first FAILING tick: within deadline (interval just happened) -- no alert yet ────
    export NIXWATCH_TEST_PROBE_OK=1
    ${probeCheckScript}
    [ "$(count)" -eq 0 ] || fail "a failure still within its own deadline must not alert yet (got $(count))"
    read -r st0 _ < "$PWD/state/probe-check"
    [ "$st0" = "UP" ] || fail "state must stay UP while still inside the deadline grace period"

    # ── simulate elapsed real time: push the persisted last-known-good timestamp back
    #    past the 2s deadline (see this file's own header for why this, not a faked `date`,
    #    is the honest way to simulate a tick separated by real wall-clock time) ─────────
    read -r _ lastgood0 < "$PWD/state/probe-check"
    echo "UP $(( lastgood0 - 10 ))" > "$PWD/state/probe-check"
    ${probeCheckScript}
    [ "$(count)" -eq 1 ] || fail "a failure that has now crossed its own deadline must alert exactly once (got $(count))"
    lastline | grep -q '^DOWN:' || fail "expected a DOWN alert, got: $(lastline)"
    read -r st1 _ < "$PWD/state/probe-check"
    [ "$st1" = "DOWN" ] || fail "persisted state must flip to DOWN once the deadline is crossed"

    # ── still failing: NO repeat alert ──────────────────────────────────────────────────
    ${probeCheckScript}
    [ "$(count)" -eq 1 ] || fail "a still-failing tick must never re-alert (alert-on-TRANSITION only; got $(count))"

    # ── recovers: exactly one RECOVERED, no more ────────────────────────────────────────
    export NIXWATCH_TEST_PROBE_OK=0
    ${probeCheckScript}
    [ "$(count)" -eq 2 ] || fail "a recovering tick must alert exactly once more (got $(count))"
    lastline | grep -q '^RECOVERED:' || fail "expected a RECOVERED alert, got: $(lastline)"

    echo "probe check: transition-only alerting PASSED"

    # ── heartbeat: unconditional beacon, every single invocation, no state machine ──────
    : > "$NIXWATCH_TEST_LOG"
    ${heartbeatCheckScript}
    ${heartbeatCheckScript}
    ${heartbeatCheckScript}
    [ "$(count)" -eq 3 ] || fail "a heartbeat check must beacon on EVERY tick unconditionally (got $(count) for 3 invocations)"
    grep -c '^ALIVE:' "$NIXWATCH_TEST_LOG" | grep -qx 3 || fail "every heartbeat line must be an ALIVE beacon"

    echo "heartbeat check: unconditional beacon PASSED"

    # ── gate: a dependent check's tick freezes entirely while its gate reads DOWN ───────
    : > "$NIXWATCH_TEST_LOG"
    rm -f "$PWD/state/gate-check" "$PWD/state/gated-check"

    export NIXWATCH_TEST_PROBE_OK=1
    ${gateCheckScript}                                  # first failing tick: within deadline, no alert
    [ "$(count)" -eq 0 ] || fail "gate-check's own first failing tick must not alert yet"
    read -r _ gLastgood < "$PWD/state/gate-check"
    echo "UP $(( gLastgood - 10 ))" > "$PWD/state/gate-check"
    ${gateCheckScript}                                  # now crosses its own deadline -> DOWN
    [ "$(count)" -eq 1 ] || fail "gate-check must alert exactly once once its own deadline is crossed"
    lastline | grep -q '^DOWN:' || fail "expected gate-check's own DOWN alert, got: $(lastline)"

    ${gatedCheckScript}                                  # gate-check is now DOWN: must freeze entirely
    [ "$(count)" -eq 1 ] || fail "a check gated by a DOWN gate must never alert on its own (got $(count), expected still 1)"
    [ ! -e "$PWD/state/gated-check" ] || fail "a frozen tick must never write its own state file at all"

    export NIXWATCH_TEST_PROBE_OK=0
    ${gateCheckScript}                                  # gate-check recovers
    [ "$(count)" -eq 2 ] || fail "gate-check must alert exactly once on its own recovery"
    lastline | grep -q '^RECOVERED:' || fail "expected gate-check's own RECOVERED alert, got: $(lastline)"

    ${gatedCheckScript}                                  # gate now UP: gated-check's own (always-failing) probe finally runs
    [ "$(count)" -eq 2 ] || fail "gated-check's own first tick, once unblocked, must not alert yet (within its own deadline)"
    [ -e "$PWD/state/gated-check" ] || fail "gated-check must start tracking its own state once its gate is no longer DOWN"

    read -r _ gdLastgood < "$PWD/state/gated-check"
    echo "UP $(( gdLastgood - 10 ))" > "$PWD/state/gated-check"
    ${gatedCheckScript}                                  # still gate=UP, probe still fails, now past ITS OWN deadline
    [ "$(count)" -eq 3 ] || fail "gated-check must alert on its own once unblocked and once ITS OWN deadline is crossed"
    lastline | grep -q '^DOWN:' || fail "expected gated-check's own DOWN alert once unblocked, got: $(lastline)"

    echo "gate: freeze-while-down + resume-once-healthy PASSED"

    # ── recoverAfter: symmetric recovery hysteresis, real elapsed time ──────────────────
    : > "$NIXWATCH_TEST_LOG"
    rm -f "$PWD/state/recover-check"

    export NIXWATCH_TEST_PROBE_OK=0
    ${recoverCheckScript}
    [ "$(count)" -eq 0 ] || fail "recover-check: a healthy first tick must never alert (got $(count))"

    # Drive it DOWN exactly like the plain probe-check proof above: fail, then simulate
    # crossing the 2s deadline by rewriting lastgood backward.
    export NIXWATCH_TEST_PROBE_OK=1
    ${recoverCheckScript}
    [ "$(count)" -eq 0 ] || fail "recover-check: a failure still within its own deadline must not alert yet"
    read -r _ rLastgood < "$PWD/state/recover-check"
    echo "UP $(( rLastgood - 10 ))" > "$PWD/state/recover-check"
    ${recoverCheckScript}
    [ "$(count)" -eq 1 ] || fail "recover-check: crossing its own deadline must alert exactly once (got $(count))"
    lastline | grep -q '^DOWN:' || fail "expected recover-check's own DOWN alert, got: $(lastline)"

    # First success after DOWN: with recoverAfter set, this must NOT flip UP and must NOT
    # alert -- it only starts the recovery streak.
    export NIXWATCH_TEST_PROBE_OK=0
    ${recoverCheckScript}
    [ "$(count)" -eq 1 ] || fail "recover-check: the FIRST success after DOWN must not alert yet with recoverAfter set (got $(count), expected still 1)"
    read -r rSt _ rSince < "$PWD/state/recover-check"
    [ "$rSt" = "DOWN" ] || fail "recover-check: state must stay DOWN through the recovery streak, got $rSt"
    [ -n "''${rSince:-}" ] || fail "recover-check: expected a recovering-since timestamp to be persisted once a success streak starts"

    # A second success arriving almost immediately (real elapsed time far short of the 10s
    # recoverAfter) must ALSO not flip UP yet, and must carry the SAME recovering-since
    # timestamp forward rather than resetting the streak's start on every tick.
    ${recoverCheckScript}
    [ "$(count)" -eq 1 ] || fail "recover-check: still-recovering ticks must not alert (got $(count), expected still 1)"
    read -r _ _ rSince2 < "$PWD/state/recover-check"
    [ "$rSince2" = "$rSince" ] || fail "recover-check: recovering-since must not reset on a later still-recovering success (was $rSince, now $rSince2)"

    # Simulate recoverAfter (10s) having actually elapsed: push recovering-since backward.
    echo "DOWN $rLastgood $(( rSince - 15 ))" > "$PWD/state/recover-check"
    ${recoverCheckScript}
    [ "$(count)" -eq 2 ] || fail "recover-check: once recoverAfter has elapsed, the next success must flip UP and alert exactly once (got $(count))"
    lastline | grep -q '^RECOVERED:' || fail "expected recover-check's own RECOVERED alert, got: $(lastline)"
    read -r rSt2 _ < "$PWD/state/recover-check"
    [ "$rSt2" = "UP" ] || fail "recover-check: state must flip to UP once recoverAfter has elapsed"

    echo "recoverAfter: symmetric recovery hysteresis PASSED"

    # ── recoverAfter: a FAILURE mid-streak resets the partial recovery, never carries over ──
    : > "$NIXWATCH_TEST_LOG"
    rm -f "$PWD/state/recover-check"

    export NIXWATCH_TEST_PROBE_OK=1
    ${recoverCheckScript}                                # first failing tick: within deadline
    read -r _ rLastgood2 < "$PWD/state/recover-check"
    echo "UP $(( rLastgood2 - 10 ))" > "$PWD/state/recover-check"
    ${recoverCheckScript}                                # crosses deadline -> DOWN
    [ "$(count)" -eq 1 ] || fail "recover-check/flap: expected exactly one DOWN alert before the flap, got $(count)"

    export NIXWATCH_TEST_PROBE_OK=0
    ${recoverCheckScript}                                # one success: starts a recovery streak
    read -r _ _ rSince3 < "$PWD/state/recover-check"
    [ -n "''${rSince3:-}" ] || fail "recover-check/flap: expected a recovering-since timestamp after the first success"

    export NIXWATCH_TEST_PROBE_OK=1
    ${recoverCheckScript}                                # fails again BEFORE recoverAfter elapses: must reset the streak
    [ "$(count)" -eq 1 ] || fail "recover-check/flap: a failure mid-streak must not itself alert (still-DOWN, got $(count))"
    read -r rSt3 _ rSince4 < "$PWD/state/recover-check"
    [ "$rSt3" = "DOWN" ] || fail "recover-check/flap: must remain DOWN after failing mid-streak"
    [ -z "''${rSince4:-}" ] || fail "recover-check/flap: a failure mid-streak must clear the recovering-since timestamp, not carry it forward (got $rSince4)"

    echo "recoverAfter: mid-streak failure resets the partial recovery PASSED"

    touch $out
  ''
