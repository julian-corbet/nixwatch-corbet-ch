#
# nixwatch's OBSERVABILITY half, declared: the stores that hold the telemetry, the shipper that
# carries logs into one of them, the dashboard a person reads them through -- and, on the other
# path entirely, the in-cluster prober that decides something is broken.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE WHOLE DESIGN ────────────────────
#
# There is a sibling repository whose entire subject is the app grammar: an app declares WHAT IT
# NEEDS (an image, ports, an exposure class, which existing claims or node paths hold its state,
# which existing Secrets it consumes) and that grammar renders the Application, the Namespace, the
# Deployment and the Service. Everything this module can express in those terms is expressed in
# them: it DEFINES INTO `nixk3s.apps` and renders no Kubernetes object of its own.
#
# IMPORT THE GRAMMAR ALONGSIDE THIS MODULE. `nixk3s.apps` is declared there, not here, and a render
# that composes this module without it fails with "the option `nixk3s.apps' does not exist". That
# is deliberately not softened: a version of this module that quietly rendered its own Deployments
# when the grammar was absent would be a second implementation of the thing the grammar is.
#
# ── THE ALARM/OBSERVABILITY AXIS IS THE STRUCTURE OF THIS FILE ─────────────────────────────────
#
# One question decides everything here: DOES THIS WORKLOAD DECIDE THAT SOMETHING IS BROKEN, OR
# DOES IT EXPLAIN AFTERWARDS WHAT WAS HAPPENING?
#
#   OBSERVABILITY  the metrics store, the log store, the trace store, the shipper, the dashboard.
#                  Built to EXPLAIN. All of it dies with the cluster and has nothing to say when
#                  the cluster is what died.
#   ALARM          the prober: active black-box checks with a status page in front of them. Built
#                  to DECIDE. This is the alarm path, living inside a cluster.
#
# THE RULE THE WHOLE REPOSITORY RESTS ON IS ABOUT DIRECTION: **the alarm path may never acquire a
# dependency on the observability path.** A probe that queries a time-series database to decide
# whether something is up has quietly moved itself inside the thing it was supposed to be outside
# of. That rule is enforced here at four levels rather than documented at one:
#
#   1. A WORKLOAD'S PATH IS NOT DECLARABLE. It is read from the catalogue, because whether a piece
#      of software decides or explains is a property of the software.
#   2. THERE IS NO `namespace` OPTION ANYWHERE. A workload's namespace is its PATH's namespace, and
#      the two namespaces are two defaultless platform options that must differ. A prober cannot be
#      moved next to the stores by editing one line -- there is no line.
#   3. AN ALARM-PATH WORKLOAD HAS NO OPTION THAT CAN NAME A STORE. `reads` exists on dashboards and
#      `ships` on shippers; writing either on a prober is "the option does not exist", not a review
#      comment.
#   4. EVERY FREE-TEXT STRING AN ALARM-PATH WORKLOAD CARRIES IS SCANNED -- its probe targets, its
#      environment, its arguments -- for the observability path's own DERIVED addresses, its
#      in-cluster DNS suffix, and its workloads by name in a URL authority. A hit fails eval,
#      quoting the rule. It is not a warning: a warning about this is a warning about the one thing
#      this repository exists to prevent.
#
# THE REVERSE DIRECTION IS NOT FORBIDDEN and is simply unrepresentable: a dashboard reading a
# prober would be the safe direction, and there is nothing here to express it, because a prober is
# not a store.
#
# AND THE HONEST LIMIT, WHICH NO OPTION HERE FIXES: the prober cannot outlive the cluster it runs
# in. When the node dies it dies with it, and raises no alarm about anything, including itself.
# That is exactly why this repository's OTHER half runs on each host's own systemd timers, outside
# every cluster (see modules/default.nix). Neither half is redundant: one survives, one explains.
#
# ── THE THREE PILLARS ARE THREE OPTION GROUPS ─────────────────────────────────────────────────
#
# Metrics, logs and traces are not interchangeable and are not declarable as if they were. Each is
# its own group, each REQUIRES a retention, and each requires a DIFFERENT growth term -- the one
# question that actually prices it:
#
#   metrics  `activeSeries`      cardinality. Sampling twice as often costs a compressed column;
#                                one unbounded label multiplies the series count and its index.
#   logs     `ingestMiBPerDay`   traffic. Nothing about the number of things watched predicts it;
#                                one component switched to debug doubles it.
#   traces   `sampledPercent`    how much is kept at all. The only pillar whose usual answer to
#                                cost is to keep less of it rather than to keep it for less long.
#
# Asking a metrics store how many bytes a day it takes is an unknown option. So is asking a log
# store what fraction it samples. That is the point of three groups: there is nothing to edit that
# would turn one pillar into another, and a reader can tell from the declaration what each one
# costs to keep. `nixwatch.cluster.retention` publishes all of it in one place.
#
# A SHIPPER IS NOT A STORE, and gets its own group for the same reason: it has no retention, no
# growth term and nothing to back, because it keeps no data at all -- only how far it has read.
#
# A DASHBOARD IS A CONSUMER OF PILLARS, never one. It NAMES the stores it reads, as a typed
# relationship against declared stores rather than a URL somebody typed; the addresses are DERIVED
# from those stores and published at `nixwatch.cluster.dashboardSources`. There is no `url` option
# on a dashboard anywhere in this module, and a dashboard naming a store nobody declared fails
# eval.
#
# ── WHAT IS PUBLISHED RATHER THAN RENDERED, AND WHY ───────────────────────────────────────────
#
# A data-source provisioning file, a shipper's chart values, and a prober's endpoint list are all
# configuration FILES belonging to their own software. This module renders none of them, and does
# not pretend to: it derives the addresses and publishes them, so the file the consumer renders is
# written against a checked relationship instead of a typed-in address. The same reasoning the
# sibling CI repository uses for a chart's credential -- publish, never pretend to wire.
#
# ONE NAMESPACE. Everything declared here lives under `nixwatch.cluster`, beside the host half's
# `nixwatch.checks`, which it shares no evaluation with and takes no dependency on.
{ config, lib, ... }:
let
  cfg = config.nixwatch.cluster;
  platform = cfg.platform;

  catalogue = import ../lib/observability.nix { };

  # The duration parser the ALARM half already uses for `interval`/`deadline`. A pure function
  # shared by both halves is not a dependency of one on the other -- nothing about reading a
  # retention string reaches a store, a query or a cluster.
  durationLib = import ../lib/duration.nix { inherit lib; };

  enabledOf = attrs: lib.filterAttrs (_: w: w.enable) attrs;

  metrics = enabledOf cfg.metrics;
  logs = enabledOf cfg.logs;
  traces = enabledOf cfg.traces;
  shippers = enabledOf cfg.shippers;
  dashboards = enabledOf cfg.dashboards;
  probers = enabledOf cfg.probers;

  # Every declared workload, tagged with its group and its catalogue entry, in one list. Most
  # guards here are about the declaration AS A WHOLE -- two workloads on one slot, two workloads
  # creating one namespace, one name in two groups -- so they are written against this rather than
  # against six separate tables.
  allWorkloads =
    lib.mapAttrsToList (name: w: { inherit name w; kind = "metrics"; entry = catalogue.metrics.${w.store}; }) metrics
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "logs"; entry = catalogue.logs.${w.store}; }) logs
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "traces"; entry = catalogue.traces.${w.store}; }) traces
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "shippers"; entry = catalogue.shippers.${w.shipper}; }) shippers
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "dashboards"; entry = catalogue.dashboards.${w.dashboard}; }) dashboards
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "probers"; entry = catalogue.probers.${w.prober}; }) probers;

  workloadsOfKind = k: lib.filter (x: x.kind == k) allWorkloads;

  storeKinds = [ "metrics" "logs" "traces" ];
  stores = lib.filter (x: lib.elem x.kind storeKinds) allWorkloads;
  storeByName = lib.listToAttrs (map (x: lib.nameValuePair x.name x) stores);

  ## ---------------------------------------------------------------------
  ## The two paths
  ## ---------------------------------------------------------------------

  pathOf = x: x.entry.path;
  onObservability = lib.filter (x: pathOf x == "observability") allWorkloads;
  onAlarm = lib.filter (x: pathOf x == "alarm") allWorkloads;

  # THE ONE PLACE A NAMESPACE COMES FROM. There is no per-workload option and there will not be
  # one: the path a workload is on decides where it lands, and the path is the catalogue's.
  namespaceOf = x:
    if pathOf x == "alarm" then platform.alarmNamespace else platform.namespace;

  ## ---------------------------------------------------------------------
  ## Delivery
  ## ---------------------------------------------------------------------

  deliveryOf = x: x.entry.delivery;

  byGrammar = lib.filter (x: deliveryOf x == "image") allWorkloads;

  # A chart-delivered workload with nothing to deliver renders no Application at all. That is the
  # correct shape when its chart is deployed by something else in the same cluster -- the
  # declaration still buys the accounting and every interlock -- and it warns, so the absence is
  # never silent.
  directly = lib.filter (x: deliveryOf x == "chart" && x.w.manifests != [ ]) allWorkloads;

  ## ---------------------------------------------------------------------
  ## Addresses, all of them DERIVED
  ##
  ## Nothing in this module accepts an address, and nothing accepts a URL. Every address below is
  ## built from a workload's own name, its path's namespace, the cluster domain, and the port its
  ## catalogue entry names -- which is exactly what makes a dashboard unable to point at a store
  ## that is not there, and what gives the cross-path guard something concrete to scan for.
  ## ---------------------------------------------------------------------

  hostOf = x: "${x.name}.${namespaceOf x}.svc.${platform.clusterDomain}";

  urlOf = x: portName:
    "${x.entry.scheme}://${hostOf x}:${toString x.entry.ports.${portName}}";

  # A store whose Service THIS module renders. A chart names its own Services, from its own release
  # name and its own template, so an address derived for one would be an address the chart never
  # creates -- refused below rather than published.
  renderedStore = x: deliveryOf x == "image" && (x.entry.queryPort or null) != null;

  knownStore = n: storeByName ? ${n};

  ## ---------------------------------------------------------------------
  ## The dashboard's typed relationship to the pillars
  ## ---------------------------------------------------------------------

  # Total on purpose: names that resolve to nothing are filtered out here and REPORTED by the
  # assertions, because a helper that threw on a bad name would take the evaluation down before the
  # refusal could say which name it was.
  resolvedReads = x: lib.filter (n: knownStore n && renderedStore storeByName.${n}) x.w.reads;

  sourcesOf = x:
    lib.listToAttrs (map
      (n: lib.nameValuePair n {
        pillar = storeByName.${n}.kind;
        url = urlOf storeByName.${n} storeByName.${n}.entry.queryPort;
      })
      (resolvedReads x));

  # A shipper writes to exactly one store, and it must be a LOG store: the push API a log shipper
  # speaks is not the one a metrics store answers, and a shipper pointed at the wrong pillar fails
  # by rejecting every write forever while both workloads report themselves healthy.
  shipsTo = x:
    let n = x.w.ships; in
    if knownStore n && storeByName.${n}.kind == "logs" && renderedStore storeByName.${n}
    then storeByName.${n} else null;

  shipperTargetOf = x:
    let target = shipsTo x; in
    if target == null then null
    else { store = target.name; url = urlOf target target.entry.writePort; };

  ## ---------------------------------------------------------------------
  ## THE ONE-DIRECTIONAL GUARD
  ##
  ## Every coordinate by which an alarm-path workload could reach the observability path, built
  ## from the same derivation the dashboards use, so the guard cannot drift away from the addresses
  ## it is guarding.
  ##
  ## Each needle is deliberately shaped to be UNAMBIGUOUS rather than broad: the full in-cluster
  ## host, the in-cluster DNS suffix of the observability namespace, and a workload's bare name
  ## only where a URL's authority begins. A bare namespace word would refuse a perfectly legitimate
  ## external target that happens to contain it, and a guard that cries wolf is a guard people
  ## switch off.
  ## ---------------------------------------------------------------------

  crossPathCoordinates =
    map (x: { what = "the in-cluster address of `${x.name}`"; needle = hostOf x; }) onObservability
    # The namespace needle only exists when this render HAS an observability path. With none, there
    # is no derived coordinate to compare against, and building one anyway would force a consumer
    # who declares nothing but a prober to name a namespace they do not have.
    ++ lib.optional (onObservability != [ ]) {
      what = "the observability path's own namespace (`${platform.namespace}`)";
      needle = ".${platform.namespace}.svc";
    }
    ++ lib.concatMap
      (x: map (form: { what = "`${x.name}`, by name"; inherit (form) needle; })
        [{ needle = "//${x.name}:"; } { needle = "//${x.name}/"; }])
      onObservability;

  # Scanned with a trailing slash appended, so a URL ending at the authority (`http://store`) is
  # caught by the same needle as one that continues (`http://store/ready`).
  hitsIn = s:
    lib.unique (map (c: c.what)
      (lib.filter (c: lib.hasInfix c.needle (s + "/")) crossPathCoordinates));

  alarmStrings = x:
    lib.mapAttrsToList (k: t: { where = "targets.${k}.url"; value = t.url; }) x.w.targets
    ++ lib.mapAttrsToList (k: v: { where = "env.${k}"; value = v; }) x.w.env
    ++ lib.imap0 (i: v: { where = "args[${toString i}]"; value = v; }) x.w.args;

  crossPathHits = x: lib.filter (s: hitsIn s.value != [ ]) (alarmStrings x);

  ## ---------------------------------------------------------------------
  ## Translation into the app grammar
  ## ---------------------------------------------------------------------

  imageOf = x:
    if x.w.image != null then x.w.image
    else "${toString x.entry.image}:${toString x.w.version}";

  portsOf = x: lib.mapAttrs (_: number: { inherit number; }) x.entry.ports;

  # Filtered to the keys the catalogue actually holds, so a key that is not the catalogue's mounts
  # nothing instead of throwing out of a helper -- the assertion below is what reports it, and a
  # raw "attribute missing" from in here would arrive first and say less.
  knownState = x: lib.filterAttrs (k: _: x.entry.state ? ${k}) x.w.state;

  stateOf = x:
    lib.mapAttrs
      (key: backing: {
        inherit (x.entry.state.${key}) mountPath readOnly;
        inherit (backing) claim hostPath hostPathType;
      })
      (knownState x);

  envRolesOf = x:
    lib.filterAttrs (role: _: (x.entry.credentials.${role} or null) != null) x.w.credentials;

  secretsOf = x:
    lib.mapAttrs
      (role: d: {
        inherit (d) secret;
        env.${x.entry.credentials.${role}.env} = d.key;
      })
      (envRolesOf x);

  # The declared retention, reaching the running store, for the one delivery where that is possible
  # at all. Passed VERBATIM: see the refusal of a unitless retention below.
  retentionArgsOf = x:
    lib.optional
      (lib.elem x.kind storeKinds && x.entry.retentionVia == "argument")
      (builtins.replaceStrings [ "{RETENTION}" ] [ x.w.retention ] x.entry.retentionArg);

  probesOf = x:
    lib.optionalAttrs (x.entry.readiness != null) {
      readiness = { port = x.entry.primaryPort; } // x.entry.readiness;
    };

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op. A store, a shipper -- anything with no slot option at all --
  # is stamped with the origin and no number.
  addressingOf = x:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      slot = x.w.slot or null;
    };

  mkGrammarApp = x:
    {
      namespace = namespaceOf x;
      inherit (x.w) createNamespace project;
      exposure = x.w.exposure or "internal";
      image = imageOf x;
      ports = portsOf x;
      state = stateOf x;
      secrets = secretsOf x;
      env = x.entry.env // x.w.env;
      args = x.entry.args ++ retentionArgsOf x ++ x.w.args;
      probes = probesOf x;
    }
    // addressingOf x;

  mkDirectApp = x: {
    namespace = namespaceOf x;
    inherit (x.w) project;
    # Never here: a Namespace created one level below the grammar carries none of the grammar's
    # protection against being read as no-longer-desired. Asserted below.
    createNamespace = false;
    yamls = x.w.manifests;
    # An operator's custom resource definitions are large enough that a client-side apply overruns
    # the annotation Kubernetes keeps the last-applied state in, and the apply simply fails.
    # Server-side diff comes with it, because comparing a client-side reconstruction of a large
    # resource against what the API server holds produces permanent phantom drift.
    syncPolicy.syncOptions.serverSideApply = true;
    compareOptions.serverSideDiff = true;
  };

  ## ---------------------------------------------------------------------
  ## Derived facts the guards are written against
  ## ---------------------------------------------------------------------

  slotOf = x: x.w.slot or null;
  showSlot = x: if slotOf x == null then "(none)" else toString (slotOf x);

  slotClaims = lib.filter (x: slotOf x != null) allWorkloads;
  claimantsOf = slot: map (x: x.name) (lib.filter (x: slotOf x == slot) slotClaims);
  duplicatedSlots =
    lib.filter (slot: lib.length (claimantsOf slot) > 1)
      (lib.unique (map slotOf slotClaims));

  namedBy = n: map (x: "${x.kind}.${x.name}") (lib.filter (x: x.name == n) allWorkloads);
  duplicatedNames =
    lib.filter (n: lib.length (namedBy n) > 1) (lib.unique (map (x: x.name) allWorkloads));

  creatorsOf = ns:
    map (x: x.name) (lib.filter (x: x.w.createNamespace && namespaceOf x == ns) allWorkloads);
  createdNamespaces =
    lib.unique (map namespaceOf (lib.filter (x: x.w.createNamespace) allWorkloads));

  growthOf = x:
    if x.kind == "metrics" then "${toString x.w.activeSeries} active series"
    else if x.kind == "logs" then "${toString x.w.ingestMiBPerDay} MiB per day"
    else "${toString x.w.sampledPercent}% of traces kept";

  ## ---------------------------------------------------------------------
  ## Assertions
  ##
  ## Every message is a TOTAL function of the declaration: an assertion's message is forced whether
  ## or not the assertion holds, so a message that only works in the failing case takes the whole
  ## evaluation down instead of reporting anything.
  ## ---------------------------------------------------------------------

  listNames = names: lib.concatMapStringsSep ", " (n: "`${n}`") names;

  showStores = if stores == [ ] then "none at all" else listNames (lib.attrNames storeByName);

  deliveryAssertions = lib.concatMap
    (x:
      let inherit (x) name w; in
      [
        {
          assertion = deliveryOf x != "image" || w.version != null || w.image != null;
          message =
            "nixwatch: `${name}` is delivered as a container image and names neither a `version` nor a "
            + "whole `image` reference. The catalogue holds the image REPOSITORY and never a tag, because "
            + "which version this workload runs is a value: name one, or set `image` to a whole reference "
            + "to pin it by digest.";
        }
        {
          assertion = deliveryOf x != "chart" || w.version == null;
          message =
            "nixwatch: `${name}` is delivered as its vendor's chart and names a `version`. The chart's own "
            + "version lives inside the objects you deliver in `manifests`, pinned by whoever rendered "
            + "them -- a second copy out here would be a pin nothing keeps honest, and the two would drift "
            + "silently apart.";
        }
        {
          assertion = deliveryOf x != "chart" || w.image == null;
          message =
            "nixwatch: `${name}` is delivered as a chart and names an `image`. Nothing here renders a "
            + "container for it, so the reference would reach no object at all. The images a chart runs "
            + "are named inside the chart's own values.";
        }
        {
          assertion = deliveryOf x != "image" || w.manifests == [ ];
          message =
            "nixwatch: `${name}` is rendered in full by the app grammar, so `manifests` here would be a "
            + "second, untyped copy of objects that are already being rendered. For one extra object "
            + "beside it, use the grammar's own escape hatch (`nixk3s.apps.${name}.raw`), which is "
            + "scanned, warned about and counted.";
        }
      ])
    allWorkloads;

  storageAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixwatch: `${name}` must back every directory this software cannot lose, and backs "
            + (if w.state == { } then "none" else listNames (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else
              lib.concatStringsSep ", "
                (lib.mapAttrsToList (k: s: "`${k}` at ${s.mountPath}") entry.state))
            + ". An unbacked directory is not an error at runtime -- the workload starts, uses the "
            + "container's own filesystem, and loses it at the next restart. For a store that also makes "
            + "its declared retention a fiction: it then keeps data until the next restart rather than "
            + "for the period the declaration says, and reports itself healthy the whole time.";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues w.state);
          message =
            "nixwatch: `${name}` backs a directory with neither or both of `claim` and `hostPath`. "
            + "Storage needs exactly one backing: an existing claim by name, or a path on the node.";
        }
      ])
    allWorkloads;

  credentialAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        known = lib.attrNames entry.credentials;
        unknown = lib.filter (r: !(entry.credentials ? ${r})) (lib.attrNames w.credentials);
        missing = lib.attrNames
          (lib.filterAttrs (r: c: c.required && !(w.credentials ? ${r})) entry.credentials);
      in
      [
        {
          assertion = unknown == [ ];
          message =
            "nixwatch: `${name}` names credential role(s) " + listNames unknown + " that this software "
            + "does not read. It reads "
            + (if known == [ ] then "none at all" else listNames known)
            + ". A role nothing reads renders a reference into a variable no process looks at, which is "
            + "worse than being refused because it looks provisioned.";
        }
        {
          assertion = missing == [ ];
          message =
            "nixwatch: `${name}` is missing required credential role(s) " + listNames missing + ". Name "
            + "the existing Secret and the key inside it -- never the value; everything this module "
            + "renders is committed to git. For a dashboard's admin credential the alternative to setting "
            + "one is not 'no password', it is the software's own well-known default.";
        }
      ])
    allWorkloads;

  costAssertions = lib.concatMap
    (x: [
      {
        # NOT THE TAUTOLOGY IT LOOKS LIKE, and the reason is worth stating because it is the only
        # place in this module where an assertion exists for what it FORCES rather than for what it
        # compares. A pillar's growth term is an estimate, so no rendered object reads it -- and in
        # this module system an option nothing reads is never forced, which means its `mkOption`
        # with no default can be silently omitted and its type (a positive count, a percentage
        # between 1 and 100) is never checked. Without this, a trace store keeping zero percent of
        # the traffic evaluates cleanly all the way to a manifest. `growthOf` reads the term, so
        # declaring a store without stating what drives its size, or stating a degenerate one, fails
        # the render instead of the report.
        assertion = growthOf x != "";
        message =
          "nixwatch: store `${x.name}` does not state what drives its size. Every pillar here declares "
          + "one, and a different one, because they are not priced by the same question: a metrics "
          + "store by `activeSeries`, a log store by `ingestMiBPerDay`, a trace store by "
          + "`sampledPercent`. Multiplied by `retention` that is what this pillar costs to keep, and it "
          + "is the number nobody can reconstruct later from the declaration.";
      }
      {
        # Passed verbatim to a program with its own unit grammar, so a translation is refused rather
        # than performed. This repository's duration grammar reads a bare integer as SECONDS; a
        # metrics store reads a bare number as MONTHS. Two grammars that disagree about the default
        # unit must never be silently bridged.
        assertion = durationLib.toSeconds x.w.retention != null
          && builtins.match "[0-9]+" x.w.retention == null;
        # The message quotes the growth term too: it is the one place a pillar's two cost numbers are
        # stated together, which is exactly what somebody re-reading this refusal wants to see.
        message =
          "nixwatch: store `${x.name}` declares `retention = \"${x.w.retention}\"` (beside ${growthOf x}), "
          + "which is not a duration with a unit. Write `30d`, `12h`, `90m` or `3600s` -- a bare integer "
          + "is legal in this repository's own duration grammar (where it means seconds) and is exactly "
          + "the wrong thing to hand a store, because each of these programs reads a bare number in its "
          + "own unit. Nothing here converts between the two: a retention that parses as thirty seconds "
          + "here and thirty months there is not a value worth guessing at.";
      }
    ])
    stores;

  dashboardAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w;
        unknown = lib.filter (n: !(knownStore n)) w.reads;
        unrendered = lib.filter (n: knownStore n && !(renderedStore storeByName.${n})) w.reads;
      in
      [
        {
          assertion = w.reads != [ ];
          message =
            "nixwatch: dashboard `${name}` reads no store at all. A dashboard is a CONSUMER of the "
            + "pillars and holds no telemetry of its own, so one that names nothing renders a login page "
            + "over an empty database. Name at least one of: " + showStores + ".";
        }
        {
          assertion = unknown == [ ];
          message =
            "nixwatch: dashboard `${name}` reads " + listNames unknown + ", which "
            + (if lib.length unknown == 1 then "is not a declared, enabled store" else "are not declared, enabled stores")
            + ". This relationship is typed on purpose -- there is no URL option on a dashboard anywhere "
            + "in this module -- so that a data source pointing at nothing is an eval error instead of a "
            + "panel that spins until somebody clicks it. Declared stores: " + showStores + ".";
        }
        {
          assertion = unrendered == [ ];
          message =
            "nixwatch: dashboard `${name}` reads " + listNames unrendered + ", which is delivered as a "
            + "chart. A chart names its own Services, from its own release name and its own template, so "
            + "the address this module would derive is one the chart never creates -- and the failure is "
            + "the quiet kind: everything applies, the dashboard comes up, and that data source times out "
            + "forever. Point it at a store this module renders, or wire that data source in the same "
            + "values file that delivers the chart.";
        }
      ])
    (workloadsOfKind "dashboards");

  shipperAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w;
        target = if knownStore w.ships then storeByName.${w.ships} else null;
      in
      [
        {
          assertion = target != null;
          message =
            "nixwatch: shipper `${name}` ships to `${w.ships}`, which is not a declared, enabled store. "
            + "Nothing else can supply that address: this module DERIVES it from the store's own name and "
            + "the observability path's namespace, precisely so that nobody writes one by hand. Declared "
            + "stores: " + showStores + ".";
        }
        {
          assertion = target == null || target.kind == "logs";
          message =
            "nixwatch: shipper `${name}` ships to `${w.ships}`, which is a "
            + (if target == null then "store that is not declared" else "${target.kind} store")
            + ". A log shipper speaks a log store's push API; a store of another pillar answers a "
            + "different protocol on that path and rejects every write, forever, while both workloads go "
            + "on reporting themselves healthy. The three pillars are three groups here for exactly this "
            + "reason.";
        }
        {
          assertion = target == null || target.kind != "logs" || renderedStore target;
          message =
            "nixwatch: shipper `${name}` ships to `${w.ships}`, which is delivered as a chart, so the "
            + "push address this module would derive is one the chart never creates. Point it at a store "
            + "this module renders, or configure that destination in the same values file that delivers "
            + "the shipper's own chart.";
        }
      ])
    (workloadsOfKind "shippers");

  proberAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w;
        hits = crossPathHits x;
      in
      [
        {
          assertion = w.targets != { };
          message =
            "nixwatch: prober `${name}` declares no targets. An active prober watching nothing is a green "
            + "status page that means nothing -- and it is the one shape of monitoring failure this whole "
            + "repository exists to refuse, because it reads as 'all clear' by default.";
        }
        {
          # THE LOAD-BEARING RULE OF THIS REPOSITORY, at the cluster level.
          assertion = hits == [ ];
          message =
            "nixwatch: prober `${name}` points at the observability path -- "
            + lib.concatMapStringsSep "; "
              (h: "`${h.where}` names " + lib.concatStringsSep " and " (hitsIn h.value))
              hits
            + ". THE ALARM PATH MAY NEVER ACQUIRE A DEPENDENCY ON THE OBSERVABILITY PATH. A probe that "
            + "asks a time-series database, a log store or a dashboard whether something is up has moved "
            + "itself INSIDE the thing it was supposed to be outside of: when that stack is what died, the "
            + "probe does not report an outage, it reports nothing, and silence reads as health. Probe the "
            + "thing itself. If what you actually want is an alarm about the observability stack, that "
            + "belongs to the half of this repository that runs outside every cluster.";
        }
      ])
    (workloadsOfKind "probers");

  pathAssertions =
    lib.optional (onAlarm != [ ] && onObservability != [ ]) {
      assertion = platform.namespace != platform.alarmNamespace;
      message =
        "nixwatch: `nixwatch.cluster.platform.namespace` and `...alarmNamespace` are the same namespace, "
        + "and this declaration puts workloads on both paths. The separation IS the two namespaces: it is "
        + "what makes 'the prober does not depend on the stores' a fact about where things live rather "
        + "than a habit, it is what the cross-path guard's own in-cluster needle is built from, and it is "
        + "what lets the whole observability stack be deleted and rebuilt without touching the thing that "
        + "decides something is broken. Give the alarm path its own namespace.";
    };

  layoutAssertions =
    map
      (n: {
        assertion = false;
        message =
          "nixwatch: `${n}` is declared more than once: " + listNames (namedBy n) + ". A workload's name "
          + "is its app's name, its objects' name and the host part of every address derived from it, so "
          + "two declarations sharing one would render two apps into one identity.";
      })
      duplicatedNames
    ++ map
      (slot: {
        assertion = false;
        message =
          "nixwatch: slot ${toString slot} is claimed by more than one workload: "
          + listNames (claimantsOf slot) + ". A slot is one identity in every address space the fleet "
          + "maps it into, so two claimants is a collision in all of them at once.";
      })
      duplicatedSlots
    ++ map
      (ns: {
        assertion = lib.length (creatorsOf ns) == 1;
        message =
          "nixwatch: namespace `${ns}` is created by more than one workload: " + listNames (creatorsOf ns)
          + ". Two Applications owning one Namespace fight over it. Let exactly one anchor it, or anchor "
          + "it in the tenancy layer and set `createNamespace = false` on all of them.";
      })
      createdNamespaces
    ++ map
      (x: {
        assertion = !x.w.createNamespace;
        message =
          "nixwatch: workload `${x.name}` is rendered below the app grammar (it delivers whole objects "
          + "rather than a container), and `createNamespace` here would produce a Namespace with no "
          + "protection against being pruned -- which for a namespace holding a telemetry store takes "
          + "every measurement in it. Let a grammar-rendered workload anchor the namespace, or anchor it "
          + "in the tenancy layer.";
      })
      (lib.filter (x: deliveryOf x == "chart") allWorkloads);

  ## ---------------------------------------------------------------------
  ## Warnings
  ## ---------------------------------------------------------------------

  warnings =
    map
      (x: {
        when = x.w.manifests == [ ];
        message =
          "nixwatch: `${x.name}` is delivered as a chart and delivers nothing here -- `manifests` is "
          + "empty, so no object is rendered for it. That is correct when its chart is deployed by "
          + "something else in the same cluster, and the declaration still buys the accounting (its "
          + "retention and its growth term appear in `nixwatch.cluster.retention` either way). If it was "
          + "meant to be delivered from here, it is not.";
      })
      (lib.filter (x: deliveryOf x == "chart") allWorkloads)
    ++ map
      (x: {
        when = (x.w.exposure or "internal") != "internal";
        message =
          "nixwatch: workload `${x.name}` declares exposure `${x.w.exposure or "internal"}`, which is a "
          + "term of the app grammar -- and this workload is rendered below the grammar, so the class "
          + "reaches no object. Whatever fronts it is selecting on something else.";
      })
      (lib.filter (x: deliveryOf x == "chart") allWorkloads)
    ++ map
      (x: {
        when = slotOf x != null && platform.origin == null;
        message =
          "nixwatch: workload `${x.name}` claims slot ${showSlot x}, and `nixwatch.cluster.platform.origin` "
          + "is unset -- so the number is checked for collisions inside this declaration, and by nothing "
          + "for which RANGE it may come from. Set the origin when the band model is part of the same "
          + "render.";
      })
      allWorkloads;

  ## ---------------------------------------------------------------------
  ## Option shapes
  ## ---------------------------------------------------------------------

  backingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          NAME of an existing PersistentVolumeClaim backing this directory. A name, never a path.
          Nothing here creates the claim: it outlives every version of the software that mounts it,
          so its existence is not the workload's to declare.
        '';
      };

      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path on the NODE backing this directory instead of a claim, and in practice the common
          answer for a telemetry store: it is usually a filesystem somebody sized deliberately for
          exactly the growth the declaration states.

          IT PINS THE WORKLOAD TO A NODE, because the path only exists on one. The VALUE is a fleet
          fact and belongs to the consumer that passes it in -- no path appears in this repository.
        '';
      };

      hostPathType = lib.mkOption {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = "Directory";
        description = ''
          Whether a missing node path is an error or is created empty. `Directory` (the default)
          refuses to start, which is the right answer for a store: a store that finds an empty
          directory does not report a problem, it reports zero -- an empty graph, an empty log
          search, and a retention window that begins now.
        '';
      };
    };
  };

  credentialType = lib.types.submodule {
    options = {
      secret = lib.mkOption {
        type = lib.types.str;
        description = "NAME of an existing Secret holding this credential.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = "Which key inside that Secret carries it.";
      };
    };
  };

  # Shared by every workload on either path. What is NOT here matters as much as what is: no
  # `namespace` (a path decides that), no `url` anywhere (every address is derived), and no
  # `readOnly` on a backing (whether the software may write a directory is the catalogue's).
  sharedOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
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
      description = ''
        Whether this workload anchors its path's namespace. Defaults to false: a namespace outlives
        every workload in it, and exactly one thing may own it. Two workloads creating one namespace
        fails eval, and so does anchoring from a workload rendered below the app grammar -- that
        Namespace would carry no protection against being pruned.
      '';
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Which version THIS workload runs, used as the image tag. Required for anything delivered as
        a container image, and refused for anything delivered as a chart -- there the version lives
        inside the objects you deliver, and a second copy here is a pin nothing keeps honest.
      '';
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Whole image reference, replacing the catalogue repository plus `version`. Set it to PIN BY
        DIGEST (`repository:tag@sha256:...`), which is the only way two syncs of an identical
        rendered tree cannot run different code -- the grammar warns while it is unpinned.
      '';
    };

    state = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = ''
        What BACKS each directory this software cannot lose, keyed by the catalogue's own name for
        it. Where it lands inside the container, and whether the software may write it, are
        knowledge and come from the catalogue; what holds it is a value and comes from here.

        EVERY directory the catalogue names must appear. For a store this is where a declared
        retention becomes true or false: an unbacked store keeps data until its next restart, not
        for the period stated a few lines above, and says nothing about the difference.
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf credentialType;
      default = { };
      description = ''
        The credentials this software reads, keyed by the catalogue's ROLE for each one. WHICH
        environment variable a role arrives in is knowledge; which Secret holds it and under which
        key is a value. A role the software does not read is refused, and a required role that is
        missing is refused.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra plain environment, merged OVER whatever the catalogue supplies. Plain is the operative
        word: a credential belongs in `credentials`, and an address belongs to whatever allocates
        addresses -- the app grammar scans these values and refuses an address literal, and on an
        alarm-path workload this module scans them again for the observability path's own
        coordinates.

        This is where capacity goes: heap sizes, worker counts, query limits. The catalogue supplies
        what software needs in order to be CORRECT and never what it needs in order to be the right
        size.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra entrypoint arguments, appended to whatever the catalogue supplies.";
    };

    manifests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Whole objects, as YAML documents, delivered under this workload's Application. This is where
        a chart's rendered output arrives -- an operator, its custom resource definitions, several
        workloads -- and where a per-node shipper's DaemonSet arrives, because the app grammar
        renders one Deployment from one image and neither of those is that.

        Refused on a workload the grammar renders in full.
      '';
    };
  };

  # ONLY A WORKLOAD A PERSON OPENS GETS THESE. A store and a shipper have no `exposure` and no
  # `slot` option at all: they are reached by in-cluster DNS, by name, from the two workloads
  # allowed to name them -- so writing either is "the option does not exist" rather than a review
  # comment, and neither can be given a front or a fleet identity from this repository.
  frontedOptions = {
    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        WHO can reach this workload, as a class and never an address. A dashboard and a status pane
        are the two things here a person opens; everything else in this module is talked to by other
        components and by nothing else.

        A term of the app grammar, so it reaches an object only on the workloads the grammar
        renders.
      '';
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address --
        the layers underneath map it into however many address spaces the fleet keeps, which is
        exactly why nothing here moves one.

        The VALUE is a fleet fact and belongs to the consumer that passes it in. What this module
        does with it is refuse two workloads on one number. Which RANGE the numbers may come from is
        a different question, answered by the band model -- see `nixwatch.cluster.platform.origin`.
      '';
    };
  };

  # The three pillars share this much and no more: each is a store, each must say how long it keeps
  # data, and each is priced by a different question -- which lives in the group, not here.
  storeOptions = sharedOptions // {
    retention = lib.mkOption {
      type = lib.types.str;
      example = "30d";
      description = ''
        HOW LONG this store keeps data. No default anywhere, deliberately: every one of these
        programs has a built-in retention that applies silently when nothing says otherwise, and a
        store quietly keeping the wrong period is never noticed until somebody needs the data that
        is already gone.

        A duration with a UNIT (`30d`, `12h`, `3600s`) -- the same grammar this repository's host
        half uses for a check's interval, except that a bare integer is refused here rather than
        read as seconds, because the number can be passed verbatim to a program whose own default
        unit is something else entirely.

        Whether it is ENFORCED depends on the software: some take it as a command-line argument,
        which this module renders, and some read it from their own configuration file, which this
        module does not. `nixwatch.cluster.retention` says which, per store, rather than leaving a
        reader to assume the number is doing something.
      '';
    };
  };

  mkStore = { pillar, extra, description, example }: lib.mkOption {
    default = { };
    inherit description example;
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = storeOptions // extra // {
        store = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue.${pillar});
          description = "Which ${pillar} store, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.${pillar})}.";
        };
      };
    }));
  };
in
{
  options.nixwatch.cluster.platform = {
    namespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        The namespace every OBSERVABILITY-path workload lands in: the stores, the shipper, the
        dashboard. NO DEFAULT, and evaluation fails naming this option the moment any of them is
        declared.

        There is no per-workload override anywhere in this module, and that is the separation being
        structural rather than advisory: a workload's namespace is its path's, and its path is a
        property of the software. What a cluster calls this namespace is a value.
      '';
    };

    alarmNamespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        The namespace every ALARM-path workload lands in: the active prober and its status page.

        It must differ from `namespace`, and eval fails when it does not, because the whole point of
        the split is that the thing which DECIDES something is broken shares no fate with the things
        that EXPLAIN it afterwards. The observability stack can then be deleted and rebuilt whole
        without touching the prober -- and the guard that refuses a probe target pointing into the
        observability path is built from this difference.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = ''
        Delivery project every workload lands in unless it says otherwise.

        Defaults to the delivery tool's own built-in project, which permits every destination and is
        therefore the answer that cannot break a render. It is not the answer to leave in place:
        name a project of your own so this stack is governed like everything else.
      '';
    };

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = ''
        The cluster's internal DNS domain, used to build every derived address here: the data-source
        addresses a dashboard reads on, and the push address a shipper writes to. Defaulted, unlike
        the namespaces, because it is a Kubernetes default rather than a fleet fact -- but it is an
        option because a cluster installed with a different one would otherwise get addresses that
        resolve nowhere.
      '';
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nixwatch";
      description = ''
        The declaring-origin name to stamp on the workloads the app grammar renders, handing their
        slots to the BAND MODEL -- which governs which range of the identity space a declaring
        repository's workloads may take a number from.

        `null` by default because `origin` and `slot` are that model's terms: defining them into a
        render that does not include it fails with "the option does not exist". Set this only when
        it is part of the same render.

        A store and a shipper are stamped with the origin and NO number, which is what the band
        model wants for a workload nobody addresses from outside the cluster. It warns about a
        workload that renders a Service and holds no slot; for a telemetry store that warning is
        the model being correct about its own mechanism and wrong about this subject -- see
        `nixwatch.cluster.unaddressed`, which is where that absence is stated deliberately.
      '';
    };
  };

  options.nixwatch.cluster.metrics = mkStore {
    pillar = "metrics";
    description = ''
      METRICS STORES, keyed by a name of your choosing. The pillar priced by CARDINALITY: how many
      distinct series exist at once, multiplied by how long each is kept.

      Sampling twice as often costs a slightly larger compressed column and nothing else. One label
      whose values are unbounded -- a request id, a pod name in a crash loop -- multiplies the
      number of series, and each one carries its own index entry and its own retention, including
      after nothing writes to it any more. That is why this group asks for `activeSeries` and has no
      term for a sample rate, and no term for bytes per day: those are the other two pillars'
      questions and answering them here would suggest the three are interchangeable.
    '';
    example = lib.literalExpression ''
      {
        example-metrics = {
          store = "victoria-metrics";
          version = "0.0.0";
          retention = "30d";
          activeSeries = 500000;
          state.data.hostPath = "/example/state/metrics";
        };
      }
    '';
    extra = {
      activeSeries = lib.mkOption {
        type = lib.types.ints.positive;
        example = 500000;
        description = ''
          HOW MANY SERIES this store is expected to hold at once -- the number that actually prices
          a metrics store, and the one a person has to look up rather than derive.

          Required, and defaulted nowhere: a guess here is not conservative in either direction. It
          is a size estimate, not a limit -- nothing here enforces it, and nothing here could: the
          store finds out what its cardinality is by being written to. What it is FOR is that the
          declaration says what this pillar costs to keep, in the unit that actually drives the
          cost, next to the retention it is multiplied by.
        '';
      };
    };
  };

  options.nixwatch.cluster.logs = mkStore {
    pillar = "logs";
    description = ''
      LOG STORES, keyed by a name of your choosing. The pillar priced by BYTES PER DAY.

      Nothing about the number of things being watched predicts what a log store costs: one
      component switched to debug logging can double the daily volume without a single declaration
      changing anywhere. That is why this group asks for `ingestMiBPerDay` and has no term for
      cardinality and no term for sampling -- a log store that dropped nine lines in ten would have
      dropped the one line somebody was looking for.
    '';
    example = lib.literalExpression ''
      {
        example-logs = {
          store = "loki";
          version = "0.0.0";
          retention = "14d";
          ingestMiBPerDay = 2048;
          state.data.hostPath = "/example/state/logs";
        };
      }
    '';
    extra = {
      ingestMiBPerDay = lib.mkOption {
        type = lib.types.ints.positive;
        example = 2048;
        description = ''
          HOW MUCH LOG DATA ARRIVES PER DAY, in mebibytes. The unit is in the option name on purpose:
          a free-text size string would need a grammar of its own, and one more grammar is one more
          thing to get subtly wrong for no gain.

          Required, and a size estimate rather than a limit -- like every growth term here, nothing
          enforces it. Multiplied by `retention` it is what this pillar costs to keep, and it is the
          one number that moves when nothing about the declaration has changed at all.
        '';
      };
    };
  };

  options.nixwatch.cluster.traces = mkStore {
    pillar = "traces";
    description = ''
      TRACE STORES, keyed by a name of your choosing. The pillar priced by HOW MUCH OF THE TRAFFIC
      IS KEPT AT ALL.

      A trace is one document per request with a span per hop inside it, so at full traffic this
      pillar outgrows a metrics store covering the same period by orders of magnitude -- and unlike
      the other two, the usual answer is not a shorter retention but keeping less of it. That is why
      this group asks for `sampledPercent`, and why neither of the other two groups has such a term:
      a metrics store that dropped nine samples in ten would draw a graph that is simply wrong.
    '';
    example = lib.literalExpression ''
      {
        example-traces = {
          store = "tempo";
          version = "0.0.0";
          retention = "3d";
          sampledPercent = 10;
          state.data.hostPath = "/example/state/traces";
        };
      }
    '';
    extra = {
      sampledPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        example = 10;
        description = ''
          WHAT PERCENTAGE OF TRACES this store is sized to keep. A whole percent between 1 and 100:
          zero is not expressible, because a trace store keeping nothing is a store that answers no
          question while still costing a workload and a volume.

          WHAT ACTUALLY DROPS SPANS IS UPSTREAM -- the instrumented application, or a collector in
          front of this store. Nothing here samples anything, and nothing here can see what upstream
          sends. This is the number this store is SIZED for, and the honest reading of a declaration
          claiming ten percent while everything upstream sends everything is that the estimate is
          ten times wrong, not that the store will fix it.
        '';
      };
    };
  };

  options.nixwatch.cluster.shippers = lib.mkOption {
    default = { };
    description = ''
      LOG SHIPPERS, keyed by a name of your choosing. One copy on every node, reading that node's
      logs and pushing them into a log store.

      A SHIPPER IS NOT A STORE, and this group's shape is the difference. There is no `retention`
      here and no growth term, because a shipper keeps no data: what it holds is a cursor -- how far
      into each file it has read -- and losing that costs a duplicate or a gap at the seam, never
      the contents, because the contents are in the store. There is no `exposure` and no `slot`
      either: a shipper is dialled by nothing at all; it only ever writes outward.

      Its destination is a typed relationship (`ships`) against a declared LOG store, and the
      address is DERIVED from it. Pointing one at a store of another pillar fails eval rather than
      rejecting every write forever while both workloads report themselves healthy.
    '';
    example = lib.literalExpression ''
      {
        example-shipper = {
          shipper = "alloy";
          ships = "example-logs";
          manifests = [ (builtins.readFile ./rendered-shipper-chart.yaml) ];
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = sharedOptions // {
        shipper = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue.shippers);
          description = "Which shipper, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.shippers)}.";
        };

        ships = lib.mkOption {
          type = lib.types.str;
          description = ''
            NAME of the declared LOG STORE this shipper writes into. Required, and defaulted
            nowhere: a shipper that ships nowhere is a process reading files and discarding them.

            THE ADDRESS IS DERIVED FROM THIS and never supplied -- the store's own name, the
            observability path's namespace, the cluster domain, and the port its catalogue entry
            says writers push to, which is frequently not the port readers query. It is published at
            `nixwatch.cluster.shipperTargets` for the chart values that consume it.
          '';
        };
      };
    }));
  };

  options.nixwatch.cluster.dashboards = lib.mkOption {
    default = { };
    description = ''
      DASHBOARDS, keyed by a name of your choosing. What a person opens to read the pillars.

      A DASHBOARD IS A CONSUMER OF THE PILLARS AND NEVER ONE OF THEM. It holds no telemetry: every
      number it draws it fetched from a store somebody else declared. So it must NAME the stores it
      reads, as a typed relationship against declared stores -- there is no URL option on a
      dashboard anywhere in this module, and one reading a store nobody declared fails eval instead
      of rendering a panel that spins until somebody clicks it.

      It is also one of the two things here a person opens, so it is one of the two groups with an
      `exposure` class and a `slot` at all.
    '';
    example = lib.literalExpression ''
      {
        example-dashboard = {
          dashboard = "grafana";
          version = "0.0.0";
          slot = 5;
          exposure = "nb";
          reads = [ "example-metrics" "example-logs" "example-traces" ];
          state.data.hostPath = "/example/state/dashboard";
          credentials.adminPassword = { secret = "example-dashboard"; key = "admin-password"; };
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = sharedOptions // frontedOptions // {
        dashboard = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue.dashboards);
          description = "Which dashboard, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.dashboards)}.";
        };

        reads = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            NAMES of the declared stores this dashboard reads, across any of the three pillars. At
            least one is required: a dashboard reading nothing renders a login page over an empty
            database.

            EVERY ADDRESS IS DERIVED FROM THESE NAMES -- the store's own name, the observability
            path's namespace, the cluster domain, and the port its catalogue entry says readers
            query on -- and the pairs are published at `nixwatch.cluster.dashboardSources` for the
            provisioning file the consumer renders. Nothing here renders that file; what the
            declaration buys is that it cannot be written against a store that does not exist.

            A store delivered as a CHART cannot be named here, because a chart names its own
            Services and the derived address would be one it never creates.
          '';
        };
      };
    }));
  };

  options.nixwatch.cluster.probers = lib.mkOption {
    default = { };
    description = ''
      ACTIVE PROBERS, keyed by a name of your choosing. Black-box checks on an interval, with a
      status page in front of them: they dial the things they were told to dial and decide that one
      of them is broken.

      THIS IS THE ALARM PATH, LIVING INSIDE A CLUSTER, and it is the only group here on that path.
      The whole repository rests on one rule about direction: the alarm path may never acquire a
      dependency on the observability path. So this group has NO option that can name a store --
      `reads` is a dashboard's term and `ships` is a shipper's -- and every free-text string it does
      carry is scanned for the observability path's derived addresses. A hit is an eval error
      quoting the rule, not a warning.

      AND THE LIMIT NO OPTION HERE FIXES: this cannot outlive the cluster it runs in. When the node
      dies, this pod dies with it and raises no alarm about anything, including itself. That is why
      this repository's other half runs on each host's own timers, outside every cluster, and why
      declaring one here is never a reason to stop declaring those.
    '';
    example = lib.literalExpression ''
      {
        example-status = {
          prober = "gatus";
          version = "0.0.0";
          slot = 6;
          exposure = "nb";
          state.data.hostPath = "/example/state/status";
          targets = {
            example-service.url = "https://example.com/healthz";
            example-gateway.url = "https://gateway.example.com/status";
          };
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      # NO `reads`, NO `ships`. See this module's header: an alarm-path workload has no term for
      # naming anything on the observability path, and writing one is an unknown-option error.
      options = sharedOptions // frontedOptions // {
        prober = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue.probers);
          description = "Which prober, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.probers)}.";
        };

        targets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options.url = lib.mkOption {
              type = lib.types.str;
              example = "https://example.com/healthz";
              description = ''
                WHAT TO DIAL. A whole URL, because black-box probing means reaching a thing the way
                anything else reaches it -- there is nothing to derive here, and that is the
                difference between this and every other address in this module.

                SCANNED, AND REFUSED IF IT POINTS AT THE OBSERVABILITY PATH. That is the one thing
                this URL may not be, and it fails eval rather than warning.
              '';
            };
          });
          default = { };
          description = ''
            What this prober watches, keyed by a name of your choosing. At least one is required: a
            prober watching nothing is a green status page that means nothing, which is precisely
            the failure this repository exists to refuse.

            PUBLISHED, NOT RENDERED. This software reads its endpoint list from its own
            configuration file, which this module does not write -- the declared set is published at
            `nixwatch.cluster.proberTargets` for whatever ConfigMap the consumer renders. What the
            declaration buys is that the set is stated in one place, countable, and checked against
            the one rule that matters.
          '';
        };
      };
    }));
  };

  # ── Computed, read-only ──────────────────────────────────────────────────────────────────────

  options.nixwatch.cluster.observabilityPath = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onObservability;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = ''
      Workloads that EXPLAIN: the stores, the shipper, the dashboard. Every one of them dies with
      the cluster, which is why nothing on the alarm path may depend on any of them.
    '';
  };

  options.nixwatch.cluster.alarmPath = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onAlarm;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = ''
      Workloads that DECIDE something is broken, from inside the cluster. Read-only, and the point
      of it is that it is COUNTABLE: this is the list of alarm machinery that cannot outlive what it
      watches, and it should be read next to the host-side checks that can.
    '';
  };

  options.nixwatch.cluster.retention = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        pillar = lib.mkOption { type = lib.types.str; description = "Which pillar this store holds."; };
        retention = lib.mkOption { type = lib.types.str; description = "How long it keeps data, as declared."; };
        retentionSeconds = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.unsigned;
          description = "The same span in seconds, so two pillars can be compared without parsing prose.";
        };
        growth = lib.mkOption {
          type = lib.types.str;
          description = "What drives this pillar's size, in its own unit -- series, bytes a day, or what fraction is kept.";
        };
        enforced = lib.mkOption {
          type = lib.types.bool;
          description = "Whether the declared retention reaches the running store from here (an argument this module renders) or lives in a configuration file it does not.";
        };
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
    description = ''
      WHAT EACH PILLAR COSTS TO KEEP, in one readable place: how long it is kept, and what drives
      its size in the unit that actually drives it. This is the report the three-group split exists
      to make possible -- three stores with one shared shape would have had one growth term that fit
      none of them.

      `enforced` is the honest half: a store taking its retention as a command-line argument runs
      with the number stated here, and one reading its own configuration file runs with whatever
      that file says. Nothing in this module renders such a file, so nothing here can reconcile the
      two -- which is exactly why the fact is published rather than assumed.
    '';
  };

  options.nixwatch.cluster.dashboardSources = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.str));
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name (sourcesOf x)) (workloadsOfKind "dashboards"));
    defaultText = lib.literalExpression "dashboard -> store -> { pillar, url }";
    description = ''
      dashboard -> the stores it reads -> `{ pillar, url }`, with every address DERIVED from the
      store's own declaration. Published rather than rendered, because what consumes it is the
      dashboard's own data-source provisioning file.

      THE POINT IS WHICH FIELD IS DERIVED. A dashboard names a store; it never names an address,
      because an address is what a person mistypes and what a rename silently breaks. A data source
      pointing at nothing is an eval error here rather than a panel that spins.
    '';
  };

  options.nixwatch.cluster.shipperTargets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name (shipperTargetOf x))
        (lib.filter (x: shipperTargetOf x != null) (workloadsOfKind "shippers")));
    defaultText = lib.literalExpression "shipper -> { store, url }";
    description = ''
      shipper -> `{ store, url }` for the log store it writes into, derived from that store's own
      name, its namespace and the port its catalogue entry says WRITERS use -- which is frequently
      not the port readers query. Published for the chart values that consume it.
    '';
  };

  options.nixwatch.cluster.proberTargets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name (lib.mapAttrs (_: t: t.url) x.w.targets))
        (workloadsOfKind "probers"));
    defaultText = lib.literalExpression "prober -> target -> url";
    description = ''
      prober -> what it dials. Published for the endpoint configuration the consumer renders, and
      readable in one place because "what does this actually watch" is the question a status page
      is least able to answer about itself.

      Every one of these has been checked against the one rule this repository will not bend: none
      of them names anything on the observability path.
    '';
  };

  options.nixwatch.cluster.unaddressed = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name)
      (lib.filter (x: !(x.w ? slot)) allWorkloads);
    defaultText = lib.literalExpression "every workload with no slot option at all";
    description = ''
      Workloads that hold no position in the fleet's identity space, STRUCTURALLY -- there is no
      slot option on any of them. These are the things only other components talk to: the stores,
      reached by in-cluster DNS from the two workloads allowed to name them, and the shipper, which
      is dialled by nothing at all.

      Published because the absence is a decision rather than an omission. A slot is a fleet
      identity, and a workload nobody reaches from outside the cluster does not need one; the band
      model, which reasons about Services rather than about audiences, will say otherwise for a
      store, and this list is where that disagreement is recorded deliberately.
    '';
  };

  options.nixwatch.cluster.slots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs (map (x: lib.nameValuePair x.name (slotOf x)) slotClaims);
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Only the two things a person opens can ever appear here,
      structurally: there is no slot option anywhere else in this module.
    '';
  };

  options.nixwatch.cluster.renderedByGrammar = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) byGrammar;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = "Workloads rendered through the app grammar, in full.";
  };

  options.nixwatch.cluster.renderedDirectly = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) directly;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = ''
      Workloads rendered one level BELOW the app grammar, because what they deliver is a whole
      object rather than a container: a vendor's whole-stack chart, and a per-node shipper's
      DaemonSet.

      Read-only, and the point of it is that it is COUNTABLE: this is the untyped surface, and a
      boundary nobody measures becomes the architecture.
    '';
  };

  config = {
    # THE WHOLE CLUSTER-FACING RENDER, and there is nothing else: every object this half produces
    # that can be described as an app is described as one, in somebody else's vocabulary.
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkGrammarApp x)) byGrammar);

    applications = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkDirectApp x)) directly);

    nixidy.assertions =
      deliveryAssertions
      ++ storageAssertions
      ++ credentialAssertions
      ++ costAssertions
      ++ dashboardAssertions
      ++ shipperAssertions
      ++ proberAssertions
      ++ pathAssertions
      ++ layoutAssertions;

    nixidy.warnings = warnings;
  };
}
