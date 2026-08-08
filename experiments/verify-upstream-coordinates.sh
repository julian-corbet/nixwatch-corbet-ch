#!/usr/bin/env bash
# Verify every upstream coordinate in ../lib/observability.nix against the registry or chart
# repository it names -- and, with --tags, show what upstream is actually shipping.
#
# WHAT THIS EXISTS TO CATCH. The cluster catalogue names container image REPOSITORIES and Helm chart
# COORDINATES, and deliberately no versions at all: a version is a value, supplied by whoever
# declares a workload. So there is nothing here that a Nix evaluation could check. What can go stale
# is the coordinate itself -- a project moves its images to a different registry, a chart repository
# is renamed, a vendor stops publishing one -- and every one of those is a fact about the world that
# changes without this repository changing.
#
# THIS IS THE ONLY PLACE THE CATALOGUE MEETS REALITY. Everything else about the cluster half is
# checked offline and exhaustively: which declaration renders, which is refused, and what the
# manifests contain. None of that can tell you that a registry still serves the repository an entry
# names, which is exactly the failure a consumer meets at the far end of a sync rather than at
# build time.
#
# Reads the coordinates out of the catalogue rather than a second hand-kept list, which is the whole
# reason this is a script and not a checklist.
#
# Usage:
#   ./verify-upstream-coordinates.sh            # every coordinate, reachable or not
#   ./verify-upstream-coordinates.sh --tags 5   # ... and some of what each one publishes, which
#                                               #     this repository deliberately cannot answer
#                                               #     from its own data: it pins no versions
#
# `--tags` IS A HINT, NOT A LISTING, and the difference matters before anybody copies a string out
# of it. For an image it prints the tail of whatever order the registry lists tags in, which is not
# sorted by recency and includes per-architecture build tags nobody should declare. For a chart it
# greps the neighbourhood of the entry in the index, which can pick up a DEPENDENCY's version
# constraint rather than the chart's own version. Both are enough to answer "is anything being
# published here at all"; neither is enough to answer "what should I pin".
#
# Needs: nix, jq, and skopeo for anything OCI. curl for classic chart repositories.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalogue="$here/../lib/observability.nix"

tags=0
case "${1:-}" in
  --tags) tags="${2:-5}" ;;
  "") ;;
  *) echo "usage: $0 [--tags N]" >&2; exit 2 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

for tool in nix jq; do
  have "$tool" || { echo "missing required tool: $tool" >&2; exit 2; }
done
have skopeo || echo "note: skopeo is not installed -- OCI coordinates will be reported as UNCHECKED"
have curl || echo "note: curl is not installed -- classic chart repositories will be reported as UNCHECKED"

# group/name/delivery/image/chart, flattened out of the catalogue itself. Written with builtins
# only: the catalogue is a plain data file, and pulling nixpkgs in just to reach `lib.concatMap`
# would make this script depend on a channel being configured.
rows="$(nix eval --json --file "$catalogue" --apply '
  f:
    let
      systems = f { };
      row = g: n:
        let e = systems.${g}.${n}; in
        {
          group = g;
          name = n;
          delivery = e.delivery;
          image = e.image;
          chartRepo = if e.chart == null then null else e.chart.repo;
          chartName = if e.chart == null then null else e.chart.name;
        };
    in
    builtins.concatLists
      (map (g: map (row g) (builtins.attrNames systems.${g})) (builtins.attrNames systems))
')" || {
  echo "could not evaluate $catalogue" >&2
  exit 1
}

ok=0; bad=0; unchecked=0

report() { printf '  %-9s %s\n' "$1" "$2"; }

list_oci_tags() {
  # $1 = registry/path, no scheme. The newest tags a registry lists, which is the whole reason for
  # --tags: this repository pins nothing, so "what can I actually declare" is a question about
  # upstream rather than about the catalogue.
  skopeo list-tags "docker://$1" 2>/dev/null | jq -r '.Tags[]' | tail -n "$tags" | sed 's/^/            /'
}

check_oci() {
  local ref="$1" what="$2"
  if ! have skopeo; then
    report UNCHECKED "$what -> $ref (no skopeo)"; unchecked=$((unchecked + 1)); return
  fi
  if skopeo list-tags "docker://$ref" >/dev/null 2>&1; then
    report OK "$what -> $ref"; ok=$((ok + 1))
    [ "$tags" -gt 0 ] && list_oci_tags "$ref"
  else
    report FAIL "$what -> $ref (the registry did not answer, or the repository is gone)"
    bad=$((bad + 1))
  fi
}

# NO PIPELINE INTO `grep -q` ANYWHERE IN HERE, and it is not a style preference -- it is a bug this
# script had on its first run and reported as three coordinates that do not exist. `grep -q` exits
# the instant it matches; the process feeding it then dies of SIGPIPE with status 141; and under
# `set -o pipefail` the PIPELINE's status is that 141 rather than grep's own 0. So a successful match
# on a large input reads as a failure, and a small input passes because the writer finishes before
# grep can exit -- which is exactly the shape of bug that survives review and every short test.
# Feeding grep from a here-string keeps the match status the whole status.
check_chart_http() {
  local repo="$1" name="$2" index versions
  if ! have curl; then
    report UNCHECKED "chart -> $repo :: $name (no curl)"; unchecked=$((unchecked + 1)); return
  fi
  index="$(curl -sfL --max-time 120 "${repo%/}/index.yaml" 2>/dev/null)"
  if [ -z "$index" ]; then
    report FAIL "chart -> $repo (no index.yaml)"; bad=$((bad + 1)); return
  fi
  if grep -q "name: *$name\$" <<<"$index"; then
    report OK "chart -> $repo :: $name"; ok=$((ok + 1))
    if [ "$tags" -gt 0 ]; then
      versions="$(grep -A3 "name: *$name\$" <<<"$index" | grep 'version:')"
      head -n "$tags" <<<"$versions" | sed 's/^/            /'
    fi
  else
    report FAIL "chart -> $repo :: $name is not in that repository's index"
    bad=$((bad + 1))
  fi
}

# Into an array rather than through a pipe: a `while read` on the right-hand side of a pipeline runs
# in a subshell, and every counter incremented in it would be discarded at the end.
mapfile -t parsed < <(printf '%s' "$rows" | jq -c '.[]')

for row in "${parsed[@]}"; do
  group=$(printf '%s' "$row" | jq -r .group)
  name=$(printf '%s' "$row" | jq -r .name)
  delivery=$(printf '%s' "$row" | jq -r .delivery)
  image=$(printf '%s' "$row" | jq -r '.image // empty')
  chartRepo=$(printf '%s' "$row" | jq -r '.chartRepo // empty')
  chartName=$(printf '%s' "$row" | jq -r '.chartName // empty')

  echo "$group.$name ($delivery)"

  case "$delivery" in
    image)
      if [ -z "$image" ]; then
        report FAIL "an image delivery with no coordinate at all -- a check asserts this cannot happen"
        bad=$((bad + 1))
      else
        check_oci "$image" "image"
      fi
      ;;
    chart)
      case "$chartRepo" in
        oci://*) check_oci "${chartRepo#oci://}/$chartName" "chart" ;;
        http*)   check_chart_http "$chartRepo" "$chartName" ;;
        *)       report FAIL "chart -> unrecognised repository scheme: $chartRepo"; bad=$((bad + 1)) ;;
      esac
      ;;
    *)
      report FAIL "unrecognised delivery: $delivery"; bad=$((bad + 1))
      ;;
  esac
done

echo
echo "checked: $ok ok, $bad failed, $unchecked unchecked"
echo
echo "A FAIL is not automatically a bug in the catalogue -- a registry that is down looks exactly like"
echo "one that moved. Re-run before changing a coordinate, and change it only for a repository that is"
echo "genuinely gone."
[ "$bad" -eq 0 ]
