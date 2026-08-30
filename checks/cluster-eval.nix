# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# declaration with exactly one thing wrong, and the `control` case is the same shape with nothing
# wrong and MUST render -- without it, a typo in the shared base would make every other case "pass"
# for the wrong reason.
#
# ── THE PART THAT IS NOT AN ASSERTION ──────────────────────────────────────────────────────────
#
# Several of the most important refusals here are not guards at all: giving a store a front, giving
# a prober a list of stores to read, or asking a log store what fraction of traffic it samples are
# all UNKNOWN OPTIONS. Those cases are in `structurallyImpossible` below and they fail with "the
# option does not exist" -- the difference between a boundary somebody has to remember and one
# nobody can cross. Asserted here so that adding such an option back would break this check rather
# than quietly widening the surface.
#
# ── THE ONE WHOSE MESSAGE IS ASSERTED WORD BY WORD ────────────────────────────────────────────
#
# The cross-path refusal. `tryEval` can only say THAT something was refused, and this is the one
# refusal whose whole value is what it says: it has to name the field, name what the field pointed
# at, and quote the rule -- because a person who wrote that line believed it was reasonable, and
# "refused" alone would read as an arbitrary restriction rather than as the failure mode it is.
{ pkgs, lib, nixidy, appsModule, addressingModule, clusterModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixwatch.cluster.platform = {
      namespace = "example-observability";
      alarmNamespace = "example-status";
      project = "example-observability";
    };
  };

  mkEnv = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule addressingModule clusterModule base values ];
  };

  renders = values:
    (builtins.tryEval (builtins.seq (mkEnv values).environmentPackage.drvPath true)).success;

  # The assertions themselves rather than the throw they eventually cause.
  failures = values:
    map (a: a.message)
      (lib.filter (a: !a.assertion) (mkEnv values).config.nixidy.assertions);

  # Cross-root layout and delivery invariants now belong to the shared factory. A bad declaration
  # must therefore produce one factory diagnostic, not one from the factory and one from a retired
  # local translator.
  failsExactlyOnceWith = infix: values:
    let
      result = builtins.tryEval (lib.length (lib.filter
        (assertion: !assertion.assertion && lib.hasInfix infix assertion.message)
        (mkEnv values).config.nixidy.assertions));
    in
    result.success && result.value == 1;

  sorted = lib.sort (a: b: a < b);

  catalogue = import ../lib/observability.nix { };

  ## ---------------------------------------------------------------------
  ## The floor: an empty declaration renders nothing at all
  ## ---------------------------------------------------------------------

  emptyCfg = (mkEnv { }).config;

  ## ---------------------------------------------------------------------
  ## The control: all three pillars, both paths, and it must resolve
  ## ---------------------------------------------------------------------

  good = {
    nixwatch.cluster.metrics = {
      example-metrics = {
        store = "victoria-metrics";
        version = "0.0.0";
        adopt = true;
        createNamespace = true;
        retention = "30d";
        activeSeries = 500000;
        state.data.hostPath = "/example/state/metrics";
      };

      example-metrics-stack = {
        store = "victoria-metrics-k8s-stack";
        retention = "90d";
        activeSeries = 1200000;
        manifests = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: example-metrics-stack\n  namespace: example-observability\n" ];
      };
    };

    nixwatch.cluster.logs.example-logs = {
      store = "loki";
      version = "0.0.0";
      retention = "14d";
      ingestMiBPerDay = 2048;
      state.data.hostPath = "/example/state/logs";
    };

    nixwatch.cluster.traces.example-traces = {
      store = "tempo";
      version = "0.0.0";
      retention = "3d";
      sampledPercent = 10;
      state.data.hostPath = "/example/state/traces";
    };

    nixwatch.cluster.shippers.example-shipper = {
      shipper = "alloy";
      ships = "example-logs";
      manifests = [ "apiVersion: apps/v1\nkind: DaemonSet\nmetadata:\n  name: example-shipper\n  namespace: example-observability\n" ];
    };

    nixwatch.cluster.dashboards.example-dashboard = {
      dashboard = "grafana";
      version = "0.0.0";
      slot = 96;
      exposure = "nb";
      reads = [ "example-metrics" "example-logs" "example-traces" ];
      state.data.hostPath = "/example/state/dashboard";
      credentials = {
        adminUser = { secret = "example-dashboard-admin"; key = "user"; };
        adminPassword = { secret = "example-dashboard-admin"; key = "password"; };
      };
    };

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
      };
    };
  };

  goodCfg = (mkEnv good).config;

  referenceCfg = (mkEnv (lib.recursiveUpdate good {
    nixwatch.cluster.metrics.example-metrics-stack.manifests = [ ];
  })).config;

  # The address the module derives for the metrics store, written out here exactly as a person
  # would if they were about to make the mistake this repository exists to refuse.
  metricsAddress = "http://example-metrics.example-observability.svc.cluster.local:8428";

  ## ---------------------------------------------------------------------
  ## The failing direction: guards
  ## ---------------------------------------------------------------------

  mustFail = {
    # ── THE HEADLINE RULE, by all four routes anybody would actually take ───────────────────────
    prober-pointed-at-the-metrics-store =
      lib.recursiveUpdate good {
        nixwatch.cluster.probers.example-status.targets.example-metrics.url =
          "${metricsAddress}/health";
      };

    prober-pointed-anywhere-in-the-observability-namespace =
      lib.recursiveUpdate good {
        nixwatch.cluster.probers.example-status.targets.example-something.url =
          "http://something-else.example-observability.svc.cluster.local:9000/ready";
      };

    prober-naming-a-store-in-its-environment =
      lib.recursiveUpdate good {
        nixwatch.cluster.probers.example-status.env.EXAMPLE_UPSTREAM = "http://example-logs:3100";
      };

    prober-naming-a-store-in-its-arguments =
      lib.recursiveUpdate good {
        nixwatch.cluster.probers.example-status.args = [ "--example-flag=${metricsAddress}" ];
      };

    # ── The dashboard's typed relationship to the pillars ───────────────────────────────────────
    dashboard-reading-a-store-nobody-declared =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.reads = [ "example-metrics" "nonesuch" ];
      };

    # A chart names its own Services; the address this module would derive is one it never creates.
    dashboard-reading-a-chart-delivered-store =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.reads = [ "example-metrics-stack" ];
      };

    dashboard-reading-nothing =
      lib.recursiveUpdate good { nixwatch.cluster.dashboards.example-dashboard.reads = [ ]; };

    dashboard-missing-its-required-credential =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.credentials = lib.mkForce { };
      };

    credential-role-the-software-does-not-read =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.credentials.nonesuch =
          { secret = "x"; key = "y"; };
      };

    # ── A shipper is not a store, and it does not push into an arbitrary one ────────────────────
    shipper-pushing-into-a-metrics-store =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.ships = "example-metrics"; };

    shipper-pushing-into-a-store-nobody-declared =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.ships = "nonesuch"; };

    # The right pillar, delivered the wrong way: a split log store's chart names several Services of
    # its own, and a writer's is not a reader's. The derived address would reach neither.
    shipper-pushing-into-a-chart-delivered-store =
      lib.recursiveUpdate good {
        nixwatch.cluster.logs.example-chart-logs = {
          store = "loki-chart";
          retention = "14d";
          ingestMiBPerDay = 4096;
          manifests = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: example-chart-logs\n  namespace: example-observability\n" ];
        };
        nixwatch.cluster.shippers.example-shipper.ships = "example-chart-logs";
      };

    # ── Retention: the number that says what a pillar costs to keep ─────────────────────────────
    store-with-a-unitless-retention =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.retention = "30"; };

    store-with-a-retention-this-repository-cannot-parse =
      lib.recursiveUpdate good { nixwatch.cluster.logs.example-logs.retention = "two weeks"; };

    # An unbacked store keeps data until its next restart, not for the period declared above it.
    store-with-an-unbacked-directory =
      lib.recursiveUpdate good {
        nixwatch.cluster.traces.example-second-traces = {
          store = "tempo";
          version = "0.0.0";
          retention = "3d";
          sampledPercent = 5;
        };
      };

    state-with-no-backing =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.state.data.hostPath = null; };

    state-with-both-backings =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.state.data.claim = "example-metrics-data"; };

    # A trace store keeping nothing answers no question and still costs a workload and a volume.
    # Refused by the option's own TYPE -- which only bites because the module forces the growth term
    # during a render rather than only when the report is read. See `costAssertions`.
    trace-store-that-keeps-none-of-the-traffic =
      lib.recursiveUpdate good { nixwatch.cluster.traces.example-traces.sampledPercent = 0; };

    # And the same forcing is what makes the growth term genuinely required rather than merely
    # undefaulted: a store declared without one would otherwise render happily.
    store-that-does-not-say-what-drives-its-size =
      lib.recursiveUpdate good {
        nixwatch.cluster.logs.example-second-logs = {
          store = "loki";
          version = "0.0.0";
          retention = "7d";
          state.data.hostPath = "/example/state/logs-two";
        };
      };

    # ── The prober itself ───────────────────────────────────────────────────────────────────────
    prober-watching-nothing =
      lib.recursiveUpdate good { nixwatch.cluster.probers.example-status.targets = lib.mkForce { }; };

    # ── The two namespaces ARE the separation ───────────────────────────────────────────────────
    one-namespace-for-both-paths =
      lib.recursiveUpdate good { nixwatch.cluster.platform.alarmNamespace = "example-observability"; };

    # ── Delivery ────────────────────────────────────────────────────────────────────────────────
    image-delivered-workload-passing-verbatim-objects =
      lib.recursiveUpdate good {
        nixwatch.cluster.logs.example-logs.manifests =
          [ "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n" ];
      };

    chart-delivered-workload-naming-a-version =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics-stack.version = "0.0.0"; };

    chart-delivered-workload-naming-an-image =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.image = "example/image:0.0.0"; };

    chart-delivered-workload-claiming-adoption =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.adopt = true; };

    externally-delivered-chart-claiming-adoption =
      lib.recursiveUpdate good {
        nixwatch.cluster.metrics.example-metrics-stack.manifests = [ ];
        nixwatch.cluster.metrics.example-metrics-stack.adopt = true;
      };

    image-delivered-workload-naming-neither-version-nor-image =
      lib.recursiveUpdate good { nixwatch.cluster.traces.example-traces.version = null; };

    # ── Layout ──────────────────────────────────────────────────────────────────────────────────
    two-workloads-on-one-slot =
      lib.recursiveUpdate good { nixwatch.cluster.probers.example-status.slot = 96; };

    two-workloads-creating-one-namespace =
      lib.recursiveUpdate good { nixwatch.cluster.logs.example-logs.createNamespace = true; };

    # A Namespace created below the grammar carries none of the grammar's protection against being
    # pruned -- and this one would hold every measurement in the stack.
    directly-rendered-workload-anchoring-a-namespace =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.createNamespace = true; };

    # One name is one app, one set of objects, and the host part of every derived address.
    one-name-declared-in-two-groups =
      lib.recursiveUpdate good {
        nixwatch.cluster.traces.example-logs = {
          store = "tempo";
          version = "0.0.0";
          retention = "3d";
          sampledPercent = 10;
          state.data.hostPath = "/example/state/traces-two";
        };
      };
  };

  ## ---------------------------------------------------------------------
  ## The failing direction: the separations that are not guards
  ##
  ## Each of these is an UNKNOWN OPTION rather than a refused value. That is the whole claim of this
  ## module's design, so it is checked rather than asserted in prose.
  ## ---------------------------------------------------------------------

  structurallyImpossible = {
    # THE ONE-DIRECTIONAL RULE, at the level where it cannot be argued with: there is no term on an
    # alarm-path workload for naming anything on the observability path.
    prober-given-stores-to-read =
      lib.recursiveUpdate good {
        nixwatch.cluster.probers.example-status.reads = [ "example-metrics" ];
      };

    prober-given-a-store-to-ship-to =
      lib.recursiveUpdate good { nixwatch.cluster.probers.example-status.ships = "example-logs"; };

    # A store is reached by in-cluster DNS from the two workloads allowed to name it. Nothing here
    # can give one a front or a fleet identity.
    store-given-an-exposure-class =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.exposure = "public"; };

    store-given-a-slot =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.slot = 98; };

    shipper-given-a-slot =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.slot = 98; };

    store-given-its-own-namespace =
      lib.recursiveUpdate good { nixwatch.cluster.logs.example-logs.namespace = "example-somewhere-else"; };

    prober-given-its-own-namespace =
      lib.recursiveUpdate good { nixwatch.cluster.probers.example-status.namespace = "example-somewhere-else"; };

    # A SHIPPER IS NOT A STORE: it keeps no data, so there is no question here of the form "how long
    # does it keep it".
    shipper-given-a-retention =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.retention = "14d"; };

    shipper-given-a-growth-term =
      lib.recursiveUpdate good { nixwatch.cluster.shippers.example-shipper.ingestMiBPerDay = 2048; };

    # THE THREE PILLARS ARE NOT INTERCHANGEABLE. Each group takes the one growth term that prices
    # it, and the other two are not terms at all.
    metrics-store-asked-how-many-bytes-a-day =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.ingestMiBPerDay = 2048; };

    log-store-asked-what-fraction-it-samples =
      lib.recursiveUpdate good { nixwatch.cluster.logs.example-logs.sampledPercent = 10; };

    trace-store-asked-its-cardinality =
      lib.recursiveUpdate good { nixwatch.cluster.traces.example-traces.activeSeries = 500000; };

    # A dashboard names stores. There is no URL option on one anywhere in this module.
    dashboard-given-a-data-source-url =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.url = metricsAddress;
      };

    # A store is the single writer of its own data directory. There is no replica count anywhere in
    # this module, on either path.
    workload-given-a-replica-count =
      lib.recursiveUpdate good { nixwatch.cluster.metrics.example-metrics.replicas = 2; };

    # The factory's wider generic vocabulary must not silently widen nixwatch's established
    # declaration contract. These remain unknown/type-invalid at the public nested path.
    workload-given-factory-resources =
      lib.recursiveUpdate good {
        nixwatch.cluster.metrics.example-metrics.resources.cpuRequest = "10m";
      };

    workload-given-factory-state-backing =
      lib.recursiveUpdate good {
        nixwatch.cluster.metrics.example-metrics.state.data.emptyDir = true;
      };

    workload-given-declaration-read-only =
      lib.recursiveUpdate good {
        nixwatch.cluster.metrics.example-metrics.state.data.readOnly = true;
      };

    workload-given-variable-shaped-credentials =
      lib.recursiveUpdate good {
        nixwatch.cluster.dashboards.example-dashboard.credentials.keys.GF_SECURITY_ADMIN_PASSWORD =
          "password";
      };
  };

  wronglyRendered =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) mustFail));
  wronglyAccepted =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) structurallyImpossible));

  ## ---------------------------------------------------------------------
  ## Messages, read as text
  ## ---------------------------------------------------------------------

  firstMatching = values: needle:
    let msgs = lib.filter (m: lib.hasInfix needle m) (failures values); in
    if msgs == [ ] then "" else lib.head msgs;

  crossPathMessage =
    firstMatching mustFail.prober-pointed-at-the-metrics-store "MAY NEVER ACQUIRE A DEPENDENCY";
  envRouteMessage =
    firstMatching mustFail.prober-naming-a-store-in-its-environment "MAY NEVER ACQUIRE A DEPENDENCY";
  unknownStoreMessage =
    firstMatching mustFail.dashboard-reading-a-store-nobody-declared "nonesuch";
  unbackedMessages = failures mustFail.store-with-an-unbacked-directory;
  pillarMessage =
    firstMatching mustFail.shipper-pushing-into-a-metrics-store "example-shipper";

  ## ---------------------------------------------------------------------
  ## The catalogue's own internal consistency
  ##
  ## Facts about the DATA rather than about any declaration, and the kind that rots silently: an
  ## entry added without a coordinate, or a per-node workload marked as one image.
  ## ---------------------------------------------------------------------

  allEntries = lib.concatMap
    (g: lib.mapAttrsToList (n: e: { group = g; name = n; entry = e; }) catalogue.${g})
    (lib.attrNames catalogue);

  storeEntries = lib.filter (x: lib.elem x.group [ "metrics" "logs" "traces" ]) allEntries;

  ## ---------------------------------------------------------------------
  ## Positive resolution
  ## ---------------------------------------------------------------------

  addressed = (mkEnv (lib.recursiveUpdate good {
    nixwatch.cluster.platform.origin = "nixwatch";
    nixk3s.addressing = {
      enable = true;
      bands.example-observability = { base = 96; size = 16; };
      bindings.nixwatch = "example-observability";
    };
  })).config;

  results = {
    # ── The floor ─────────────────────────────────────────────────────────────────────────────
    "an empty declaration defines no app in the grammar at all" =
      emptyCfg.nixk3s.apps == { };

    "an empty declaration reports nothing on either path, nothing rendered, and no slot" =
      emptyCfg.nixwatch.cluster.observabilityPath == [ ]
      && emptyCfg.nixwatch.cluster.alarmPath == [ ]
      && emptyCfg.nixwatch.cluster.renderedByGrammar == [ ]
      && emptyCfg.nixwatch.cluster.renderedDirectly == [ ]
      && emptyCfg.nixwatch.cluster.notRendered == [ ]
      && emptyCfg.nixwatch.cluster.clusterSlots == { }
      && emptyCfg.nixwatch.cluster.slots == { }
      && emptyCfg.nixwatch.cluster.retention == { };

    "an empty declaration raises no assertion of its own -- an unused module must be silent" =
      lib.all (a: a.assertion) emptyCfg.nixidy.assertions;

    # ── The control ───────────────────────────────────────────────────────────────────────────
    "a declaration covering all three pillars and both paths renders" = renders good;

    "adoption reaches exactly the image declaration that asked for it" =
      goodCfg.nixk3s.apps.example-metrics.adopt
      && !goodCfg.nixk3s.apps.example-logs.adopt
      && !goodCfg.nixk3s.apps.example-traces.adopt
      && !goodCfg.nixk3s.apps.example-dashboard.adopt
      && !goodCfg.nixk3s.apps.example-status.adopt;

    "the two paths are exactly the workloads their catalogue entries put there" =
      sorted goodCfg.nixwatch.cluster.observabilityPath
      == [ "example-dashboard" "example-logs" "example-metrics" "example-metrics-stack" "example-shipper" "example-traces" ]
      && goodCfg.nixwatch.cluster.alarmPath == [ "example-status" ];

    "the factory inhabits the established nested option path without a sibling mirror" =
      goodCfg.nixwatch.cluster.metrics.example-metrics.store == "victoria-metrics"
      && !(goodCfg.nixwatch ? metrics);

    "a workload's namespace is its PATH's, and nothing declared it" =
      goodCfg.nixk3s.apps.example-metrics.namespace == "example-observability"
      && goodCfg.nixk3s.apps.example-dashboard.namespace == "example-observability"
      && goodCfg.applications.example-shipper.namespace == "example-observability"
      && goodCfg.nixk3s.apps.example-status.namespace == "example-status";

    "the render split is countable: images through the grammar, whole objects below it" =
      sorted goodCfg.nixwatch.cluster.renderedByGrammar
      == [ "example-dashboard" "example-logs" "example-metrics" "example-status" "example-traces" ]
      && sorted goodCfg.nixwatch.cluster.renderedDirectly
      == [ "example-metrics-stack" "example-shipper" ]
      && goodCfg.nixwatch.cluster.notRendered == [ ];

    "a chart left to an external Application is projected as a reference, not a rendered object" =
      referenceCfg.nixwatch.cluster.notRendered == [ "example-metrics-stack" ]
      && referenceCfg.nixwatch.cluster.renderedDirectly == [ "example-shipper" ]
      && !(referenceCfg.applications ? example-metrics-stack);

    # ── WHAT EACH PILLAR COSTS TO KEEP, in three genuinely different units ────────────────────
    "the three pillars report three different growth terms, not one shared number" =
      goodCfg.nixwatch.cluster.retention.example-metrics.growth == "500000 active series"
      && goodCfg.nixwatch.cluster.retention.example-logs.growth == "2048 MiB per day"
      && goodCfg.nixwatch.cluster.retention.example-traces.growth == "10% of traces kept";

    "each row names its pillar and its retention, in prose and in seconds" =
      goodCfg.nixwatch.cluster.retention.example-metrics.pillar == "metrics"
      && goodCfg.nixwatch.cluster.retention.example-traces.pillar == "traces"
      && goodCfg.nixwatch.cluster.retention.example-logs.retention == "14d"
      && goodCfg.nixwatch.cluster.retention.example-logs.retentionSeconds == 1209600
      && goodCfg.nixwatch.cluster.retention.example-traces.retentionSeconds == 259200;

    # The honest half of the report: which declared retentions actually reach the running store.
    "the report says which retentions are enforced from here and which live in a file it does not render" =
      goodCfg.nixwatch.cluster.retention.example-metrics.enforced
      && !goodCfg.nixwatch.cluster.retention.example-logs.enforced
      && !goodCfg.nixwatch.cluster.retention.example-traces.enforced;

    "an enforced retention reaches the container as an argument, and an unenforced one adds none" =
      goodCfg.nixk3s.apps.example-metrics.args == [ "-retentionPeriod=30d" ]
      && goodCfg.nixk3s.apps.example-logs.args == [ ]
      && goodCfg.nixk3s.apps.example-traces.args == [ ];

    "a chart-delivered store is still accounted for, even though it renders no container" =
      goodCfg.nixwatch.cluster.retention.example-metrics-stack.retention == "90d"
      && goodCfg.nixwatch.cluster.retention.example-metrics-stack.growth == "1200000 active series"
      && !(goodCfg.nixk3s.apps ? example-metrics-stack);

    # ── THE DASHBOARD NAMES STORES; THE ADDRESSES ARE DERIVED ─────────────────────────────────
    "every data-source address is computed from the store's own declaration" =
      goodCfg.nixwatch.cluster.dashboardSources.example-dashboard.example-metrics.url
      == "http://example-metrics.example-observability.svc.cluster.local:8428"
      && goodCfg.nixwatch.cluster.dashboardSources.example-dashboard.example-logs.url
      == "http://example-logs.example-observability.svc.cluster.local:3100";

    "and each one carries the pillar it is, so a provisioning file never has to guess" =
      goodCfg.nixwatch.cluster.dashboardSources.example-dashboard.example-metrics.pillar == "metrics"
      && goodCfg.nixwatch.cluster.dashboardSources.example-dashboard.example-traces.pillar == "traces";

    # A trace store answers a dashboard on one port and takes spans on another. One `port` field
    # doing both jobs would have put a reader on the write path.
    "a reader gets the store's QUERY port, which is not always the port writers use" =
      goodCfg.nixwatch.cluster.dashboardSources.example-dashboard.example-traces.url
      == "http://example-traces.example-observability.svc.cluster.local:3200"
      && catalogue.traces.tempo.ports.${catalogue.traces.tempo.writePort} == 4317;

    "a shipper's push address is derived from the log store it names, on the WRITE port" =
      goodCfg.nixwatch.cluster.shipperTargets.example-shipper == {
        store = "example-logs";
        url = "http://example-logs.example-observability.svc.cluster.local:3100";
      };

    "what the prober watches is published in one place, and none of it is on the other path" =
      goodCfg.nixwatch.cluster.proberTargets.example-status == {
        example-site = "https://example.com/healthz";
        example-gateway = "https://gateway.example.com/status";
      };

    # ── ADDRESSABILITY: two things a person opens, four things only components talk to ────────
    "only the two workloads a person opens can hold a slot at all" =
      goodCfg.nixwatch.cluster.slots == { example-dashboard = 96; example-status = 97; }
      && goodCfg.nixwatch.cluster.clusterSlots == goodCfg.nixwatch.cluster.slots;

    "everything else is unaddressed STRUCTURALLY -- there is no slot option on any of them" =
      sorted goodCfg.nixwatch.cluster.unaddressed
      == [ "example-logs" "example-metrics" "example-metrics-stack" "example-shipper" "example-traces" ];

    "a store still renders a Service, because other components reach it by name" =
      goodCfg.nixk3s.apps.example-metrics.ports.http.number == 8428
      && goodCfg.nixk3s.apps.example-logs.ports.http.number == 3100
      && goodCfg.nixk3s.apps.example-traces.ports.otlp-grpc.number == 4317;

    "and it is never fronted: a store has no exposure option, so its class is the default" =
      goodCfg.nixk3s.apps.example-metrics.exposure == "internal"
      && goodCfg.nixk3s.apps.example-logs.exposure == "internal"
      && goodCfg.nixk3s.apps.example-dashboard.exposure == "nb"
      && goodCfg.nixk3s.apps.example-status.exposure == "nb";

    # ── The knowledge reaches the objects ─────────────────────────────────────────────────────
    "the image is the catalogue repository plus THIS workload's version" =
      goodCfg.nixk3s.apps.example-metrics.image == "docker.io/victoriametrics/victoria-metrics:0.0.0"
      && goodCfg.nixk3s.apps.example-status.image == "ghcr.io/twin/gatus:0.0.0";

    "each directory lands where the software writes it, backed by what the consumer supplied" =
      goodCfg.nixk3s.apps.example-metrics.state.data.mountPath == "/victoria-metrics-data"
      && goodCfg.nixk3s.apps.example-metrics.state.data.hostPath == "/example/state/metrics"
      && goodCfg.nixk3s.apps.example-traces.state.data.mountPath == "/var/tempo";

    "a credential arrives as a reference, under the variable the SOFTWARE names, never as a value" =
      goodCfg.nixk3s.apps.example-dashboard.secrets.adminPassword.secret == "example-dashboard-admin"
      && goodCfg.nixk3s.apps.example-dashboard.secrets.adminPassword.env.GF_SECURITY_ADMIN_PASSWORD == "password";

    "a probe watches the port the catalogue calls primary, with the software's own timing" =
      goodCfg.nixk3s.apps.example-metrics.probes.readiness.port == "http"
      && goodCfg.nixk3s.apps.example-metrics.probes.readiness.path == "/health"
      && goodCfg.nixk3s.apps.example-status.probes.readiness.path == "/health"
      && goodCfg.nixk3s.apps.example-traces.probes.readiness.path == "/ready";

    "everything rendered below the grammar carries server-side apply and server-side diff" =
      goodCfg.applications.example-shipper.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true"
      && goodCfg.applications.example-metrics-stack.compareOptions.serverSideDiff == "ServerSideDiff=true";

    # ── The band model ────────────────────────────────────────────────────────────────────────
    "with the band model in the render, grammar-rendered workloads carry the declaring origin" =
      addressed.nixk3s.apps.example-dashboard.origin == "nixwatch"
      && addressed.nixk3s.apps.example-dashboard.slot == 96;

    "and a store is stamped with the origin and NO number, deliberately" =
      addressed.nixk3s.apps.example-metrics.origin == "nixwatch"
      && addressed.nixk3s.apps.example-metrics.slot == null;

    "without that switch the grammar's apps name no origin at all -- those are the band model's terms" =
      goodCfg.nixk3s.apps.example-dashboard.origin == null
      && goodCfg.nixk3s.apps.example-dashboard.slot == null;

    # ── The catalogue's own consistency ───────────────────────────────────────────────────────
    "every image-delivered entry names an image repository, and no chart entry does" =
      lib.all
        (x:
          if x.entry.delivery == "image" then x.entry.image != null && x.entry.chart == null
          else x.entry.image == null && x.entry.chart != null)
        allEntries;

    # A per-node workload is a DaemonSet, and the grammar renders a Deployment from an image.
    "a per-node entry is never image-delivered" =
      lib.all (x: !(x.entry.perNode or false) || x.entry.delivery == "chart") allEntries;

    "every store this module renders names a query port and a write port it actually declares" =
      lib.all
        (x: x.entry.delivery != "image"
          || ((x.entry.ports ? ${x.entry.queryPort}) && (x.entry.ports ? ${x.entry.writePort})))
        storeEntries;

    "a store taking its retention as an argument has a template to put it in, and one reading a file has none" =
      lib.all
        (x:
          if x.entry.retentionVia == "argument"
          then x.entry.retentionArg != null && lib.hasInfix "{RETENTION}" x.entry.retentionArg
          else x.entry.retentionArg == null)
        storeEntries;

    "exactly one group is on the alarm path, and it is the prober" =
      lib.attrNames (lib.filterAttrs (_: e: e.path == "alarm") catalogue.probers)
      == lib.attrNames catalogue.probers
      && lib.all (x: x.group == "probers" || x.entry.path == "observability") allEntries;

    # ── The failing direction ─────────────────────────────────────────────────────────────────
    "every guard fires: nothing in the must-fail set renders" =
      wronglyRendered == [ ];

    "the separations are structural: every one of them is an unknown option" =
      wronglyAccepted == [ ];

    "the factory is the single cross-root slot-collision authority" =
      failsExactlyOnceWith "slot 96 is claimed by 2 workloads"
        mustFail.two-workloads-on-one-slot;

    "the factory is the single namespace-anchor collision authority" =
      failsExactlyOnceWith "namespace `example-observability` is anchored by 2 workloads"
        mustFail.two-workloads-creating-one-namespace;

    "the factory is the single direct-delivery namespace-safety authority" =
      failsExactlyOnceWith "non-grammar renderer cannot stamp"
        mustFail.directly-rendered-workload-anchoring-a-namespace;

    "the factory is the single typed-app manifest authority" =
      failsExactlyOnceWith "rendered in full by the app grammar and also carries whole manifests"
        mustFail.image-delivered-workload-passing-verbatim-objects;

    "a directly rendered chart cannot pretend its unconditional delivery policy is adoption" =
      failsExactlyOnceWith "already use server-side apply and server-side diff unconditionally"
        mustFail.chart-delivered-workload-claiming-adoption;

    "an externally rendered chart cannot claim to adopt an Application it does not render" =
      failsExactlyOnceWith "renders nothing to adopt"
        mustFail.externally-delivered-chart-claiming-adoption;

    "the factory is the single cross-root declaration-name authority" =
      failsExactlyOnceWith "declaration name `example-logs` appears in more than one root"
        mustFail.one-name-declared-in-two-groups;

    # THE MESSAGE THAT HAS TO DO THE MOST WORK. Somebody wrote that line believing it reasonable.
    "the cross-path refusal quotes the rule, names the field, and names what it pointed at" =
      lib.hasInfix "THE ALARM PATH MAY NEVER ACQUIRE A DEPENDENCY ON THE OBSERVABILITY PATH" crossPathMessage
      && lib.hasInfix "targets.example-metrics.url" crossPathMessage
      && lib.hasInfix "example-metrics" crossPathMessage
      && lib.hasInfix "silence reads as health" crossPathMessage;

    "and it catches the blunter route too, naming the environment variable it came in on" =
      lib.hasInfix "env.EXAMPLE_UPSTREAM" envRouteMessage;

    "the unknown-store refusal lists the stores that ARE declared" =
      lib.hasInfix "`example-metrics`" unknownStoreMessage
      && lib.hasInfix "`example-logs`" unknownStoreMessage
      && lib.hasInfix "`example-traces`" unknownStoreMessage;

    "the unbacked refusal says which directory, where, and what it does to the declared retention" =
      lib.any
        (message:
          lib.hasInfix "/var/tempo" message
          && lib.hasInfix "retention" message)
        unbackedMessages;

    "the wrong-pillar refusal says which pillar was named and what the failure looks like" =
      lib.hasInfix "metrics store" pillarMessage
      && lib.hasInfix "rejects every write" pillarMessage;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then
  pkgs.writeText "nixwatch-cluster-eval" ''
    the control renders, the floor holds, and every guard fires:
    ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames mustFail)}
    and these are not refusals at all -- they are unknown options:
    ${lib.concatMapStringsSep "\n" (n: "  impossible: ${n}") (lib.attrNames structurallyImpossible)}
  ''
else
  throw ''
    nixwatch: cluster-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
    ${lib.optionalString (wronglyRendered != [ ])
      "Declarations that rendered but had to be refused: ${lib.concatStringsSep ", " wronglyRendered}"}
    ${lib.optionalString (wronglyAccepted != [ ])
      "Declarations that evaluated but had to be unknown options: ${lib.concatStringsSep ", " wronglyAccepted}"}
  ''
