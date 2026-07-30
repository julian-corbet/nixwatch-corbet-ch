# lib/duration.nix
#
# Parses a small, exactly-defined subset of duration syntax ("30s", "5m", "2h", "1d", or a
# bare integer meaning seconds) into a plain integer number of seconds, entirely at Nix eval
# time.
#
# WHY THIS EXISTS AT ALL: `nixwatch.checks.<name>.interval` and `.deadline` are BOTH plain
# duration strings -- not a systemd OnCalendar cron expression -- specifically so the "a check
# whose deadline is shorter than its own interval must be a build error" assertion
# (modules/default.nix) can compare the two AT EVAL TIME, as plain integers. Two OnCalendar
# strings have no well-defined "shorter than" relation to compare at all; two durations do.
#
# Deliberately NOT the full systemd.time(7) grammar -- no combined "1h30m", no weeks/months/
# years, no fractional seconds, no bare "infinity". A small, exactly-parseable subset is
# enough for a staleness threshold, and the exact same subset is asserted in BOTH directions
# in checks/duration.nix (every unit below parses to the expected value; a malformed string,
# or a grammar this parser deliberately does not support, parses to `null`).
{ lib }:
let
  # Seconds per unit suffix. Absent suffix (bare integer) means seconds, handled below.
  unitSeconds = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
  };
in
{
  # toSeconds :: str -> int | null
  #
  # `null` means "did not parse" -- this function never throws. The caller
  # (modules/default.nix's assertions) is the one place a `null` here turns into a build
  # failure with a readable message; keeping the parser itself total (no throw) is what lets
  # checks/duration.nix assert on malformed input as an ordinary value comparison
  # (`toSeconds "banana" == null`) rather than having to catch an exception.
  toSeconds = s:
    let
      m = builtins.match "([0-9]+)(s|m|h|d)?" s;
    in
    if m == null then null
    else
      let
        n = lib.toInt (builtins.elemAt m 0);
        unitStr = builtins.elemAt m 1;
        mult = if unitStr == null then 1 else unitSeconds.${unitStr};
      in
      n * mult;
}
