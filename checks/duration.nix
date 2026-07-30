# checks/duration.nix
#
# Pure function tests for lib/duration.nix -- no NixOS eval-config anywhere in this file,
# since `toSeconds` has no dependency on the module system at all (it is a plain string ->
# int|null function). Every unit the parser claims to support gets a positive test; the
# grammar it deliberately does NOT support (combined units, garbage input, empty string) gets
# a negative one, so this file proves the SAME "both directions" shape checks/assertions.nix
# proves for the module built on top of this parser.
{ lib }:

let
  durationLib = import ../lib/duration.nix { inherit lib; };
  check = name: ok: detail: { inherit name ok detail; };
in
[
  (check "duration/bare-integer-is-seconds"
    (durationLib.toSeconds "90" == 90)
    "expected \"90\" to parse as 90 seconds")

  (check "duration/seconds-suffix"
    (durationLib.toSeconds "30s" == 30)
    "expected \"30s\" to parse as 30 seconds")

  (check "duration/minutes-suffix"
    (durationLib.toSeconds "5m" == 300)
    "expected \"5m\" to parse as 300 seconds")

  (check "duration/hours-suffix"
    (durationLib.toSeconds "2h" == 7200)
    "expected \"2h\" to parse as 7200 seconds")

  (check "duration/days-suffix"
    (durationLib.toSeconds "1d" == 86400)
    "expected \"1d\" to parse as 86400 seconds")

  # --- deliberately unsupported grammar: each must parse to null, not throw, and not
  #     silently coerce to some guessed value -------------------------------------------
  (check "duration/empty-string-fails-to-parse"
    (durationLib.toSeconds "" == null)
    "expected the empty string to fail to parse")

  (check "duration/non-numeric-fails-to-parse"
    (durationLib.toSeconds "banana" == null)
    "expected a non-numeric string to fail to parse")

  (check "duration/unknown-suffix-fails-to-parse"
    (durationLib.toSeconds "5x" == null)
    "expected an unrecognized unit suffix to fail to parse")

  (check "duration/combined-units-not-supported"
    (durationLib.toSeconds "1h30m" == null)
    "expected combined units (\"1h30m\") to fail to parse -- this parser deliberately supports only a single number + single optional suffix")

  (check "duration/negative-not-supported"
    (durationLib.toSeconds "-5m" == null)
    "expected a negative duration to fail to parse")

  (check "duration/whitespace-not-supported"
    (durationLib.toSeconds " 5m" == null)
    "expected leading whitespace to fail to parse -- this parser does no trimming")
]
