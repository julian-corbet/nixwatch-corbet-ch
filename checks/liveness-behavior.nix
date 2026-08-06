# checks/liveness-behavior.nix
#
# BUILD-LEVEL proof for lib/liveness.nix's generated `nixwatch-is-it-live` script, the same
# shape and reasoning as checks/behavior.nix (see that file's own header): calls
# `mkLivenessReport` DIRECTLY, entirely inside the Nix build sandbox, against a fake
# `systemctl` that answers `is-active`/`show` from fixture files instead of ever touching a
# real system -- and against REAL `jq` reading REAL, test-written JSON fixture files, since jq
# is a pure, deterministic reader with nothing to fake.
#
# WHY A REAL CLOCK, LIKE checks/behavior.nix: `validUntil`/`ExecMainStartTimestamp`/
# `UserspaceTimestamp` fixtures below are computed with the REAL `date` command, offset by a
# real `+1 day`/`-1 day`/etc. at the moment this proof actually runs -- never a faked clock.
# What's faked is only ever `systemctl`'s own opinion of unit state, exactly parallel to how
# checks/behavior.nix fakes only `nixpush`, never `date`.
{ pkgs, lib, system }:

let
  livenessLib = import ../lib/liveness.nix { inherit pkgs lib; };

  # A fake systemctl: answers `is-active <unit>` and `show -p <props> [<unit>]` from fixture
  # files under $FAKE_SYSTEMCTL_DIR, set up by the test script below before each scenario --
  # the same "rewrite the fixture on disk, run the real generated script against it" shape
  # checks/behavior.nix uses for its own state-file rewrites, applied here to systemctl's
  # OUTPUT instead of nixwatch's own persisted state.
  fakeSystemctl = pkgs.writeShellScriptBin "systemctl" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail
    dir="''${FAKE_SYSTEMCTL_DIR:?FAKE_SYSTEMCTL_DIR not set}"
    case "''${1:-}" in
      is-active)
        unit="''${2:-}"
        if [ -f "$dir/is-active/$unit" ]; then cat "$dir/is-active/$unit"; else echo "inactive"; fi
        exit 0
        ;;
      show)
        shift
        if [ "''${1:-}" = "-p" ]; then
          props="''${2:-}"
          unit="''${3:-}"
          if [ -n "$unit" ]; then
            [ -f "$dir/show/$unit" ] && cat "$dir/show/$unit"
          elif [ "$props" = "UserspaceTimestamp" ] && [ -f "$dir/boot" ]; then
            printf 'UserspaceTimestamp=%s\n' "$(cat "$dir/boot")"
          fi
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  '';

  mkReport = subjects: livenessLib.mkLivenessReport {
    inherit subjects;
    systemctlCmd = "${fakeSystemctl}/bin/systemctl";
    jqCmd = "${pkgs.jq}/bin/jq";
  };

  # Every field lib/liveness.nix might read is set explicitly below, even where a real
  # `nixwatch.liveness.subjects.<name>` submodule would supply a default -- same reasoning
  # checks/behavior.nix's own `probeCheck`/`heartbeatCheck` fixtures give: these stand in for
  # an already-*resolved* submodule value, so no NixOS default machinery fills in
  # `title`/`healthDomain`/... the way modules/liveness.nix normally would.
  baseSubject = {
    moduleEnabled = true;
    title = null;
    units = [ ];
    healthFile = null;
    healthDomain = null;
    verifyUnit = null;
  };

  disabledSubject = baseSubject // { moduleEnabled = false; units = [ "example.service" ]; };
  unitsOnlySubject = baseSubject // { units = [ "example.service" ]; };
  unitsDownSubject = baseSubject // { units = [ "example.service" ]; };
  healthFreshSubject = baseSubject // { healthFile = "$PWD/health-fresh.json"; };
  healthStaleSubject = baseSubject // { healthFile = "$PWD/health-stale.json"; };
  healthMissingSubject = baseSubject // { healthFile = "$PWD/health-missing.json"; };
  healthDomainRedSubject = baseSubject // {
    healthFile = "$PWD/health-domain.json";
    healthDomain = "firewall";
  };
  verifyFreshSubject = baseSubject // { verifyUnit = "example-verify.service"; };
  verifyStaleSubject = baseSubject // { verifyUnit = "example-verify.service"; };
  verifyMissingSubject = baseSubject // { verifyUnit = "does-not-exist.service"; };

  reportDisabled = mkReport { example = disabledSubject; };
  reportUnitsOnly = mkReport { example = unitsOnlySubject; };
  reportUnitsDown = mkReport { example = unitsDownSubject; };
  reportHealthFresh = mkReport { example = healthFreshSubject; };
  reportHealthStale = mkReport { example = healthStaleSubject; };
  reportHealthMissing = mkReport { example = healthMissingSubject; };
  reportHealthDomainRed = mkReport { example = healthDomainRedSubject; };
  reportVerifyFresh = mkReport { example = verifyFreshSubject; };
  reportVerifyStale = mkReport { example = verifyStaleSubject; };
  reportVerifyMissing = mkReport { example = verifyMissingSubject; };
  # Multi-subject: one FRESH, one UNKNOWN -- overall must read UNKNOWN (exit 2), never green.
  # `fresh` checks no units at all (healthFreshSubject), so it cannot collide with `unknown`'s
  # own is-active fixture below.
  reportMixedFreshUnknown = mkReport {
    fresh = healthFreshSubject;
    unknown = unitsOnlySubject;
  };
  # Multi-subject: one DOWN, one UNKNOWN -- decisive badness must win over merely-unknown.
  # Each names a DIFFERENT unit -- the fake systemctl's `is-active` fixture is keyed by unit
  # name, not by subject name, so two subjects sharing one unit would collide on one fixture
  # file and could never be driven to two different states in the same scenario.
  mixedDownSubject = baseSubject // { units = [ "mixed-down.service" ]; };
  mixedUnknownSubject = baseSubject // { units = [ "mixed-unknown.service" ]; };
  reportMixedDownUnknown = mkReport {
    down = mixedDownSubject;
    unknown = mixedUnknownSubject;
  };
in
pkgs.runCommand "nixwatch-liveness-behavior-proof"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.bash pkgs.gnugrep pkgs.jq ];
}
  ''
    set -euo pipefail
    export FAKE_SYSTEMCTL_DIR="$PWD/fake-systemctl"
    fail() { echo "FAIL: $*"; exit 1; }

    reset_fixtures() {
      rm -rf "$FAKE_SYSTEMCTL_DIR"
      mkdir -p "$FAKE_SYSTEMCTL_DIR/is-active" "$FAKE_SYSTEMCTL_DIR/show"
    }

    run() { # $1 = report script path -- captures stdout+exit code, never aborts the test itself
      set +e
      LAST_OUT="$("$1")"
      LAST_RC=$?
      set -e
    }

    # ── DISABLED: a disabled module is reported DISABLED and never queried further ─────────
    reset_fixtures
    run "${reportDisabled}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 0 ] || fail "a report with only a disabled subject must exit 0, got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^DISABLED' || fail "expected a DISABLED line, got: $LAST_OUT"

    echo "disabled subject: reported disabled, exit 0 PASSED"

    # ── UNKNOWN: enabled, unit active, but no healthFile/verifyUnit declared at all ────────
    reset_fixtures
    echo -n "active" > "$FAKE_SYSTEMCTL_DIR/is-active/example.service"
    run "${reportUnitsOnly}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 2 ] || fail "a subject with no healthFile/verifyUnit must exit 2 (UNKNOWN), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^UNKNOWN' || fail "expected an UNKNOWN line, got: $LAST_OUT"
    echo "$LAST_OUT" | grep -qi 'FRESH' && fail "a subject that cannot prove freshness must never print FRESH, got: $LAST_OUT"

    echo "unit-active-but-no-artifact: UNKNOWN is never folded into healthy PASSED"

    # ── DOWN: enabled, unit NOT active ──────────────────────────────────────────────────────
    reset_fixtures
    echo -n "inactive" > "$FAKE_SYSTEMCTL_DIR/is-active/example.service"
    run "${reportUnitsDown}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 1 ] || fail "a subject whose unit is not active must exit 1 (DOWN), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^DOWN' || fail "expected a DOWN line, got: $LAST_OUT"

    echo "unit not active: DOWN PASSED"

    # ── FRESH: healthFile with validUntil comfortably in the future ────────────────────────
    reset_fixtures
    futureTs="$(date -u -d '+1 day' --iso-8601=seconds)"
    jq -n --arg v "$futureTs" '{validUntil: $v}' > "$PWD/health-fresh.json"
    run "${reportHealthFresh}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 0 ] || fail "a subject with a future validUntil must exit 0 (FRESH), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^FRESH' || fail "expected a FRESH line, got: $LAST_OUT"

    echo "healthFile validUntil in the future: FRESH PASSED"

    # ── STALE: healthFile with validUntil already in the past (HEALTH-2) ───────────────────
    reset_fixtures
    pastTs="$(date -u -d '-1 day' --iso-8601=seconds)"
    jq -n --arg v "$pastTs" '{validUntil: $v}' > "$PWD/health-stale.json"
    run "${reportHealthStale}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 1 ] || fail "a subject with a past validUntil must exit 1 (STALE), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^STALE' || fail "expected a STALE line, got: $LAST_OUT"

    echo "healthFile validUntil in the past: STALE, HEALTH-2 PASSED"

    # ── UNKNOWN: healthFile declared but the file does not exist ───────────────────────────
    reset_fixtures
    rm -f "$PWD/health-missing.json"
    run "${reportHealthMissing}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 2 ] || fail "a subject whose healthFile is missing must exit 2 (UNKNOWN), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^UNKNOWN' || fail "expected an UNKNOWN line, got: $LAST_OUT"

    echo "healthFile absent: UNKNOWN, never FRESH-by-absence PASSED"

    # ── DOWN: healthFile fresh (validUntil in the future) but its OWN domain reports red ───
    reset_fixtures
    futureTs2="$(date -u -d '+1 day' --iso-8601=seconds)"
    jq -n --arg v "$futureTs2" '{validUntil: $v, subjects: {firewall: {state: "red"}}}' > "$PWD/health-domain.json"
    run "${reportHealthDomainRed}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 1 ] || fail "a subject whose own domain reports red must exit 1 (DOWN) even with a fresh validUntil, got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^DOWN' || fail "expected a DOWN line, got: $LAST_OUT"

    echo "HEALTH-3: fresh document, one red domain -> DOWN, not vouched-for by validUntil alone PASSED"

    # ── FRESH: verifyUnit ran THIS boot and passed ──────────────────────────────────────────
    reset_fixtures
    bootTs="$(date -u -d '-1 hour' '+%a %Y-%m-%d %H:%M:%S UTC')"
    ranTs="$(date -u -d '-30 minutes' '+%a %Y-%m-%d %H:%M:%S UTC')"
    echo -n "$bootTs" > "$FAKE_SYSTEMCTL_DIR/boot"
    printf 'ActiveState=active\nResult=success\nExecMainStartTimestamp=%s\nExecMainStatus=0\n' "$ranTs" \
      > "$FAKE_SYSTEMCTL_DIR/show/example-verify.service"
    run "${reportVerifyFresh}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 0 ] || fail "a verifyUnit that ran this boot and passed must exit 0 (FRESH), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^FRESH' || fail "expected a FRESH line, got: $LAST_OUT"

    echo "verifyUnit ran this boot and passed: FRESH PASSED"

    # ── STALE: verifyUnit last ran BEFORE this boot (never re-ran) ─────────────────────────
    reset_fixtures
    bootTs2="$(date -u -d '-1 hour' '+%a %Y-%m-%d %H:%M:%S UTC')"
    ranTs2="$(date -u -d '-1 day' '+%a %Y-%m-%d %H:%M:%S UTC')"
    echo -n "$bootTs2" > "$FAKE_SYSTEMCTL_DIR/boot"
    printf 'ActiveState=active\nResult=success\nExecMainStartTimestamp=%s\nExecMainStatus=0\n' "$ranTs2" \
      > "$FAKE_SYSTEMCTL_DIR/show/example-verify.service"
    run "${reportVerifyStale}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 1 ] || fail "a verifyUnit that last ran before this boot must exit 1 (STALE), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^STALE' || fail "expected a STALE line, got: $LAST_OUT"

    echo "verifyUnit last ran before this boot: STALE, not vouched for by a stale success PASSED"

    # ── UNKNOWN: verifyUnit declared but not found on this host at all ─────────────────────
    reset_fixtures
    run "${reportVerifyMissing}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 2 ] || fail "a verifyUnit that does not exist must exit 2 (UNKNOWN), got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^UNKNOWN' || fail "expected an UNKNOWN line, got: $LAST_OUT"

    echo "verifyUnit absent: UNKNOWN PASSED"

    # ── aggregate: FRESH + UNKNOWN together must read UNKNOWN overall, never green ──────────
    reset_fixtures
    futureTs3="$(date -u -d '+1 day' --iso-8601=seconds)"
    jq -n --arg v "$futureTs3" '{validUntil: $v}' > "$PWD/health-fresh.json"
    echo -n "active" > "$FAKE_SYSTEMCTL_DIR/is-active/example.service"
    run "${reportMixedFreshUnknown}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 2 ] || fail "one FRESH subject plus one UNKNOWN subject must aggregate to exit 2, got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^FRESH' || fail "expected the fresh subject's own FRESH line still present, got: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^UNKNOWN' || fail "expected the unknown subject's own UNKNOWN line still present, got: $LAST_OUT"

    echo "aggregate: one UNKNOWN subject keeps the whole report off green PASSED"

    # ── aggregate: DOWN + UNKNOWN together must read DOWN (decisive badness wins) ──────────
    reset_fixtures
    echo -n "inactive" > "$FAKE_SYSTEMCTL_DIR/is-active/mixed-down.service"
    echo -n "active" > "$FAKE_SYSTEMCTL_DIR/is-active/mixed-unknown.service"
    run "${reportMixedDownUnknown}/bin/nixwatch-is-it-live"
    [ "$LAST_RC" -eq 1 ] || fail "one DOWN subject plus one UNKNOWN subject must aggregate to exit 1, got $LAST_RC: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^DOWN' || fail "expected the down subject's own DOWN line still present, got: $LAST_OUT"
    echo "$LAST_OUT" | grep -q '^UNKNOWN' || fail "expected the unknown subject's own UNKNOWN line still present, got: $LAST_OUT"

    echo "aggregate: decisive DOWN outranks merely-UNKNOWN PASSED"

    touch $out
  ''
