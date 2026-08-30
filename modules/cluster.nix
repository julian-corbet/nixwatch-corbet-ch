#
# nixwatch's cluster surface: six catalogue roots translated through nixk3s.
#
# The shared consumer factory owns the declaration/rendering spine: catalogue selection, image and
# manifest delivery, state projection, probes, addressing, and the cross-root identity guards.
# nixwatch keeps only its subject: the alarm/observability path split, pillar cost reports, typed
# dashboard/shipper relationships, role-shaped credentials, and the rule that the alarm path may
# never depend on the observability path.
{ mkConsumerModule }:
{ config, lib, ... }:

let
  cfg = config.nixwatch.cluster;
  platform = cfg.platform;
  catalogue = import ../lib/observability.nix { };
  durationLib = import ../lib/duration.nix { inherit lib; };

  enabledOf = lib.filterAttrs (_: workload: workload.enable);

  metrics = enabledOf cfg.metrics;
  logs = enabledOf cfg.logs;
  traces = enabledOf cfg.traces;
  shippers = enabledOf cfg.shippers;
  dashboards = enabledOf cfg.dashboards;
  probers = enabledOf cfg.probers;

  # Domain reports and interlocks retain the established pillar order. Rendering itself is driven
  # by the factory contexts below; this list contains no Kubernetes projection.
  allWorkloads =
    lib.mapAttrsToList (name: w: { inherit name w; kind = "metrics"; entry = catalogue.metrics.${w.store}; }) metrics
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "logs"; entry = catalogue.logs.${w.store}; }) logs
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "traces"; entry = catalogue.traces.${w.store}; }) traces
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "shippers"; entry = catalogue.shippers.${w.shipper}; }) shippers
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "dashboards"; entry = catalogue.dashboards.${w.dashboard}; }) dashboards
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "probers"; entry = catalogue.probers.${w.prober}; }) probers;

  workloadsOfKind = kind: lib.filter (x: x.kind == kind) allWorkloads;
  storeKinds = [ "metrics" "logs" "traces" ];
  stores = lib.filter (x: lib.elem x.kind storeKinds) allWorkloads;
  storeByName = lib.listToAttrs (map (x: lib.nameValuePair x.name x) stores);

  pathOf = x: x.entry.path;
  onObservability = lib.filter (x: pathOf x == "observability") allWorkloads;
  onAlarm = lib.filter (x: pathOf x == "alarm") allWorkloads;

  resolvedNamespaceOf = x:
    let selectedPlatform = x.platform or platform; in
    if pathOf x == "alarm" then selectedPlatform.alarmNamespace else selectedPlatform.namespace;

  deliveryOf = x: x.entry.delivery;
  hostOf = x: "${x.name}.${resolvedNamespaceOf x}.svc.${platform.clusterDomain}";
  urlOf = x: portName:
    "${x.entry.scheme}://${hostOf x}:${toString x.entry.ports.${portName}}";

  renderedStore = x:
    deliveryOf x == "image" && (x.entry.queryPort or null) != null;
  knownStore = name: storeByName ? ${name};

  resolvedReads = x:
    lib.filter (name: knownStore name && renderedStore storeByName.${name}) x.w.reads;

  sourcesOf = x:
    lib.listToAttrs (map
      (name: lib.nameValuePair name {
        pillar = storeByName.${name}.kind;
        url = urlOf storeByName.${name} storeByName.${name}.entry.queryPort;
      })
      (resolvedReads x));

  shipsTo = x:
    let name = x.w.ships; in
    if knownStore name
      && storeByName.${name}.kind == "logs"
      && renderedStore storeByName.${name}
    then storeByName.${name}
    else null;

  shipperTargetOf = x:
    let target = shipsTo x; in
    if target == null then null else {
      store = target.name;
      url = urlOf target target.entry.writePort;
    };

  # Every address by which an alarm workload could reach the observability path. The needles are
  # derived from the same names and namespaces as the published dashboard and shipper addresses.
  crossPathCoordinates =
    map (x: {
      what = "the in-cluster address of `${x.name}`";
      needle = hostOf x;
    }) onObservability
    ++ lib.optional (onObservability != [ ]) {
      what = "the observability path's own namespace (`${platform.namespace}`)";
      needle = ".${platform.namespace}.svc";
    }
    ++ lib.concatMap
      (x: map
        (form: { what = "`${x.name}`, by name"; inherit (form) needle; })
        [ { needle = "//${x.name}:"; } { needle = "//${x.name}/"; } ])
      onObservability;

  hitsIn = value:
    lib.unique (map (coordinate: coordinate.what)
      (lib.filter
        (coordinate: lib.hasInfix coordinate.needle (value + "/"))
        crossPathCoordinates));

  alarmStrings = x:
    lib.mapAttrsToList (name: target: {
      where = "targets.${name}.url";
      value = target.url;
    }) x.w.targets
    ++ lib.mapAttrsToList (name: value: {
      where = "env.${name}";
      inherit value;
    }) x.w.env
    ++ lib.imap0 (index: value: {
      where = "args[${toString index}]";
      inherit value;
    }) x.w.args;

  crossPathHits = x:
    lib.filter (field: hitsIn field.value != [ ]) (alarmStrings x);

  # Role-shaped credentials are intentionally outside the factory's variable-shaped public term.
  # The factory therefore treats `credentials` as structurally disabled and this adapter owns both
  # their projection and their domain guards.
  envRolesOf = x:
    lib.filterAttrs
      (role: _: (x.entry.credentials.${role} or null) != null)
      x.w.credentials;

  secretsOf = x:
    lib.mapAttrs
      (role: declaration: {
        inherit (declaration) secret;
        env.${x.entry.credentials.${role}.env} = declaration.key;
      })
      (envRolesOf x);

  groupOf = x: x.root or x.kind;

  retentionArgsOf = x:
    lib.optional
      (lib.elem (groupOf x) storeKinds && x.entry.retentionVia == "argument")
      (builtins.replaceStrings [ "{RETENTION}" ] [ x.w.retention ] x.entry.retentionArg);

  extendApp = x@{ app, entry, w, ... }:
    app // {
      secrets = secretsOf x;
      args = (entry.args or [ ]) ++ retentionArgsOf x ++ w.args;
    };

  factoryKind = x:
    if deliveryOf x == "image" then "app"
    else if x.w.manifests == [ ] then "reference"
    else "manifest";

  slotOf = x: x.w.slot or null;
  slotClaims = lib.filter (x: slotOf x != null) allWorkloads;

  growthOf = x:
    if x.kind == "metrics" then "${toString x.w.activeSeries} active series"
    else if x.kind == "logs" then "${toString x.w.ingestMiBPerDay} MiB per day"
    else "${toString x.w.sampledPercent}% of traces kept";

  listNames = names:
    lib.concatMapStringsSep ", " (name: "`${name}`") names;
  showStores =
    if stores == [ ] then "none at all" else listNames (lib.attrNames storeByName);

  # Chart deliveries have no container image for the factory's app-only image guard to inspect.
  chartDeliveryAssertions = lib.concatMap
    (x: lib.optionals (deliveryOf x == "chart") [
      {
        assertion = x.w.version == null;
        message =
          "nixwatch: `${x.name}` is delivered as its vendor's chart and names a `version`. The "
          + "chart's version lives inside the objects in `manifests`; a second pin here would drift.";
      }
      {
        assertion = x.w.image == null;
        message =
          "nixwatch: `${x.name}` is delivered as a chart and names an `image`. Nothing here renders "
          + "a container for it, so the reference would reach no object at all.";
      }
    ])
    allWorkloads;

  # `adopt` is a switch on the app grammar's Application. Chart deliveries never pass through
  # that renderer: a manifest Application already carries SSA/SSD unconditionally, while a
  # reference renders no Application at all. Refuse the otherwise-silent spelling on both shapes.
  adoptionAssertions = lib.concatMap
    (x: lib.optionals (deliveryOf x != "image") [{
      assertion = !x.w.adopt;
      message =
        "nixwatch: `${x.name}` is delivered as its vendor's chart and sets `adopt`. Chart objects "
        + (if x.w.manifests == [ ]
          then "are delivered by another Application, so this declaration renders nothing to adopt."
          else "already use server-side apply and server-side diff unconditionally; `adopt` would change nothing.");
    }])
    allWorkloads;

  # Keep nixwatch's richer state sentence beside the factory's general state guards: for a telemetry
  # store the important consequence is that declared retention becomes fiction.
  storageAssertions = lib.concatMap
    (x: [
      {
        assertion = lib.attrNames x.w.state == lib.attrNames x.entry.state;
        message =
          "nixwatch: `${x.name}` must back every directory this software cannot lose, and backs "
          + (if x.w.state == { } then "none" else listNames (lib.attrNames x.w.state))
          + ". It writes: "
          + (if x.entry.state == { } then "nothing" else
            lib.concatStringsSep ", "
              (lib.mapAttrsToList
                (name: state: "`${name}` at ${state.mountPath}")
                x.entry.state))
          + ". An unbacked directory is not an error at runtime: the workload starts, uses the "
          + "container filesystem, loses it at restart, and for a store makes its retention a fiction.";
      }
      {
        assertion = lib.all
          (backing: (backing.claim == null) != (backing.hostPath == null))
          (lib.attrValues x.w.state);
        message =
          "nixwatch: `${x.name}` backs a directory with neither or both of `claim` and `hostPath`. "
          + "Storage needs exactly one backing: an existing claim by name, or a path on the node.";
      }
    ])
    allWorkloads;

  credentialAssertions = lib.concatMap
    (x:
      let
        known = lib.attrNames x.entry.credentials;
        unknown = lib.filter
          (role: !(x.entry.credentials ? ${role}))
          (lib.attrNames x.w.credentials);
        missing = lib.attrNames
          (lib.filterAttrs
            (role: credential: credential.required && !(x.w.credentials ? ${role}))
            x.entry.credentials);
      in
      [
        {
          assertion = unknown == [ ];
          message =
            "nixwatch: `${x.name}` names credential role(s) ${listNames unknown} that this software "
            + "does not read. It reads "
            + (if known == [ ] then "none at all" else listNames known) + ".";
        }
        {
          assertion = missing == [ ];
          message =
            "nixwatch: `${x.name}` is missing required credential role(s) ${listNames missing}. "
            + "Name the existing Secret and the key inside it, never the value.";
        }
      ])
    allWorkloads;

  costAssertions = lib.concatMap
    (x: [
      {
        assertion = growthOf x != "";
        message =
          "nixwatch: store `${x.name}` does not state what drives its size: active series, MiB per "
          + "day, or sampled percent. Multiplied by retention, that is what the pillar costs.";
      }
      {
        assertion = durationLib.toSeconds x.w.retention != null
          && builtins.match "[0-9]+" x.w.retention == null;
        message =
          "nixwatch: store `${x.name}` declares `retention = \"${x.w.retention}\"` beside "
          + "${growthOf x}, which is not a duration with a unit. Write `30d`, `12h`, `90m` or `3600s`.";
      }
    ])
    stores;

  dashboardAssertions = lib.concatMap
    (x:
      let
        unknown = lib.filter (name: !(knownStore name)) x.w.reads;
        unrendered = lib.filter
          (name: knownStore name && !(renderedStore storeByName.${name}))
          x.w.reads;
      in
      [
        {
          assertion = x.w.reads != [ ];
          message =
            "nixwatch: dashboard `${x.name}` reads no store at all. Name at least one of: "
            + showStores + ".";
        }
        {
          assertion = unknown == [ ];
          message =
            "nixwatch: dashboard `${x.name}` reads ${listNames unknown}, which is not a declared, "
            + "enabled store. Declared stores: ${showStores}.";
        }
        {
          assertion = unrendered == [ ];
          message =
            "nixwatch: dashboard `${x.name}` reads ${listNames unrendered}, which is delivered as a "
            + "chart. The chart owns its Service names, so this module cannot derive its address.";
        }
      ])
    (workloadsOfKind "dashboards");

  shipperAssertions = lib.concatMap
    (x:
      let
        target = if knownStore x.w.ships then storeByName.${x.w.ships} else null;
      in
      [
        {
          assertion = target != null;
          message =
            "nixwatch: shipper `${x.name}` ships to `${x.w.ships}`, which is not a declared, enabled "
            + "store. Declared stores: ${showStores}.";
        }
        {
          assertion = target == null || target.kind == "logs";
          message =
            "nixwatch: shipper `${x.name}` ships to `${x.w.ships}`, which is a "
            + (if target == null then "store that is not declared" else "${target.kind} store")
            + ". A log shipper speaks a log store's push API; another pillar rejects every write.";
        }
        {
          assertion = target == null || target.kind != "logs" || renderedStore target;
          message =
            "nixwatch: shipper `${x.name}` ships to `${x.w.ships}`, which is delivered as a chart. "
            + "The chart owns its write Service name, so this module cannot derive it.";
        }
      ])
    (workloadsOfKind "shippers");

  proberAssertions = lib.concatMap
    (x:
      let hits = crossPathHits x; in
      [
        {
          assertion = x.w.targets != { };
          message =
            "nixwatch: prober `${x.name}` declares no targets. A prober watching nothing is a green "
            + "status page that means nothing.";
        }
        {
          assertion = hits == [ ];
          message =
            "nixwatch: prober `${x.name}` points at the observability path -- "
            + lib.concatMapStringsSep "; "
              (hit: "`${hit.where}` names " + lib.concatStringsSep " and " (hitsIn hit.value))
              hits
            + ". THE ALARM PATH MAY NEVER ACQUIRE A DEPENDENCY ON THE OBSERVABILITY PATH. A probe "
            + "inside the stack it watches disappears with that stack, and silence reads as health.";
        }
      ])
    (workloadsOfKind "probers");

  pathAssertions = lib.optional (onAlarm != [ ] && onObservability != [ ]) {
    assertion = platform.namespace != platform.alarmNamespace;
    message =
      "nixwatch: `nixwatch.cluster.platform.namespace` and `...alarmNamespace` are the same "
      + "namespace. The alarm and observability paths must not share fate.";
  };

  domainAssertions =
    chartDeliveryAssertions
    ++ adoptionAssertions
    ++ storageAssertions
    ++ credentialAssertions
    ++ costAssertions
    ++ dashboardAssertions
    ++ shipperAssertions
    ++ proberAssertions
    ++ pathAssertions;

  domainWarnings = lib.concatMap
    (x: [
      {
        when = x.w.manifests == [ ];
        message =
          "nixwatch: `${x.name}` is delivered as a chart and delivers nothing here. That is correct "
          + "when another Application deploys it; the declaration still participates in reports.";
      }
      {
        when = (x.w.exposure or "internal") != "internal";
        message =
          "nixwatch: workload `${x.name}` declares exposure `${x.w.exposure or "internal"}`, but "
          + "this chart delivery renders below the app grammar, so the class reaches no object.";
      }
    ])
    (lib.filter (x: deliveryOf x == "chart") allWorkloads);

  # ── Exact legacy declaration shapes ─────────────────────────────────────────────────────────

  backingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of an existing PersistentVolumeClaim backing this directory.";
      };
      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path on the node backing this directory instead of a claim.";
      };
      hostPathType = lib.mkOption {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = "Directory";
        description = "Whether a missing node path is an error or is created empty.";
      };
    };
  };

  credentialType = lib.types.submodule {
    options = {
      secret = lib.mkOption {
        type = lib.types.str;
        description = "Name of an existing Secret holding this credential.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Key inside that Secret carrying the credential.";
      };
    };
  };

  sharedOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to render this workload.";
    };
    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixwatch.cluster.platform.project";
      description = "Delivery project this workload's Application belongs to.";
    };
    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this workload anchors its path's namespace.";
    };
    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Image tag for an image delivery; absent on chart deliveries.";
    };
    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Whole image reference replacing the catalogue repository plus version.";
    };
    state = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = "Backing for every directory this catalogue entry cannot lose.";
    };
    credentials = lib.mkOption {
      type = lib.types.attrsOf credentialType;
      default = { };
      description = "Credential Secret references keyed by catalogue role.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra plain environment merged over catalogue values.";
    };
    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to the catalogue entrypoint arguments.";
    };
    manifests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Whole YAML objects delivered for a chart-backed declaration.";
    };
  };

  frontedOptions = {
    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = "Who can reach this workload, as a class rather than an address.";
    };
    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "Position this workload holds in the consumer's ordered identity space.";
    };
  };

  storeOptions = sharedOptions // {
    retention = lib.mkOption {
      type = lib.types.str;
      example = "30d";
      description = "How long this store keeps data, with an explicit unit.";
    };
  };

  metricsOptions = storeOptions // {
    activeSeries = lib.mkOption {
      type = lib.types.ints.positive;
      example = 500000;
      description = "Expected number of simultaneously active metric series.";
    };
  };

  logsOptions = storeOptions // {
    ingestMiBPerDay = lib.mkOption {
      type = lib.types.ints.positive;
      example = 2048;
      description = "Expected daily log ingest in mebibytes.";
    };
  };

  tracesOptions = storeOptions // {
    sampledPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      example = 10;
      description = "Whole percentage of traces this store is sized to retain.";
    };
  };

  shippersOptions = sharedOptions // {
    ships = lib.mkOption {
      type = lib.types.str;
      description = "Name of the declared log store this shipper writes into.";
    };
  };

  dashboardsOptions = sharedOptions // frontedOptions // {
    reads = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Names of the declared stores this dashboard reads.";
    };
  };

  probersOptions = sharedOptions // frontedOptions // {
    targets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.url = lib.mkOption {
          type = lib.types.str;
          example = "https://example.com/healthz";
          description = "Whole URL this black-box target dials.";
        };
      });
      default = { };
      description = "Black-box targets keyed by a name of the consumer's choosing.";
    };
  };

  namespaceOption = lib.mkOption {
    type = lib.types.str;
    description = "Namespace for every observability-path workload.";
  };

  alarmNamespaceOption = lib.mkOption {
    type = lib.types.str;
    description = "Separate namespace for every alarm-path workload.";
  };

  clusterDomainOption = lib.mkOption {
    type = lib.types.str;
    default = "cluster.local";
    description = "Internal DNS domain used to derive store addresses.";
  };

  observabilityPathOption = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onObservability;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = "Workloads on the explanatory observability path.";
  };

  alarmPathOption = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onAlarm;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = "Workloads on the in-cluster alarm path.";
  };

  retentionOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        pillar = lib.mkOption { type = lib.types.str; };
        retention = lib.mkOption { type = lib.types.str; };
        retentionSeconds = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; };
        growth = lib.mkOption { type = lib.types.str; };
        enforced = lib.mkOption { type = lib.types.bool; };
      };
    });
    readOnly = true;
    default = lib.listToAttrs (map
      (x: lib.nameValuePair x.name {
        pillar = x.kind;
        inherit (x.w) retention;
        retentionSeconds = durationLib.toSeconds x.w.retention;
        growth = growthOf x;
        enforced = x.entry.retentionVia == "argument";
      })
      stores);
    defaultText = lib.literalExpression "computed from the declared stores";
    description = "Per-pillar retention, growth driver, and enforcement report.";
  };

  dashboardSourcesOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.str));
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name (sourcesOf x)) (workloadsOfKind "dashboards"));
    defaultText = lib.literalExpression "dashboard -> store -> { pillar, url }";
    description = "Derived dashboard data-source coordinates.";
  };

  shipperTargetsOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map
        (x: lib.nameValuePair x.name (shipperTargetOf x))
        (lib.filter (x: shipperTargetOf x != null) (workloadsOfKind "shippers")));
    defaultText = lib.literalExpression "shipper -> { store, url }";
    description = "Derived log-shipper destinations.";
  };

  proberTargetsOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map
        (x: lib.nameValuePair x.name (lib.mapAttrs (_: target: target.url) x.w.targets))
        (workloadsOfKind "probers"));
    defaultText = lib.literalExpression "prober -> target -> url";
    description = "Published black-box target URLs.";
  };

  unaddressedOption = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) (lib.filter (x: !(x.w ? slot)) allWorkloads);
    defaultText = lib.literalExpression "every workload with no slot option at all";
    description = "Workloads structurally outside the external identity space.";
  };

  slotsOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name (slotOf x)) slotClaims);
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = "Workload to claimed identity-space position.";
  };

  commonEnabledOptions = [
    "project"
    "createNamespace"
    "version"
    "image"
    "state"
    "env"
    "args"
    "manifests"
    "adopt"
  ];

  frontedEnabledOptions = commonEnabledOptions ++ [ "exposure" "slot" ];

  mkRoot = { catalogueSet, selectorName, enabled, optionsSet, description }: {
    catalogue = catalogueSet;
    selector = selectorName;
    enabledOptions = enabled;
    extraOptions = optionsSet;
    kind = factoryKind;
    namespaceOf = resolvedNamespaceOf;
    extend = extendApp;
    inherit description;
  };

  factoryModule = mkConsumerModule {
    namespace = "nixwatch";
    optionPath = [ "nixwatch" "cluster" ];
    platformOption = "platform";

    roots = {
      metrics = mkRoot {
        catalogueSet = catalogue.metrics;
        selectorName = "store";
        enabled = commonEnabledOptions;
        optionsSet = metricsOptions;
        description = "Metrics stores, keyed by declaration name.";
      };
      logs = mkRoot {
        catalogueSet = catalogue.logs;
        selectorName = "store";
        enabled = commonEnabledOptions;
        optionsSet = logsOptions;
        description = "Log stores, keyed by declaration name.";
      };
      traces = mkRoot {
        catalogueSet = catalogue.traces;
        selectorName = "store";
        enabled = commonEnabledOptions;
        optionsSet = tracesOptions;
        description = "Trace stores, keyed by declaration name.";
      };
      shippers = mkRoot {
        catalogueSet = catalogue.shippers;
        selectorName = "shipper";
        enabled = commonEnabledOptions;
        optionsSet = shippersOptions;
        description = "Log shippers, keyed by declaration name.";
      };
      dashboards = mkRoot {
        catalogueSet = catalogue.dashboards;
        selectorName = "dashboard";
        enabled = frontedEnabledOptions;
        optionsSet = dashboardsOptions;
        description = "Dashboards, keyed by declaration name.";
      };
      probers = mkRoot {
        catalogueSet = catalogue.probers;
        selectorName = "prober";
        enabled = frontedEnabledOptions;
        optionsSet = probersOptions;
        description = "Active black-box probers, keyed by declaration name.";
      };
    };

    extraPlatformOptions = {
      namespace = namespaceOption;
      alarmNamespace = alarmNamespaceOption;
      clusterDomain = clusterDomainOption;
    };

    extraNamespaceOptions = {
      observabilityPath = observabilityPathOption;
      alarmPath = alarmPathOption;
      retention = retentionOption;
      dashboardSources = dashboardSourcesOption;
      shipperTargets = shipperTargetsOption;
      proberTargets = proberTargetsOption;
      unaddressed = unaddressedOption;
      slots = slotsOption;
    };

    extraAssertions = _contexts: domainAssertions;
    extraWarnings = _contexts: domainWarnings;

    extraConfig = _contexts: {
      # Preserve the established default while the factory remains the sole declaration authority
      # for the common platform project option.
      nixwatch.cluster.platform.project = lib.mkOptionDefault "default";
    };
  };
in
{
  imports = [ factoryModule ];
}
