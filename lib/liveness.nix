# lib/liveness.nix
#
# Builds ONE host's is-it-live report script -- a plain function of its own arguments (a
# resolved `nixwatch.liveness.subjects` attrset, plus the two external commands it shells out
# to) rather than a closure over a NixOS config, the same "plain, standalone-callable builder"
# shape lib/runner.nix already uses and for the identical reason: checks/liveness-behavior.nix
# calls this DIRECTLY and runs the real generated script against a fake `systemctl`, entirely
# inside a build sandbox, without paying for a full NixOS toplevel eval.
#
# `modules/liveness.nix` is the only real caller, always with `systemctlCmd`/`jqCmd` resolved to
# `${pkgs.systemd}/bin/systemctl` / `${pkgs.jq}/bin/jq` -- absolute Nix store paths, never a bare
# command name. This is not the usual "prefer absolute paths" house style talking: nixboot's own
# module header records a MEASURED finding that a plain systemd `script = ...` unit's default
# PATH is a curated minimal list (coreutils/findutils/gnugrep/gnused/systemd), not
# `/run/current-system/sw/bin` -- so a bare `systemctl`/`jq` inside a oneshot's own script can
# fail to resolve on a real host even though both are visibly installed system-wide.
#
# THIS FUNCTION CONSUMES, NEVER REIMPLEMENTS, TWO EXISTING SHAPES:
#   * nixnet's health document (BEHAVIORS.md HEALTH-1/HEALTH-2): one JSON document, one shared
#     top-level `validUntil`, optionally one subject per domain under `.subjects.<domain>.state`
#     -- the `healthFile`/`healthDomain` branch below only ever READS that shape; nothing here
#     writes one.
#   * nixboot-verify's own convention: a oneshot systemd unit, `RemainAfterExit = true`, whose
#     own exit code is the verdict and which persists no artifact of its own on disk -- the
#     `verifyUnit` branch below reads exactly that shape, correlating the unit's own
#     `ExecMainStartTimestamp` against this boot's own `UserspaceTimestamp` (a unit that only
#     ever runs once at boot has no `validUntil` of its own to read; "did it run and pass THIS
#     boot" is the closest honest equivalent).
{ pkgs, lib }:

let
  # One subject's own shell block. Every value read here (`subj.*`) is already a plain Nix
  # string/bool/null from an already-*resolved* `nixwatch.liveness.subjects.<name>` submodule --
  # this function performs NO validation of its own; `modules/liveness.nix`'s assertions are the
  # only place a malformed subject (both `healthFile` and `verifyUnit` set, a subject checking
  # nothing at all, `healthDomain` with no `healthFile`) is ever refused, and they run before
  # this function's result can ever be forced by a real activation -- same division of labour
  # `lib/runner.nix`'s own header describes for checks.
  #
  # Every value that could ever appear INSIDE a printed message is first assigned to a shell
  # variable via `lib.escapeShellArg` (`subject_title=${lib.escapeShellArg titleStr}`), then
  # referenced as `"$subject_title"` -- never spliced straight into a double-quoted `echo`
  # string. `escapeShellArg` wraps its result in single quotes, which is only correct when the
  # WHOLE shell word is that one value (an assignment's right-hand side, same as this repo's own
  # `send() { ... --title ${lib.escapeShellArg "..."} ... }` in lib/runner.nix); splicing an
  # already-single-quoted value into the middle of a separate double-quoted string would print
  # the literal quote marks instead of escaping anything.
  subjectBlock = { systemctlCmd, jqCmd }: name: subj:
    let
      titleStr = if subj.title != null then subj.title else name;
      unitsList = lib.concatStringsSep " " (map lib.escapeShellArg subj.units);
      enabledLiteral = if subj.moduleEnabled then "true" else "false";
    in
    ''
      # ── subject: ${name} ────────────────────────────────────────────────────────────────
      subject_title=${lib.escapeShellArg titleStr}
      if ${enabledLiteral}; then
        units_ok=1
        failing_units=""
        for u in ${unitsList}; do
          st="$(${systemctlCmd} is-active "$u" 2>/dev/null || true)"
          if [ "$st" != "active" ]; then
            units_ok=0
            failing_units="''${failing_units:+$failing_units, }$u=''${st:-unknown}"
          fi
        done

        # Default: neither `healthFile` nor `verifyUnit` declared at all -- the subject can
        # prove its units are running and nothing more. This is UNKNOWN, deliberately, never
        # folded into FRESH: a module with no verify/health artifact of its own has not been
        # vouched for by anything except "systemd thinks its unit is up", which is exactly the
        # "unit active is not proof it actually works" gap this whole module exists to close
        # (see modules/default.nix's own `probe` doc for the sibling FUSE-mount version of the
        # same point).
        artifact_state="UNKNOWN"
        artifact_detail="no healthFile or verifyUnit declared for this subject -- unit activity is all that can be known"

        ${lib.optionalString (subj.healthFile != null) ''
        # Inserted inside a plain double-quoted shell assignment, UNESCAPED beyond that -- the
        # same convention lib/runner.nix uses for its own `stateDir` (`STATE_DIR="<value>"`,
        # never `escapeShellArg`-wrapped), and for the same reason: it lets
        # checks/liveness-behavior.nix hand in a shell-EXPANDABLE value like "$PWD/health.json"
        # and have it resolve at RUNTIME inside the build sandbox, rather than needing a
        # writable absolute path known at Nix eval time. `healthFile` is an operator-set
        # module option, never external input -- the same trust boundary `stateDir` accepts.
        subject_healthfile="${subj.healthFile}"
        if [ ! -f "$subject_healthfile" ]; then
          artifact_state="UNKNOWN"
          artifact_detail="health file $subject_healthfile does not exist"
        else
          validUntil="$(${jqCmd} -r '.validUntil // empty' "$subject_healthfile" 2>/dev/null || true)"
          if [ -z "$validUntil" ]; then
            artifact_state="UNKNOWN"
            artifact_detail="$subject_healthfile has no top-level validUntil -- cannot decide staleness (HEALTH-1/HEALTH-2)"
          else
            validEpoch="$(date -d "$validUntil" +%s 2>/dev/null || true)"
            nowEpoch="$(date +%s)"
            if [ -z "$validEpoch" ]; then
              artifact_state="UNKNOWN"
              artifact_detail="$subject_healthfile: validUntil \"$validUntil\" does not parse as a timestamp"
            elif [ "$nowEpoch" -ge "$validEpoch" ]; then
              artifact_state="STALE"
              artifact_detail="$subject_healthfile: validUntil $validUntil has passed -- HEALTH-2: silence reads as red, not as the last value it ever reported"
            else
              ${if subj.healthDomain != null then ''
              # jq FILTER text, not a shell argument -- `healthDomain` is spliced directly into
              # the jq program below (never through escapeShellArg, which would wrongly quote
              # it as jq syntax rather than as a jq object key). Same trust boundary as every
              # other operator-authored Nix string this repo splices into a generated script
              # (a check's own `probe`, `channel`); this is config, never external input.
              domainState="$(${jqCmd} -r '.subjects.${subj.healthDomain}.state // empty' "$subject_healthfile" 2>/dev/null || true)"
              if [ -z "$domainState" ]; then
                artifact_state="UNKNOWN"
                artifact_detail="$subject_healthfile has no .subjects.${subj.healthDomain}.state"
              elif [ "$domainState" = "green" ] || [ "$domainState" = "up" ] || [ "$domainState" = "ok" ]; then
                artifact_state="FRESH"
                artifact_detail="fresh, domain ${subj.healthDomain} reports $domainState (valid until $validUntil)"
              else
                artifact_state="DOWN"
                artifact_detail="fresh but domain ${subj.healthDomain} itself reports $domainState (valid until $validUntil)"
              fi
              '' else ''
              artifact_state="FRESH"
              artifact_detail="fresh (valid until $validUntil)"
              ''}
            fi
          fi
        fi
        ''}

        ${lib.optionalString (subj.verifyUnit != null) ''
        subject_verifyunit=${lib.escapeShellArg subj.verifyUnit}
        show="$(${systemctlCmd} show -p ActiveState,Result,ExecMainStartTimestamp,ExecMainStatus "$subject_verifyunit" 2>/dev/null || true)"
        if [ -z "$show" ]; then
          artifact_state="UNKNOWN"
          artifact_detail="verify unit $subject_verifyunit not found"
        else
          activeState="$(printf '%s\n' "$show" | sed -n 's/^ActiveState=//p')"
          result="$(printf '%s\n' "$show" | sed -n 's/^Result=//p')"
          startTs="$(printf '%s\n' "$show" | sed -n 's/^ExecMainStartTimestamp=//p')"
          mainStatus="$(printf '%s\n' "$show" | sed -n 's/^ExecMainStatus=//p')"
          if [ -z "$startTs" ]; then
            artifact_state="UNKNOWN"
            artifact_detail="verify unit $subject_verifyunit has not run yet (no ExecMainStartTimestamp)"
          else
            # `systemctl show -p UserspaceTimestamp` with NO unit queries the manager itself,
            # not any one unit -- "if no unit name is specified, the manager itself will be
            # inspected" (systemctl(1)). This is the only clock a boot-once verify unit (no
            # validUntil of its own) can be judged fresh against: did it run THIS boot, not
            # merely at some point in the past.
            bootLine="$(${systemctlCmd} show -p UserspaceTimestamp 2>/dev/null || true)"
            bootTs="''${bootLine#UserspaceTimestamp=}"
            startEpoch="$(date -d "$startTs" +%s 2>/dev/null || true)"
            bootEpoch="$(date -d "$bootTs" +%s 2>/dev/null || true)"
            if [ -z "$startEpoch" ] || [ -z "$bootEpoch" ]; then
              artifact_state="UNKNOWN"
              artifact_detail="verify unit $subject_verifyunit: could not parse its own timestamp or this boot's own UserspaceTimestamp"
            elif [ "$startEpoch" -lt "$bootEpoch" ]; then
              artifact_state="STALE"
              artifact_detail="verify unit $subject_verifyunit last ran at $startTs, before this boot -- it has not run since the machine came up"
            elif [ "$activeState" = "active" ] && { [ "$result" = "success" ] || [ "$mainStatus" = "0" ]; }; then
              artifact_state="FRESH"
              artifact_detail="verify unit $subject_verifyunit ran this boot at $startTs and passed"
            else
              artifact_state="DOWN"
              artifact_detail="verify unit $subject_verifyunit ran this boot at $startTs and reported failure (result=''${result:-?}, exit=''${mainStatus:-?})"
            fi
          fi
        fi
        ''}

        if [ "$units_ok" -eq 0 ]; then
          echo "DOWN     $subject_title: unit(s) not active: $failing_units"
          overall_bad=1
        elif [ "$artifact_state" = "DOWN" ] || [ "$artifact_state" = "STALE" ]; then
          echo "$artifact_state    $subject_title: $artifact_detail"
          overall_bad=1
        elif [ "$artifact_state" = "UNKNOWN" ]; then
          echo "UNKNOWN  $subject_title: $artifact_detail"
          overall_unknown=1
        else
          echo "FRESH    $subject_title: $artifact_detail"
        fi
      else
        echo "DISABLED $subject_title: module not enabled on this host"
      fi
    '';
in
{
  # mkLivenessReport :: { subjects, systemctlCmd, jqCmd } -> derivation
  #
  # Produces `$out/bin/nixwatch-is-it-live`. Exit code is the aggregate, three-way, ON PURPOSE
  # -- collapsing it to the usual two (0/nonzero) would erase the one distinction this whole
  # mechanism exists to draw:
  #   0 = every ENABLED subject read FRESH.
  #   1 = at least one subject read DOWN or STALE -- decisive, known-bad evidence.
  #   2 = nothing DOWN or STALE, but at least one subject read UNKNOWN -- nothing is provably
  #       broken, and nothing has proven itself alive either. This is the "publisher ran green
  #       for days into zero receivers" state: a check wired as
  #       `probe = "nixwatch-is-it-live; [ $? -eq 0 ]"` pages on this exactly like a genuine
  #       DOWN; one wired as `[ $? -ne 1 ]` accepts UNKNOWN as tolerable and only pages on
  #       decisive badness -- the choice belongs to whoever wires the check, never to this
  #       script. See README's "is-it-live" section for the wiring pattern.
  mkLivenessReport = { subjects, systemctlCmd, jqCmd }:
    pkgs.writeShellScriptBin "nixwatch-is-it-live" ''
      set -uo pipefail   # no -e: any one subject's own bad reading is DATA, never an engine crash
      export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bash pkgs.gnused ]}:$PATH
      # `date -d` parses a weekday-prefixed systemd timestamp ("Thu 2026-08-06 09:00:00 UTC")
      # -- locale-independent parsing needs the C locale explicitly, the same reason
      # nixboot-verify forces `LC_ALL=C` on its own `bootctl status` call rather than trusting
      # whatever locale the unit happens to inherit.
      export LC_ALL=C

      overall_bad=0
      overall_unknown=0

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (subjectBlock { inherit systemctlCmd jqCmd; }) subjects)}

      if [ "$overall_bad" -eq 1 ]; then
        exit 1
      elif [ "$overall_unknown" -eq 1 ]; then
        exit 2
      else
        exit 0
      fi
    '';
}
