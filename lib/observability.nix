#
# The cluster catalogue: what the in-cluster half of knowing is made of. Six groups, and the
# split between them is the subject rather than a filing convention:
#
#   `metrics`     a time-series store. Cheap per sample, and priced by how many distinct
#                 SERIES exist at once.
#   `logs`        a log store. Priced by how many BYTES arrive per day.
#   `traces`      a trace store. Priced by how much of the traffic is kept at all.
#   `shippers`    what carries logs from a node into the log store. HOLDS NO DATA.
#   `dashboards`  what a person opens to read the three above. A CONSUMER of them, never one
#                 of them.
#   `probers`     an active black-box status pane. THE ALARM PATH, living in the cluster.
#
# ── THE THREE PILLARS ARE THREE GROUPS, NOT ONE GROUP WITH A `kind` FIELD ──────────────────────
#
# There is no `pillar` field anywhere below, and that is deliberate: the group IS the pillar, so
# there is nothing to edit that would turn a metrics store into a log store. They are separated
# because they do not cost the same thing and are not sized by the same question -- see
# ../modules/cluster.nix, where each group carries a DIFFERENT required growth term, and where
# asking a metrics store how many bytes a day it takes is an unknown option rather than a value
# nobody reads.
#
# ── THE ALARM/OBSERVABILITY AXIS, WHICH THIS REPOSITORY'S WHOLE THESIS RESTS ON ────────────────
#
# Every entry carries a `path`, and it is a property of the SOFTWARE rather than a decision a
# consumer makes:
#
#   `observability`  the three stores, the shipper, and the dashboard. Built to EXPLAIN. When the
#                    cluster is what died, all of it dies with the cluster and has nothing to say.
#   `alarm`          the prober. It probes from outside the thing it watches and decides that
#                    something is broken, which is the other job entirely.
#
# THE RULE IS ONE-DIRECTIONAL AND IT IS THE READMEs' HEADLINE: the alarm path may never acquire a
# dependency on the observability path. A probe that queries a time-series database to decide
# whether something is up has quietly moved itself inside the thing it was supposed to be outside
# of. ../modules/cluster.nix enforces that in two ways at once -- an alarm-path workload has no
# option that could NAME a store, and every free-text string it does carry is scanned for the
# stores' own derived addresses -- and the reverse direction is not forbidden, because a dashboard
# reading a prober would be the safe direction. It is merely unrepresentable here: a prober is not
# a store, so nothing can read it.
#
# THE PROBER CANNOT OUTLIVE THE CLUSTER IT RUNS IN. That is not a defect in the entry below and no
# option fixes it; it is the reason this repository's OTHER half exists, on each host's own systemd
# timers, outside every cluster. Both halves are wanted: one survives, one explains.
#
# ── ONE PIECE OF SOFTWARE IS NOT ONE VERSION, so no entry below carries one ────────────────────
#
# The same reasoning the sibling catalogues state: a version is a value supplied by whoever
# declares a workload, and a stack mid-upgrade is running two. `image` is a REPOSITORY with no tag;
# `chart` is a coordinate with no version, because a chart's version is pinned inside the objects
# the consumer delivers and a second copy out here would be a pin nothing keeps honest.
#
# ── FIELDS ────────────────────────────────────────────────────────────────────────────────────
#
# Shared by every group:
#
#   `path`         `observability` or `alarm`. See above. Not declarable anywhere.
#   `delivery`     HOW the thing arrives:
#                    `image`  one container image; the app grammar renders it in full, including
#                             the Service its address is derived from.
#                    `chart`  its vendor's Helm chart -- custom resource definitions, an operator,
#                             several workloads -- rendered one level below the grammar as whole
#                             objects, because the grammar renders one Deployment from one image
#                             and that is not what a chart is.
#   `image`        container image REPOSITORY, no tag. `null` for a chart delivery.
#   `chart`        `{ repo, name }`, deliberately WITHOUT a version.
#   `ports`        named container-side ports, `<name> = <number>`. A container port is a property
#                  of the software rather than of any network -- the one kind of number a public
#                  catalogue may carry. Empty on every chart delivery: the chart names its own.
#   `primaryPort`  which of those the readiness probe watches.
#   `state`        directories this software writes that it cannot lose, as
#                  `<name> = { mountPath, readOnly }`. WHERE it lands inside the container is
#                  knowledge and lives here; what BACKS it is a value and comes from the
#                  declaration. Empty on a chart delivery, whose own values back its volumes.
#   `env`          plain environment the software needs to be CORRECT. Never sizing, never
#                  credentials, never an address of anything outside the container.
#   `args`         entrypoint arguments in the same spirit.
#   `readiness`    probe shape and timing. `path = null` means a TCP connect.
#   `credentials`  `<role> = { env, required }`. The role is what the credential IS; which Secret
#                  holds it and under which key is a value.
#   `note`         what the entry is, and every non-obvious thing about running it.
#
# On a STORE entry (`metrics`, `logs`, `traces`) only:
#
#   `scheme`         how a reader reaches it, `http` or `https`. Part of the derived address.
#   `queryPort`      which declared port a READER dials. The dashboard's data-source address is
#                    built from it, so nobody writes a store's address by hand.
#   `writePort`      which declared port a WRITER pushes to. Frequently not the same port and
#                    frequently not the same protocol -- which is exactly why it is a second field
#                    rather than one `port` doing both jobs badly.
#   `retentionVia`   HOW the declared retention reaches the running store:
#                      `argument`  as a command-line argument this module renders, from
#                                  `retentionArg` with `{RETENTION}` substituted.
#                      `config`    from the software's own configuration file, which this module
#                                  does not render. The number is then PUBLISHED and enforced by
#                                  nothing here -- see `nixwatch.cluster.retention`, whose
#                                  `enforced` field says so per store.
#   `retentionArg`   the argument template, or `null` for `retentionVia = "config"`.
#
# On a DASHBOARD entry only:
#
#   `authenticationModes`
#                  explicit access modes the software can implement. The consumer chooses one;
#                  the catalogue owns the exact environment that gives that choice meaning.
#
# On a SHIPPER entry only:
#
#   `perNode`      true when the software runs one copy on every node. The app grammar renders a
#                  Deployment for every app, unconditionally, which is not that -- so a `perNode`
#                  entry is never image-delivered, and ../checks/cluster-eval.nix asserts that over
#                  the whole catalogue rather than trusting it.
{ ... }:
{
  # ── Metrics: the pillar priced by CARDINALITY ────────────────────────────────────────────────
  metrics = {
    victoria-metrics = {
      path = "observability";
      delivery = "image";
      image = "docker.io/victoriametrics/victoria-metrics";
      chart = null;

      ports = { http = 8428; };
      primaryPort = "http";
      scheme = "http";
      queryPort = "http";
      writePort = "http";

      retentionVia = "argument";
      retentionArg = "-retentionPeriod={RETENTION}";

      state = {
        data = { mountPath = "/victoria-metrics-data"; readOnly = false; };
      };

      env = { };
      args = [ ];

      readiness = {
        path = "/health";
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = { };

      note = ''
        The single-binary time-series store: one process, one directory, one port that both answers
        queries and accepts writes. It is the entry an in-cluster observability stack should start
        from, and the one whose address can be DERIVED, because this module renders its Service.

        WHAT IT COSTS IS CARDINALITY, NOT SAMPLES. Doubling how often a value is sampled roughly
        doubles a compressed column and nothing else; adding one label whose values are unbounded
        -- a request id, a pod name in a crash loop, a full path -- multiplies the number of
        SERIES, and every one of those carries its own index entry and its own retention. A series
        that stopped being written yesterday still occupies that index until retention expires it.
        That is why the declaration asks for `activeSeries` rather than a sample rate.

        RETENTION IS A COMMAND-LINE ARGUMENT HERE, which is the reason this entry can promise that
        the declared number is the number the process runs with. It is passed VERBATIM, so it must
        carry a unit: this repository's duration grammar accepts a bare integer meaning seconds,
        and this program reads a bare number as MONTHS. A declaration is refused rather than
        translated, because a translation between two grammars that disagree about the default unit
        is exactly the kind of helpfulness that turns 30 seconds into 30 months.

        ITS DEFAULT RETENTION IS ONE MONTH and applies the moment the argument is absent, which is
        why the declaration has no default at all: a store silently keeping a month of data is not
        obviously wrong, and is therefore never noticed until somebody needs the thirteenth month.
      '';
    };

    victoria-metrics-k8s-stack = {
      path = "observability";
      delivery = "chart";
      image = null;
      chart = {
        repo = "https://victoriametrics.github.io/helm-charts/";
        name = "victoria-metrics-k8s-stack";
      };

      ports = { };
      primaryPort = null;
      scheme = "http";
      queryPort = null;
      writePort = null;

      retentionVia = "config";
      retentionArg = null;

      state = { };
      env = { };
      args = [ ];
      readiness = null;
      credentials = { };

      note = ''
        The whole-stack chart: an operator, its custom resource definitions, a scraping agent, a
        rules evaluator, and the store itself, versioned together by people who are not us. It is
        declarable here for the same reason a forge somebody else runs is declarable in the sibling
        CI catalogue -- refusing to model it would not make the dependency go away, it would only
        make it invisible -- and what the declaration buys is the accounting: its retention and its
        expected cardinality land in the same report as every other pillar, and its namespace is
        the observability path's, decided by nothing anybody wrote down.

        WHAT IT DOES NOT BUY IS AN ADDRESS. The chart names its own Services, from its own release
        name and its own template, and this module would derive one it never creates. So a
        dashboard naming this store is REFUSED at eval rather than rendered: the failure otherwise
        is the quiet kind -- everything applies, the dashboard comes up, and one data source times
        out for as long as nobody clicks it.

        THIS CHART CAN ALSO DEPLOY A DASHBOARD AND AN ALERTMANAGER, and this model deliberately
        does not use that. A dashboard is a CONSUMER of pillars and is declared in its own group,
        naming the stores it reads; a dashboard delivered from inside one pillar's chart is a
        consumer living inside the thing it consumes, which is precisely the shape this repository
        exists to keep apart. If the chart's own dashboard is switched on in the values the
        consumer delivers, nothing here can see it -- and the declaration in `dashboards` is then
        describing a second one.
      '';
    };
  };

  # ── Logs: the pillar priced by BYTES PER DAY ────────────────────────────────────────────────
  logs = {
    loki = {
      path = "observability";
      delivery = "image";
      image = "docker.io/grafana/loki";
      chart = null;

      ports = { http = 3100; };
      primaryPort = "http";
      scheme = "http";
      queryPort = "http";
      writePort = "http";

      retentionVia = "config";
      retentionArg = null;

      state = {
        data = { mountPath = "/loki"; readOnly = false; };
      };

      env = { };
      args = [ ];

      readiness = {
        path = "/ready";
        initialDelaySeconds = 15;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 12;
      };

      credentials = { };

      note = ''
        The log store, in its single-binary shape: one process holding chunks and their index, one
        port serving both the push API a shipper writes to and the query API a dashboard reads
        from.

        WHAT IT COSTS IS INGEST, AND INGEST IS TRAFFIC. Unlike a metrics store, nothing about the
        number of things being watched predicts the bill: one component switched to debug logging
        can double the daily volume without a single declaration changing anywhere. That is why the
        declaration asks for `ingestPerDay` -- a number a person has to look up rather than derive,
        and the honest unit of "what does this pillar cost to keep".

        RETENTION HERE IS A CONFIGURATION FILE, and worse, it is TWO settings that must agree: a
        retention period, and a compactor explicitly told to enforce it. A configuration that names
        the period and leaves the compactor's enforcement off deletes NOTHING, forever, and reports
        itself perfectly healthy while the disk fills. Nothing in this module renders that file, so
        nothing here can check it -- what it does instead is publish the declared number at
        `nixwatch.cluster.retention` with `enforced = false`, so that the one place the number is
        stated and the file that has to implement it can be compared by a person.

        THE INDEX IS SMALL AND THE CHUNKS ARE NOT, which is why this entry keeps them in one
        directory anyway: splitting them is a real decision about backup boundaries, and it belongs
        to whoever backs the volume, not to a catalogue.
      '';
    };

    loki-chart = {
      path = "observability";
      delivery = "chart";
      image = null;
      chart = {
        repo = "https://grafana.github.io/helm-charts";
        name = "loki";
      };

      ports = { };
      primaryPort = null;
      scheme = "http";
      queryPort = null;
      writePort = null;

      retentionVia = "config";
      retentionArg = null;

      state = { };
      env = { };
      args = [ ];
      readiness = null;
      credentials = { };

      note = ''
        The same log store, delivered as its vendor's chart: a read path, a write path, a compactor
        and an index gateway as separate workloads, versioned together by people who are not us. It
        is the shape a log store grows into once one process is no longer enough, and it is
        declarable here for the accounting exactly like the metrics stack.

        NOTHING HERE DERIVES ITS ADDRESS, for the same reason: the chart names its own Services, and
        this split shape has SEVERAL -- a writer pushes to one and a reader queries another. So a
        shipper naming this store is refused at eval rather than pointed at an address the chart
        never creates, which is the difference between an error at build time and a shipper that
        writes into a 404 forever while every workload reports itself healthy.
      '';
    };
  };

  # ── Traces: the pillar priced by HOW MUCH YOU KEEP AT ALL ───────────────────────────────────
  traces = {
    tempo = {
      path = "observability";
      delivery = "image";
      image = "docker.io/grafana/tempo";
      chart = null;

      # Three ports, two audiences, and they are not interchangeable: OTLP writers may speak
      # either gRPC or HTTP, while the query API answers dashboards and health checks.
      ports = { http = 3200; otlp-grpc = 4317; otlp-http = 4318; };
      primaryPort = "http";
      scheme = "http";
      queryPort = "http";
      writePort = "otlp-grpc";

      retentionVia = "config";
      retentionArg = null;

      state = {
        data = { mountPath = "/var/tempo"; readOnly = false; };
      };

      env = { };
      args = [ ];

      readiness = {
        path = "/ready";
        initialDelaySeconds = 15;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 12;
      };

      credentials = { };

      note = ''
        The trace store. A trace is one document per request, with a span per hop inside it, so at
        full traffic this pillar outgrows a metrics store covering the same period by orders of
        magnitude -- and unlike the other two, the usual answer is not a shorter retention but
        keeping LESS OF IT. That is why the declaration asks for a `sampling` fraction, and why
        neither of the other two groups has such a field: a metrics store that dropped nine samples
        in ten would produce a graph that is simply wrong, and a log store that dropped nine lines
        in ten would lose the one line anybody was looking for.

        ITS WRITE PORT IS NOT ITS READ PORT. Instrumented software pushes spans over OTLP on one
        port and a dashboard queries an HTTP API on another, which is the concrete reason a store
        entry carries `queryPort` and `writePort` separately rather than one `port` pretending to
        be both.

        RETENTION IS ITS COMPACTOR'S BLOCK RETENTION, in its own configuration file, with the same
        honest limit the log store's entry states: this module publishes the declared number and
        renders no file, so the two can be compared by a person and by nothing else.

        SAMPLING IS DECIDED WHERE THE SPAN IS CREATED, not here. The fraction on the declaration is
        the number this store is SIZED for; what actually drops spans is the instrumented
        application or a collector in front of it. A declaration claiming a tenth while everything
        upstream sends everything is not refused here, because nothing here can see upstream -- it
        is simply a size estimate that is ten times wrong, which is what the report exists to make
        legible.
      '';
    };
  };

  # ── Shippers: they carry, they do not keep ──────────────────────────────────────────────────
  shippers = {
    alloy = {
      path = "observability";
      delivery = "chart";
      perNode = true;
      image = null;
      chart = {
        repo = "https://grafana.github.io/helm-charts";
        name = "alloy";
      };

      ports = { };
      primaryPort = null;
      state = { };
      env = { };
      args = [ ];
      readiness = null;
      credentials = { };

      note = ''
        The log shipper: one copy on every node, reading that node's container logs and pushing
        them into the log store. It is in its own group and not in `logs` because it is not a
        store, and the difference is not one of size -- it is that losing a shipper loses nothing.

        WHAT IT KEEPS IS A CURSOR, NOT DATA. A shipper does hold a little state -- how far into
        each file it has read -- and losing that costs a duplicate or a gap at the seam, never the
        contents, because the contents are in the store. That is the whole reason this group has no
        `retention` option, no growth term, and nothing to back: there is no question here of the
        form "what does it cost to keep this", because it does not keep anything.

        IT RUNS ON EVERY NODE, WHICH IS WHY IT IS CHART-DELIVERED. The app grammar renders one
        Deployment per app, unconditionally; a one-per-node workload is a DaemonSet, which the
        grammar has no term for. Rather than teach a grammar about a kind it does not model, a
        shipper's objects arrive as whole objects, exactly like a chart's -- and `perNode` is what
        records that as a property of the software, so an image delivery for a per-node entry is
        refused instead of quietly rendering one copy of a shipper for a whole cluster.

        THE ADDRESS IT PUSHES TO IS DERIVED, from the log store it names. It is published rather
        than injected, because what consumes it is the chart's own values file.
      '';
    };
  };

  # ── Dashboards: consumers of the pillars, never a pillar ────────────────────────────────────
  dashboards = {
    grafana = {
      path = "observability";
      delivery = "image";
      image = "docker.io/grafana/grafana";
      chart = null;

      ports = { http = 3000; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/var/lib/grafana"; readOnly = false; };
      };

      env = { };
      args = [ ];

      readiness = {
        path = "/api/health";
        initialDelaySeconds = 10;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = {
        adminUser = { env = "GF_SECURITY_ADMIN_USER"; required = false; };
        adminPassword = { env = "GF_SECURITY_ADMIN_PASSWORD"; required = true; };
      };
      authenticationModes = [ "credentials" "anonymous-admin" ];

      note = ''
        The thing a person opens. It is a CONSUMER of the three pillars and never one of them: it
        stores no telemetry of its own, and everything it draws it fetched from a store somebody
        else declared. Its own directory holds dashboards, users and sessions -- which is state,
        and which is why it must be backed like any other, even though losing it loses no
        measurement.

        CREDENTIALS ARE THE DEFAULT. In that mode the admin password is required because the
        alternative is not "no password" but a well-known default one. Grafana can also implement
        `anonymous-admin`, but that is a separate explicit mode rather than a missing Secret: the
        module disables the login form, grants the anonymous organisation role Admin, refuses any
        simultaneously declared credentials, and refuses public exposure. This records the real
        security decision without putting a private hostname or network address in this catalogue.

        ITS DATA SOURCES ARE PROVISIONED FROM A FILE this module does not render. What the
        declaration buys instead is that the file cannot be written against a store that does not
        exist: `reads` names declared stores, the addresses are DERIVED from them, and the pair is
        published at `nixwatch.cluster.dashboardSources` for whatever ConfigMap the consumer
        renders. A free-text URL would have been fewer lines here and one more place a typo lives
        until somebody clicks the panel.
      '';
    };
  };

  # ── Probers: the alarm path, living inside the cluster ──────────────────────────────────────
  probers = {
    gatus = {
      path = "alarm";
      delivery = "image";
      image = "ghcr.io/twin/gatus";
      chart = null;

      ports = { http = 8080; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/data"; readOnly = false; };
      };

      env = { };
      args = [ ];

      readiness = {
        path = "/health";
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = { };

      note = ''
        An active black-box prober with a status page in front of it: it dials the things it was
        told to dial, on an interval, and decides that one of them is broken. That is the ALARM
        job, and this entry is the only one in this catalogue on that path.

        IT MAY NOT DEPEND ON ANY OF THE OTHERS, and that is enforced rather than requested. There
        is no option on this group that can name a store; the declared targets and every free-text
        string it carries are scanned for the observability path's own derived addresses; and it
        lands in a different namespace, decided by its path rather than by anything a declaration
        says. See ../modules/cluster.nix's header for the full list.

        IT CANNOT OUTLIVE THE CLUSTER IT RUNS IN, and no version of this entry ever will. When the
        node dies, this pod dies with it, and a prober that is not running raises no alarm about
        anything -- including about itself. That is the whole reason this repository's other half
        runs on each host's own systemd timers, outside every cluster, and why neither half is
        redundant: this one watches many things cheaply from one place, the other one survives.

        ITS HISTORY IS SQLITE IN A DIRECTORY, and only if its own configuration says so -- the
        default storage is memory, which is erased on every restart, and a status pane whose
        history resets every deploy is a page nobody can answer "was this flapping last week" from.
        The directory is listed as state for that reason; the configuration that points at it is a
        value, in the file the consumer supplies.

        ITS OWN ALERTING IS NOT THIS REPOSITORY'S TRANSPORT. This software can notify on its own,
        through providers configured in its own file. nixwatch names none of them, holds no key,
        and renders no such configuration -- the same permanent exclusion the host half states for
        every alert it raises: delivery belongs to nixpush, and what this entry contributes is the
        verdict.
      '';
    };
  };
}
