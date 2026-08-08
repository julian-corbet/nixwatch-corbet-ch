# Asserts what this half actually RENDERS, by reading the manifests out of the rendered environment
# with a YAML parser.
#
# Why not just evaluate: a module that type-checks can still render a store whose data directory is
# not mounted, a status pane in the same namespace as the stack it is supposed to be independent of,
# or a retention argument that never reaches the process. None of that is an eval error. The first
# is a store that reports zero and looks healthy; the second is the failure this whole repository
# exists to prevent; the third is a declaration that says thirty days beside a process keeping one
# month because nothing passed the number along.
#
# ── THE TWO CENTRAL ASSERTIONS IN THIS FILE ARE ABSENCES ──────────────────────────────────────
#
#   1. NO OBSERVABILITY ADDRESS APPEARS ANYWHERE IN THE ALARM PATH'S OBJECTS. Checked on the bytes,
#      not on the model: the alarm path may never acquire a dependency on the observability path,
#      and a claim about a boundary is worth exactly as much as the grep that reads the output and
#      finds nothing there.
#   2. NO DERIVED ADDRESS APPEARS ANYWHERE IN THE RENDERED TREE AT ALL. This module publishes the
#      data-source and push addresses and renders neither, because both are consumed by a
#      configuration file belonging to somebody else's software. "Published rather than rendered" is
#      a claim about what is NOT in the manifests, so it is checked as one.
{ pkgs, lib, env }:

pkgs.runCommand "nixwatch-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not manifests, so they cannot be asserted from the tree: the reports that say which path each
  # workload landed on, what each pillar costs to keep, and which workloads deliberately hold no
  # position in the fleet's identity space.
  observabilityPath = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixwatch.cluster.observabilityPath);
  alarmPath = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixwatch.cluster.alarmPath);
  unaddressed = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixwatch.cluster.unaddressed);
  byGrammar = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixwatch.cluster.renderedByGrammar);
  directly = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixwatch.cluster.renderedDirectly);
  # One line per pillar: what it holds, how long, what drives its size, and whether the number
  # reaches the running store from here.
  retentionReport = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: r: "${name}\t${r.pillar}\t${r.retention}\t${r.growth}\tenforced=${lib.boolToString r.enforced}")
    env.config.nixwatch.cluster.retention);
  metricsSource = env.config.nixwatch.cluster.dashboardSources.example-dashboard.example-metrics.url;
  shipperTarget = env.config.nixwatch.cluster.shipperTargets.example-shipper.url;
} ''
  set -euo pipefail
  fail=0

  check() {
    if [ "$2" = "$3" ]; then
      echo "  ok   $1: $3"
    else
      echo "  FAIL $1: expected '$2', got '$3'"
      fail=1
    fi
  }

  present() {
    if [ -e "$2" ]; then echo "  ok   $1: rendered"; else echo "  FAIL $1: not rendered ($2)"; fail=1; fi
  }

  absent() {
    if [ -e "$2" ]; then echo "  FAIL $1: rendered but should not be ($2)"; fail=1; else echo "  ok   $1: correctly not rendered"; fi
  }

  y() { yq -r "$1" "$2"; }

  OBS_NS=example-observability
  ALARM_NS=example-status

  MET_D=$manifests/example-metrics/Deployment-example-metrics.yaml
  MET_S=$manifests/example-metrics/Service-example-metrics.yaml
  MET_NS=$manifests/example-metrics/Namespace-example-observability.yaml
  LOG_D=$manifests/example-logs/Deployment-example-logs.yaml
  TRC_D=$manifests/example-traces/Deployment-example-traces.yaml
  TRC_S=$manifests/example-traces/Service-example-traces.yaml
  DASH_D=$manifests/example-dashboard/Deployment-example-dashboard.yaml
  DASH_S=$manifests/example-dashboard/Service-example-dashboard.yaml
  STAT_D=$manifests/example-status/Deployment-example-status.yaml
  STAT_NS=$manifests/example-status/Namespace-example-status.yaml
  SHIP_DS=$manifests/example-shipper/DaemonSet-example-shipper.yaml

  echo "== the whole rendered status pane -- the alarm path, in full, inside a cluster =="
  cat $STAT_D

  echo
  echo "== THE ALARM PATH NAMES NOTHING ON THE OBSERVABILITY PATH. Checked on the bytes. =="
  # Every derived in-cluster coordinate of the stack, and the stack's namespace itself. A build
  # script for this repository's whole thesis: if any of these turns up in the prober's objects, the
  # alarm has moved inside the thing it was supposed to be outside of.
  for f in $(find -L $manifests/example-status -type f | sort); do
    for needle in ".$OBS_NS.svc" "example-metrics" "example-logs" "example-traces" "example-dashboard"; do
      if grep -q "$needle" "$f"; then
        echo "  FAIL the alarm path names the observability path ($needle in $f)"; fail=1
      fi
    done
  done
  echo "  ok   no object of the alarm path names any store, the dashboard, or their namespace"
  check "the prober lands in its own namespace"      "$ALARM_NS" "$(y '.metadata.namespace' $STAT_D)"
  check "and nothing of the stack does"              "$OBS_NS"   "$(y '.metadata.namespace' $MET_D)"
  # From the other side: nothing at all is rendered into the alarm namespace except the prober.
  for f in $(find -L $manifests -type f -name '*.yaml' | sort); do
    ns=$(y '.metadata.namespace // ""' $f)
    if [ "$ns" = "$ALARM_NS" ] && ! printf '%s' "$f" | grep -q 'example-status\|apps/Application'; then
      echo "  FAIL something other than the prober is in the alarm namespace: $f"; fail=1
    fi
  done
  echo "  ok   the alarm namespace holds the prober and nothing else"

  echo
  echo "== PUBLISHED, NOT RENDERED: no derived address is anywhere in the tree =="
  # A data source and a push destination are consumed by configuration files this module does not
  # write. The addresses exist in the report; they must exist nowhere in the manifests.
  check "the report derived a data-source address" \
    "http://example-metrics.$OBS_NS.svc.cluster.local:8428" "$metricsSource"
  check "and a push address for the shipper" \
    "http://example-logs.$OBS_NS.svc.cluster.local:3100" "$shipperTarget"
  for needle in "$metricsSource" "$shipperTarget"; do
    if grep -rq -- "$needle" $manifests/; then
      echo "  FAIL a derived address was rendered into the tree: $needle"; fail=1
    fi
  done
  echo "  ok   neither address appears in any manifest -- the consumer's own config consumes them"

  echo
  echo "== THE RETENTION EACH PILLAR DECLARES, AND WHETHER IT REACHES THE PROCESS =="
  printf '%s\n' "$retentionReport"
  # The one store whose retention is a command-line argument: the declared number, verbatim, with
  # its unit -- never translated, because this repository's duration grammar and this program's
  # disagree about what a bare number means.
  check "the metrics store runs with the declared retention" "-retentionPeriod=30d" \
    "$(y '.spec.template.spec.containers[0].args[0]' $MET_D)"
  # The two that read a file instead get no argument at all, rather than one that does nothing.
  check "the log store is given no retention argument"   "null" "$(y '.spec.template.spec.containers[0].args' $LOG_D)"
  check "the trace store is given no retention argument" "null" "$(y '.spec.template.spec.containers[0].args' $TRC_D)"

  echo
  echo "== the stores: their own directories, mounted, and a strategy that keeps one writer =="
  check "the metrics directory is the catalogue's" "/victoria-metrics-data" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data") | .mountPath' $MET_D)"
  check "the log directory is the catalogue's"     "/loki" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data") | .mountPath' $LOG_D)"
  check "the trace directory is the catalogue's"   "/var/tempo" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data") | .mountPath' $TRC_D)"
  check "backing is the declaration's"             "/example/state/metrics" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.path' $MET_D)"
  # An empty directory is not a fresh start for a store: it is a retention window beginning now,
  # reported as zero rather than as a problem.
  check "a missing directory refuses to start rather than starting empty" "Directory" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.type' $MET_D)"
  check "single writer: state forces Recreate, never a rolling update" "Recreate" "$(y '.spec.strategy.type' $MET_D)"
  check "one replica" "1" "$(y '.spec.replicas' $MET_D)"

  echo
  echo "== a trace store answers a reader on one port and takes spans on another =="
  check "query port"   "3200" \
    "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "http") | .containerPort' $TRC_D)"
  check "write port"   "4317" \
    "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "otlp-grpc") | .containerPort' $TRC_D)"
  check "and the Service carries both, by name" "http" "$(y '.spec.ports[] | select(.port == 3200) | .targetPort' $TRC_S)"

  echo
  echo "== TWO THINGS A PERSON OPENS, THE REST TALKED TO ONLY BY OTHER COMPONENTS =="
  check "the dashboard carries an exposure class" "nb" \
    "$(y '.metadata.labels."nixk3s.dev/exposure"' $DASH_D)"
  check "the status pane too"                     "nb" \
    "$(y '.metadata.labels."nixk3s.dev/exposure"' $STAT_D)"
  # Not "happens to be internal": there is no exposure option on a store anywhere in the module.
  for f in "$MET_D" "$LOG_D" "$TRC_D"; do
    check "$(basename $f): no front, structurally" "internal" "$(y '.metadata.labels."nixk3s.dev/exposure"' $f)"
  done
  check "the workloads holding no position at all" \
    "example-logs example-metrics example-metrics-stack example-shipper example-traces" "$unaddressed"
  # Still reachable BY NAME, which is the whole point: a store has an in-cluster address and no
  # fleet identity.
  present "the metrics store's Service" "$MET_S"
  for svc in $(find -L $manifests -type f -name 'Service-*.yaml' | sort); do
    check "$(basename $svc): type"           "ClusterIP" "$(y '.spec.type' $svc)"
    check "$(basename $svc): no pinned IP"   "null"      "$(y '.spec.clusterIP' $svc)"
    check "$(basename $svc): no LB address"  "null"      "$(y '.spec.loadBalancerIP' $svc)"
    check "$(basename $svc): no nodePort"    "null"      "$(y '.spec.ports[0].nodePort' $svc)"
  done

  echo
  echo "== A SHIPPER IS NOT A STORE, and the render says so too =="
  present "the shipper's own objects" "$SHIP_DS"
  check "it is one per node, which the grammar has no term for" "DaemonSet" "$(y '.kind' $SHIP_DS)"
  absent "a Deployment for the shipper" "$manifests/example-shipper/Deployment-example-shipper.yaml"
  absent "a Service for the shipper"    "$manifests/example-shipper/Service-example-shipper.yaml"
  absent "a volume claim for a shipper" "$manifests/example-shipper/PersistentVolumeClaim-example-shipper.yaml"

  echo
  echo "== the dashboard: a credential as a reference, never as a value =="
  check "the admin password is a reference" "example-dashboard-admin" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "GF_SECURITY_ADMIN_PASSWORD") | .valueFrom.secretKeyRef.name' $DASH_D)"
  check "and never a value"                 "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "GF_SECURITY_ADMIN_PASSWORD") | .value' $DASH_D)"
  absent "a rendered Secret object anywhere" "$manifests/example-dashboard/Secret-example-dashboard-admin.yaml"
  check "the dashboard's Service targets its port by name" "http" "$(y '.spec.ports[0].targetPort' $DASH_S)"

  echo
  echo "== each namespace is anchored by a grammar-rendered workload, so it cannot be cascade-deleted =="
  present "the observability namespace" "$MET_NS"
  present "the alarm namespace"         "$STAT_NS"
  check "observability ns Prune=false" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $MET_NS)"
  check "alarm ns Prune=false"         "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $STAT_NS)"

  echo
  echo "== a large custom resource cannot be applied client-side: server-side apply and diff =="
  for app in example-metrics-stack example-shipper; do
    check "$app: SSA" "ServerSideApply=true" \
      "$(y '.spec.syncPolicy.syncOptions[0]' $manifests/apps/Application-$app.yaml)"
    check "$app: SSD" "ServerSideDiff=true" \
      "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $manifests/apps/Application-$app.yaml)"
  done
  check "and NOT on an ordinary rendered workload" "null" \
    "$(y '.spec.syncPolicy.syncOptions' $manifests/apps/Application-example-metrics.yaml)"

  echo
  echo "== the two paths and the render split are countable =="
  check "observability path" "example-dashboard example-logs example-metrics example-metrics-stack example-shipper example-traces" "$observabilityPath"
  check "alarm path"         "example-status" "$alarmPath"
  check "rendered by the grammar" "example-dashboard example-logs example-metrics example-status example-traces" "$byGrammar"
  check "rendered below it"       "example-metrics-stack example-shipper" "$directly"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match this module's promises" >&2
    exit 1
  fi
  echo "all render assertions hold"
  cp -rL $manifests $out
''
