# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders this whole declaration through the real app grammar and the real
# renderer, so a module that stops evaluating, or that grows a required value nobody supplies,
# fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, node path, Secret name, slot number, URL and image tag is
# invented for this file, and no credential appears in any form — only the NAMES of Secrets that
# would hold them.
#
# The declarations are chosen to put BOTH PATHS in one render, and to cover the cases that differ
# in what is RENDERED rather than merely in what evaluates:
#
#   - all three pillars, each with its own retention and its own growth term, so the report that
#     says what each one costs to keep has three genuinely different rows in it;
#   - a metrics store whose retention reaches the process as an argument, beside a whole-stack
#     chart whose retention lives in a file this module does not render — `enforced` is true for
#     one and false for the other, and both are declared;
#   - a log shipper, delivered as whole objects because it runs one copy per node, pushing to the
#     log store at an address nobody wrote down;
#   - a dashboard that NAMES the three stores it reads and no address at all;
#   - a status pane on the OTHER path, in its own namespace, watching only things outside this
#     render — which is the only kind of target it is allowed to have.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # A cluster fact the app grammar refuses to guess: which node holds the directories that node-path
  # state lives on. Set once here instead of on every workload.
  nixk3s.appPlatform.hostPathNodeSelector = { "kubernetes.io/hostname" = "example-node"; };

  # The band model, with the layout a consumer would supply. Every value is invented: the model
  # ships no band, no base and no binding of its own.
  nixk3s.addressing = {
    enable = true;
    bands.example-observability = {
      base = 96;
      size = 16;
      description = "the things a person opens to find out what is happening";
    };
    bindings.nixwatch = "example-observability";
  };

  nixwatch.cluster.platform = {
    # THE TWO NAMESPACES ARE THE SEPARATION. The whole observability stack can be deleted and
    # rebuilt without touching the thing that decides something is broken — and the guard that
    # refuses a probe target pointing into the stack is built from this difference.
    namespace = "example-observability";
    alarmNamespace = "example-status";
    project = "example-observability";
    # Hands the grammar-rendered workloads' slots to the band model above. Null (the default)
    # everywhere that model is not part of the render.
    origin = "nixwatch";
  };

  nixwatch.cluster.metrics = {
    # The single-binary store: this module renders its Service, so its address can be derived and a
    # dashboard is allowed to name it. It anchors the observability namespace because it is rendered
    # by the app grammar and therefore stamps the protection a namespace holding data needs.
    example-metrics = {
      store = "victoria-metrics";
      # Deliberately tag-only, so the render sees the grammar's unpinned-image warning fire as well
      # as the digest-pinned path further down.
      version = "0.0.0";
      # This declaration is taking over an existing grammar-rendered workload, so its Application
      # compares and applies through the API server during the adoption window.
      adopt = true;
      createNamespace = true;
      # Retention and cardinality: the two numbers that multiply into what this pillar costs. The
      # retention reaches the process as an argument this module renders.
      retention = "30d";
      activeSeries = 500000;
      state.data.hostPath = "/example/state/metrics";
    };

    # The whole-stack chart. Declared for the accounting and the interlocks; it renders its own
    # Services from its own template, so nothing here derives an address for it and the dashboard
    # below deliberately does not name it.
    example-metrics-stack = {
      store = "victoria-metrics-k8s-stack";
      retention = "90d";
      activeSeries = 1200000;
      manifests = [
        ''
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: example-metrics-stack-operator
            namespace: example-observability
        ''
      ];
    };
  };

  nixwatch.cluster.logs.example-logs = {
    store = "loki";
    # A whole reference rather than a version: pinned by digest, which is what the grammar asks for
    # and what the metrics store above deliberately does not do.
    image = "registry.example.com/example-org/example-loki:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    # Traffic, not cardinality: nothing about the number of things watched predicts this number.
    retention = "14d";
    ingestMiBPerDay = 2048;
    state.data.hostPath = "/example/state/logs";
  };

  nixwatch.cluster.traces.example-traces = {
    store = "tempo";
    version = "0.0.0";
    # The pillar whose answer to cost is to keep less of it, not to keep it for less long.
    retention = "3d";
    sampledPercent = 10;
    state.data.hostPath = "/example/state/traces";
  };

  # One copy per node, so its objects arrive whole: the app grammar renders a Deployment from an
  # image, and that is not a DaemonSet. It has no retention, no growth term and nothing to back,
  # because it keeps no data — only how far it has read.
  nixwatch.cluster.shippers.example-shipper = {
    shipper = "alloy";
    # The push address is DERIVED from this name. Nothing in this file writes one down.
    ships = "example-logs";
    manifests = [
      ''
        apiVersion: apps/v1
        kind: DaemonSet
        metadata:
          name: example-shipper
          namespace: example-observability
        spec:
          selector:
            matchLabels:
              app.kubernetes.io/name: example-shipper
          template:
            metadata:
              labels:
                app.kubernetes.io/name: example-shipper
            spec:
              containers:
                - name: alloy
                  image: registry.example.com/example-org/example-alloy:0.0.0
      ''
    ];
  };

  # A CONSUMER of the three pillars. It names stores; it names no address at all.
  nixwatch.cluster.dashboards.example-dashboard = {
    dashboard = "grafana";
    version = "0.0.0";
    slot = 96;
    exposure = "nb";
    reads = [ "example-metrics" "example-logs" "example-traces" ];
    state.data.hostPath = "/example/state/dashboard";
    # Required by the catalogue, because the alternative to setting one is not "no password".
    credentials = {
      adminUser = { secret = "example-dashboard-admin"; key = "user"; };
      adminPassword = { secret = "example-dashboard-admin"; key = "password"; };
    };
  };

  # THE ALARM PATH, in its own namespace, which it anchors. Every target is outside this render, and
  # nothing about this declaration could name a store even if somebody wanted it to.
  nixwatch.cluster.probers.example-status = {
    prober = "gatus";
    version = "0.0.0";
    slot = 97;
    exposure = "nb";
    createNamespace = true;
    state.data.hostPath = "/example/state/status";
    targets = {
      example-site.url = "https://example.com/healthz";
      example-gateway.url = "https://gateway.example.com/status";
      # A plain TCP-shaped target on a host this render knows nothing about — the point being that
      # what a black-box prober dials is, by definition, not something this module can derive.
      example-upstream.url = "https://upstream.example.org/generate_204";
    };
  };
}
