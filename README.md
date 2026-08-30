# nixwatch

**An alarm tells you that something broke; a dashboard tells you what. nixwatch owns both
halves of knowing — the liveness verdict, raised exactly once per state transition on the
channel it was told to use, and the metrics, dashboards and traces that explain it afterwards
— and neither half ever carries the message itself: delivery is
[nixpush](https://github.com/julian-corbet/nixpush-corbet-ch)'s job, always.**

The alarm half is a liveness/heartbeat discipline as a NixOS module, and it is what exists
today: named checks, each with a probe (or, for a heartbeat, no probe at all), an interval, a
staleness deadline, a severity, and a nixpush channel to dispatch on. Every alert fires exactly
once per state TRANSITION — a still-failing tick never re-pages, a still-healthy one never
speaks at all.

The observability half is the time series, the logs, the traces and the dashboards that answer
"what was actually happening" once the alarm has already told you that something was. It is a
cluster declaration rather than a host one — a metrics store, a log store and its shipper, a
trace store, a dashboard that reads them, and the one piece of the alarm path that lives in a
cluster: an active black-box prober with a status page. See
[The observability half](#the-observability-half-declared) below.

This repo, and the design it implements, is a generalization of one private operator's own
systemd-timer watchdog engine, born from an incident where a host memory-wedged overnight —
every service on it, including SSH, went unresponsive — and **nothing noticed**, because
nothing watching it was independent of it: the alerting path itself depended on infrastructure
that lived on the same box that had just gone dark. The fix that implementation landed on:
probe every plane from OUTSIDE the thing being watched, alert only on a state transition, and
push a heartbeat unconditionally so
silence itself becomes detectable rather than reading as "all clear" by default. That lesson
does not soften now that the same repo also owns the dashboards; keeping it sharp is what the
next section is for. The alarm half is that mechanism, with every operator-specific probe,
hostname, and bespoke delivery-queue detail stripped out — see
[What changed vs. the implementation this generalizes](#what-changed-vs-the-implementation-this-generalizes)
below for exactly what was cut, and why.

## Two jobs, one subject

Deciding that a thing is unhealthy, and being able to explain afterwards what it was doing,
are one subject: knowing. They are not one JOB, and this repo owning both is precisely what
makes it worth stating where the seam runs, out loud, rather than leaving it to be inferred
from which repo somebody happened to put a thing in.

- **Outside-in liveness** — the checks in `modules/default.nix`, on each host's own systemd
  timers, probing every plane FROM OUTSIDE the thing being watched and alerting on a state
  transition through nixpush. This path is built to SURVIVE the death of what it watches. It is
  deliberately dumb, deliberately local, and deliberately dependent on nothing but a timer and
  one CLI — no database, no cluster, no query language, no browser.
- **In-cluster observability** — the stores, the shipper and the dashboard in
  `modules/cluster.nix`, deployed as cluster workloads, answering "what was actually happening" at
  a resolution no single probe could reach. This path is built to EXPLAIN, not to survive. When the
  cluster is what died, it dies with it and has nothing to say — which is exactly why the alarm
  must never route through it.

Confusing the two IS the incident above. A dashboard showing a host is down is not an alarm; it
is a picture nobody was looking at. An alarm dispatched by infrastructure sitting on the host it
watches is not an alarm either; it is a note that burns with the building. So the rule that
falls out of putting both under one roof is a rule about DIRECTION, not about scope: the alarm
path may never acquire a dependency on the observability path, in either the module code or the
deployment. A probe that queries a time-series database to decide whether something is up has
quietly moved itself inside the thing it was supposed to be outside of.

The two halves are also two evaluations that never meet: the alarm half is a NixOS module and the
observability half is a cluster module, and neither imports the other in either direction. Inside
the cluster half — where the prober and the stores DO share one file, one namespace scheme and one
render — that rule stops being a convention and becomes four structural refusals; see
[the one-directional rule, in the cluster](#the-one-directional-rule-in-the-cluster).

## What nixwatch is not

- **Not a notification transport. This exclusion is permanent, and widening the scope to
  dashboards did not touch it.** Every alert and every heartbeat beacon shells out to the
  real [`nixpush`](https://github.com/julian-corbet/nixpush-corbet-ch) CLI
  (`nixpush send --channel <name> ...`) — this repo has no idea what a "provider" is, holds
  no API keys, and will never grow its own delivery logic, on either half.
  `nixwatch.checks.<name>.channel` only ever NAMES a nixpush channel; see
  [Why nixwatch depends on nixpush, and never as a flake input](#why-nixwatch-depends-on-nixpush-and-never-as-a-flake-input)
  for how that naming works without a flake dependency in either direction.
- **Not the alarm path and the observability path collapsed into one.** Owning both halves is
  not permission to blur them: the checks in `modules/default.nix` persist one
  `STATUS LAST_KNOWN_GOOD_EPOCH` line per check and read nothing else, specifically so the
  alarm survives what it watches — and in the cluster half, where both paths do share one file,
  the separation is four structural refusals rather than a convention. See
  [Two jobs, one subject](#two-jobs-one-subject) and
  [the one-directional rule, in the cluster](#the-one-directional-rule-in-the-cluster).
- **Not the POLICY of what any one operator watches.** This repo ships the mechanism and
  generic examples only (see `examples/host/configuration.nix` and `examples/cluster/values.nix`).
  Which checks exist, what their probes actually run, which real channels they page, which
  namespace or node path or slot a store gets — that is private, per-operator configuration, and
  it belongs there, never in this repo.
- **Not a renderer of Kubernetes objects, and not a renderer of anybody's configuration file.**
  The cluster half declares what a stack NEEDS and defines it into a sibling repository's app
  grammar; the addresses it derives for a dashboard's data sources, a shipper's destination and a
  prober's endpoint list are PUBLISHED, because what consumes each of those is a configuration
  file belonging to somebody else's software. Publishing a derived address is honest; rendering
  somebody else's schema from here is a second implementation that goes stale on their release
  schedule.
- **Cannot detect its own death.** This is the one honest limit worth stating plainly rather
  than glossing over: a heartbeat check's `deadline` is a PROMISE folded into the beacon's own
  message text ("expect one at least every ..."), not a value nixwatch enforces. Enforcing it
  would require nixwatch's own tick to notice a missed deadline — but a timer that has
  stopped firing cannot also raise the alarm that it stopped firing. Closing that loop needs a
  receiver with its own missed-heartbeat timeout, or a human watching the channel, entirely
  outside this module's own timer. This is a structural fact about any local watchdog, not a
  gap a future version of this module could fix by trying harder.

## The two check shapes

Every check is one of:

- **`kind = "probe"` (default).** `probe`'s shell snippet runs every `interval`; its LAST
  command's exit status is the verdict. A persisted last-known-good timestamp tracks real
  elapsed time, never a tick count (a systemd timer's own jitter means "N consecutive ticks"
  is not a fixed span of wall-clock time; a timestamp is). Once a failure has persisted past
  `deadline`, the check flips DOWN and alerts exactly once; by default the very next success
  flips it back to UP and alerts RECOVERED exactly once. A tick that merely confirms the
  current state — still failing, still healthy — never alerts again. Set `recoverAfter` on a
  check whose dependency is known to flap on recovery: it must then succeed continuously for
  that long (again real elapsed time) before actually flipping UP, so a flap right around
  `deadline`'s own boundary cannot alert DOWN/RECOVERED/DOWN/RECOVERED on every cycle.
- **`kind = "heartbeat"`.** No probe, no state machine, no up/down transitions — just an
  unconditional "I'm alive" beacon dispatched every `interval`, full stop. This is the
  dead-man's-switch shape: the one thing naive "alert on explicit failure" monitoring always
  misses is silence itself, and a heartbeat only closes that gap if something OUTSIDE this
  module is watching for the beacon's absence (see
  [What nixwatch is not](#what-nixwatch-is-not) above).

## Gates: one root cause pages once, not once per dependent

`nixwatch.checks.<name>.gatedBy = "<other-check>"` freezes `<name>`'s tick entirely — no
probe run, no state change, no alert — for as long as the named gate itself reads DOWN. This
generalizes the implementation this module is built from, which hardcoded exactly one such
relationship (a single "control probe" checking the hub's own network egress, gating every
other host probe, so an egress blip couldn't fan out into "everything is down") into a
reusable relationship any check can declare against any other. The gate's own check already
alerts once, for the shared root cause; its dependents staying silent while it's down is what
keeps that one alert legible instead of buried under a dozen others saying the same thing in
different words.

## Why nixwatch depends on nixpush, and never as a flake input

`nixwatch.checks.<name>.channel` is a plain string naming a key in
[nixpush](https://github.com/julian-corbet/nixpush-corbet-ch)'s own
`nixpush.channels.<name>` — but this repo's `flake.nix` has no `nixpush` input at all, and
never will. This is the "read a sibling defensively, never as a flake input" convention this
design-system family reserves for PEER repos (as opposed to a genuinely lower layer): every
read of nixpush's own config goes through `config.nixpush.enable or false`,
`config.nixpush.channels or { }`, `config.nixpush.package or null` — each safe even when
NO module anywhere declares `options.nixpush` at all, because Nix's `or` attaches to the
WHOLE dotted selection (`config.nixpush.enable`), not just its final segment, so a completely
absent `nixpush` top-level attribute is caught by the same `or` a missing `.enable` leaf
would be.

Concretely, this buys two things:

- A host that has not yet wired up nixpush at all can still adopt nixwatch — every check's
  `channel` goes UNVALIDATED (nixwatch has no channel list to check it against), and every
  `send()` call falls back to a bare `nixpush` resolved off `$PATH` — see
  `examples/host/configuration.nix`, which deliberately imports no nixpush stub at all, for
  exactly this path.
- A host that HAS wired up nixpush gets a real build-time assertion: `nixwatch.checks.<name>
  .channel` naming a channel absent from `nixpush.channels` fails the build, with a message
  naming every channel that DOES exist — instead of failing silently at 3am, at the one
  `nixpush send` call that would have raised the alarm about whatever this check was
  watching.

This is checked in **both directions**, twice over — with nixpush absent from the composed
system entirely, and with it present but the named channel missing — see
`checks/assertions.nix`'s own `checks/undeclared-channel-*`/`checks/unvalidated-channel-*`
entries.

## is-it-live: the consumer side, per host

A probe check answers "did the last tick of ONE liveness question succeed" — which is exactly
the wrong shape for a different, equally real failure: a publisher that runs every 60 seconds
for days, signed and green on every tick, into zero receivers. Nothing about that publisher's
own probe ever fails — it is doing precisely what it was told to do — so a check watching IT
would stay green the entire time. The gap is one level up: nobody ever asked whether the thing
its output was supposed to reach still exists at all. `nixwatch.liveness` is that question,
asked per host, per declared **subject** (typically one nix* module's own domain): is the
module even enabled, are the systemd units it depends on actually active right now, and — the
part a green unit cannot answer on its own — is that subsystem's OWN verify or health artifact
actually FRESH, not merely present.

This reads three things per subject, and reports one of five states — `FRESH`, `DOWN`,
`STALE`, `UNKNOWN`, `DISABLED` — never collapsing the middle three into either end:

- **`moduleEnabled`**, handed in by the operator's own configuration.nix (typically
  `config.nixnet.enable or false`) — nixwatch never imports nixnet, nixboot, or any other nix*
  module as a flake input, the same house rule this repo already applies to nixpush (see
  above), so it has no way to read this value itself. A subject whose module is disabled is
  reported `DISABLED` and nothing else about it is ever queried — an off module having no
  running units is expected, not a finding.
- **`units`**, checked with `systemctl is-active` — necessary, never sufficient, for the same
  reason a check's own `probe` doc gives for a FUSE/network mount: a unit reporting `active` is
  not proof it actually answers.
- **One of `healthFile` or `verifyUnit`** (mutually exclusive — a subject has exactly one way
  of proving its own freshness), each reading an EXISTING primitive rather than reinventing
  one:
  - `healthFile` reads nixnet's own health-document shape (BEHAVIORS.md `HEALTH-1`/`HEALTH-2`):
    a JSON document with one shared top-level `validUntil`, and — via `healthDomain` — an
    optional `.subjects.<domain>.state` breakdown for a document reporting more than one
    domain under that one expiry. Absent, unreadable, or expired all read as `UNKNOWN` or
    `STALE`, never as fresh; a document whose OWN domain reports red is `DOWN` even while its
    `validUntil` is still comfortably in the future (`HEALTH-3`: a healthy expiry is not the
    same claim as a healthy subject).
  - `verifyUnit` reads nixboot-verify's own convention: a oneshot systemd unit,
    `RemainAfterExit = true`, whose own exit code is the verdict and which persists no
    artifact of its own. A boot-once unit has no `validUntil` to read, so freshness here means
    "ran and passed THIS boot" — its own `ExecMainStartTimestamp` compared against the current
    boot's own `UserspaceTimestamp`. A unit that last ran before this boot (masked, disabled,
    or a condition that failed silently) reads `STALE`, not fresh-by-a-stale-success.
  - Neither set: `UNKNOWN`, on purpose. A subject with only `units` declared has proven systemd's
    own opinion and nothing else — that is real information, and it is not the same claim as
    "verified fresh," so it is never printed as one.

Each subject prints one line — `STATE   title: detail`, e.g. `DOWN     example network daemon:
unit(s) not active: example-netd.service=failed` — the same PASS/FAIL/SKIP-line shape
nixboot-verify already uses, deliberately not a fourth report format; run
`systemctl status nixwatch-is-it-live` (or `journalctl -u nixwatch-is-it-live`) on any host with
`nixwatch.liveness.enable = true` to read the last one.

`config` below is the module system's own — this snippet, unlike the plain attribute-set
Quickstart above, needs to live inside a module that receives it (`{ config, ... }: { ... }`),
since `moduleEnabled` and `nixwatch.liveness.package` both read it back:

```nix
nixwatch.liveness.enable = true;
nixwatch.liveness.interval = "5m";

nixwatch.liveness.subjects.nixnet = {
  moduleEnabled = config.nixnet.enable or false;
  units = [ "nixnetd.service" ];
  healthFile = "/run/nixnet/health.json";
  healthDomain = "firewall";
  title = "nixnet";
};

nixwatch.liveness.subjects.nixboot = {
  moduleEnabled = config.nixboot.verify.enable or false;
  verifyUnit = "nixboot-verify.service";
  title = "nixboot verify";
};
```

**This is not a second alerting engine.** `nixwatch-is-it-live`'s own exit code is
three-way, deliberately: `0` when every enabled subject read `FRESH`; `1` when at least one
read `DOWN` or `STALE` — decisive, known-bad evidence; `2` when nothing is `DOWN`/`STALE` but
at least one subject read `UNKNOWN` — nothing is provably broken, and nothing has proven itself
alive either, which is exactly the zero-receivers state this section opened with. Wire it
through the SAME check mechanism every other liveness question already uses (see
[The two check shapes](#the-two-check-shapes) above — this is nothing more than one more probe
whose snippet happens to be a bigger question):

```nix
nixwatch.checks.is-it-live = {
  # `[ $? -eq 0 ]`: page on UNKNOWN exactly like a genuine DOWN -- the conservative default.
  # `[ $? -ne 1 ]` instead accepts UNKNOWN as tolerable and pages only on decisive badness;
  # that choice belongs to whoever wires this check, never to nixwatch-is-it-live itself.
  probe = "${config.nixwatch.liveness.package}/bin/nixwatch-is-it-live; [ $? -eq 0 ]";
  interval = "5m";
  deadline = "15m";
  severity = "critical";
  channel = "ops-page";
  title = "is-it-live";
};
```

`nixwatch.liveness.package` (not a bare `nixwatch-is-it-live`, even though it is also on
`environment.systemPackages` for interactive use) is deliberate: a systemd oneshot's own
default PATH is a curated minimal list, not `/run/current-system/sw/bin` — see
`modules/liveness.nix`'s own header, and nixboot-verify's, for the measured reason a bare
command name inside a generated script's `probe` is not trustworthy.

**What this does not do:** it is not itself the dashboard (one host, one report — rendering
many hosts at once is, same as `HEALTH-2`, a READER's job: in this repo that reader is the
observability half, never this module, and a survey that started querying it would have
inverted the direction [Two jobs, one subject](#two-jobs-one-subject) forbids), and it cannot
discover subjects on its own (`moduleEnabled` must be handed in; see
above). It also inherits `HEALTH-2`'s own honest limit one level further down: a `healthFile`
this module reads is only ever as trustworthy as whatever wrote it — nixwatch can tell you a
document is stale or absent, never that a present, fresh-looking one is lying.

## The observability half, declared

`modules/cluster.nix` is the other half: a cluster module (composed into a
[nixidy](https://github.com/arnarg/nixidy) environment, beside
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch)'s app grammar) that declares six kinds
of workload and renders every one of them through that grammar rather than building Kubernetes
objects of its own. It shares no evaluation with the host half above and imports nothing from it.

Two of those six are things a person opens. Four are things only other components talk to. That
split runs through the whole option surface:

| group | what it is | reachable |
|---|---|---|
| `metrics.<name>` | a time-series store | no — in-cluster DNS only |
| `logs.<name>` | a log store | no |
| `traces.<name>` | a trace store | no |
| `shippers.<name>` | carries a node's logs into a log store | no — nothing dials it at all |
| `dashboards.<name>` | what a person opens to read the pillars | yes: `exposure`, `slot` |
| `probers.<name>` | active black-box checks with a status page | yes: `exposure`, `slot` |

A store and a shipper have **no `exposure` option and no `slot` option at all** — writing either is
"the option does not exist". A slot is a fleet identity, and a workload nobody reaches from outside
the cluster does not have one; `nixwatch.cluster.unaddressed` lists every workload in that position
so the absence reads as a decision rather than an omission.

### The three pillars are three groups, and each says what it costs

Metrics, logs and traces are not interchangeable, so they are not declarable as if they were. Each
group requires a `retention` and one growth term the other two do not have as an option:

| group | growth term | why that one |
|---|---|---|
| `metrics` | `activeSeries` | cardinality prices a metrics store; sampling twice as often barely moves it, and one unbounded label multiplies it |
| `logs` | `ingestMiBPerDay` | traffic prices a log store; nothing about the number of things watched predicts it |
| `traces` | `sampledPercent` | a trace store's answer to cost is keeping less of it, not keeping it for less long |

Asking a metrics store how many bytes a day it takes is an unknown option. `nixwatch.cluster
.retention` publishes all of it in one place — pillar, retention, growth term, and whether the
declared retention actually reaches the running store (some of these programs take it as a
command-line argument this module renders; some read it from their own configuration file, which
this module does not, and the report says `enforced = false` rather than implying otherwise). See
[`studies/three-pillars-are-three-option-groups.md`](studies/three-pillars-are-three-option-groups.md).

**A shipper is not a store.** It has no `retention`, no growth term and nothing to back, because it
keeps no data — only how far it has read, and losing that costs a duplicate or a gap at the seam,
never the contents. It also runs one copy per NODE, which the app grammar has no term for (it
renders one Deployment per app), so its objects arrive whole, like a chart's.

### The dashboard names stores, never addresses

`dashboards.<name>.reads` is a list of declared store names. There is no URL option on a dashboard
anywhere in this module: every data-source address is DERIVED from the store's own name, the
observability namespace, the cluster domain and the port its catalogue entry says readers query on
(which is not always the port writers push to). A dashboard naming a store nobody declared fails
eval, listing the stores that do exist.

The addresses are then PUBLISHED at `nixwatch.cluster.dashboardSources`, not rendered — what
consumes them is the dashboard's own provisioning file, which belongs to somebody else's software.
The same applies to a shipper's push destination (`shipperTargets`) and a prober's endpoint list
(`proberTargets`). What the declaration buys is that none of those files can be written against
something that is not there.

### The one-directional rule, in the cluster

The prober is the alarm path living inside a cluster, and this is where the rule from
[Two jobs, one subject](#two-jobs-one-subject) has to survive contact with a file where the stores
are one line away. Four levels, only two of which are code that runs:

1. **A workload's path is not declarable.** `alarm` or `observability` is a property of the
   software, read from the catalogue.
2. **There is no `namespace` option anywhere.** A workload's namespace is its path's, and the two
   namespaces are separate, defaultless options that must differ.
3. **An alarm-path workload has no option that could name a store.** `reads` belongs to dashboards
   and `ships` to shippers; on a prober both are "the option does not exist".
4. **Every free-text string a prober carries is scanned** — its targets, its environment, its
   arguments — against the derived in-cluster addresses of the observability path, that path's DNS
   suffix, and its workloads by name where a URL's authority begins. A hit **fails eval quoting the
   rule**. It is not a warning: a warning about this is a warning about the one thing this
   repository exists to prevent.

The reverse direction is not forbidden — a dashboard reading a prober would be the safe direction —
it is merely unrepresentable, because a prober is not a store. See
[`studies/the-alarm-path-is-not-declarable-against-the-stores.md`](studies/the-alarm-path-is-not-declarable-against-the-stores.md).

**And the limit no option fixes:** the in-cluster prober cannot outlive the cluster it runs in.
When the node dies it dies with it and raises no alarm about anything, including itself. That is
not a gap in this module — it is the reason the host half exists, on each machine's own systemd
timers, outside every cluster. Declaring a status pane is never a reason to stop declaring those.

### What it renders, and what it does not

The cluster module configures nixk3s's shared catalogue-consumer factory at the existing nested
`nixwatch.cluster` option path. Its six roots dispatch image deliveries into `nixk3s.apps`, where
the grammar renders a Deployment, Service and optional Namespace. What the grammar has no term for
— a vendor's whole-stack chart, a per-node DaemonSet — is dispatched as whole objects one level
below it, with server-side apply and diff, and listed in `nixwatch.cluster.renderedDirectly` so the
untyped surface is countable.

A chart-delivered store is still declarable, and still accounted for in the retention report — but
**a dashboard or a shipper naming one is refused**, because a chart names its own Services from its
own template and the address this module would derive is one the chart never creates. The failure
that refusal replaces is the quiet kind: everything applies, everything reports healthy, and one
data source times out until somebody clicks the panel.

## What changed vs. the implementation this generalizes

Stated plainly, because a generalization that quietly drops behavior without saying so is
worse than one that never had it:

- **Per-check `interval`, not one shared engine tick.** The implementation this module
  generalizes ran every probe off ONE systemd timer at one shared cadence. Here, each check
  gets its own timer at its own `interval` — a heartbeat that should fire every 30 seconds and
  a probe that only needs checking hourly no longer have to share a cadence neither of them
  actually wants.
- **A time-based `deadline`, not a consecutive-tick counter.** The old engine flipped DOWN
  after `failThreshold` consecutive failing ticks. `deadline` here is a real elapsed-time
  span instead — the more portable, and the more honest, version of the same idea (comparable
  directly against `interval` at eval time, which is exactly what makes the "deadline shorter
  than interval can never pass" assertion possible at all — see `modules/default.nix`).
- **Recovery hysteresis is opt-in, not gone.** The old engine required `failThreshold`
  consecutive SUCCESSES before flipping back to UP, specifically to stop a flapping probe
  from paging on every recovery blip. This module's probe branch still flips UP (and alerts
  RECOVERED) on the very first success after a DOWN state BY DEFAULT — but a check can set
  `recoverAfter` (a real elapsed-time span, same duration grammar as `deadline`, never a
  consecutive-tick count) to require that many seconds of UNBROKEN success before it actually
  flips back to UP. A failure anywhere in that streak resets it — a flap never carries a
  partial recovery into its next attempt. See `experiments/README.md` #001 for the reasoning
  this default was originally shipped on, and why a real deployment (one whose recovery
  hysteresis was load-bearing) is what motivated making it available rather than leaving it
  purely eval-time-simpler.
- **A composable `gatedBy`, not one hardcoded control probe.** See
  [Gates](#gates-one-root-cause-pages-once-not-once-per-dependent) above.
- **Dispatch through nixpush, not a bespoke crash-safe delivery queue.** The old engine
  carried its own persistent undelivered-alert queue, poison-4xx handling, and a dedicated
  paging-topic-with-fallback preference — real delivery-reliability engineering that belongs
  to nixpush's own domain, not duplicated here. `severity` maps onto nixpush's own `--priority`
  (info → low, warning → default, critical → urgent); it never invents its OWN delivery
  preference logic on top. nixpush offers the same guarantees opt-in, per channel: `durable`
  (a crash-safe on-disk spool, poison messages moved aside so one permanently-rejected alert
  cannot wedge the queue behind it) and `fallback` (degrade to another channel on a hard
  rejection, never on a transient failure, since retrying is the right answer there). Both
  default to off, so nixpush stays a thin one-shot for a channel that never asked for a queue —
  set them explicitly on any channel that needs them.
- **No vendor-specific dead-man's-switch receiver inside the check mechanism.** The old
  engine pushed its own liveness directly to gatus, a specific in-cluster status pane, with
  gatus's own `heartbeat.interval` closing the "did the watchdog itself die" loop. nixwatch's
  `kind = "heartbeat"` ships the GENERIC half of that shape (an unconditional beacon on a
  nixpush channel) and states outright that closing the loop is a receiver's job. WHICH
  receiver is a deployment decision — this repo's observability half may well end up declaring
  one, and that is fine; what stays true either way is that the beacon never learns its name,
  never reaches it by any path but a nixpush channel, and never becomes conditional on it
  being up.

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixwatch.url = "github:julian-corbet/nixwatch-corbet-ch";
  # nixpush is a SEPARATE, independent import -- nixwatch never pulls it in for you (see
  # "Why nixwatch depends on nixpush, and never as a flake input" above).
  inputs.nixpush.url = "github:julian-corbet/nixpush-corbet-ch";

  outputs = { self, nixpkgs, nixwatch, nixpush, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixwatch.nixosModules.default
        nixpush.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
nixpush.enable = true;
nixpush.defaultChannel = "ops-noise";
nixpush.ntfy.enable = true;
nixpush.channels.ops-page = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-page.env"; # NTFY_TOPIC=<unguessable topic>
  defaultPriority = "urgent";
};
nixpush.channels.ops-noise = {
  provider = "ntfy";
  secretFile = "/run/secrets/nixpush-noise.env";
};

nixwatch.enable = true;

nixwatch.checks.example-api = {
  probe = ''curl -sf -o /dev/null --max-time 10 http://example-api.internal/healthz'';
  interval = "1m";
  deadline = "5m";
  severity = "critical";
  channel = "ops-page";
  title = "example API";
};

# A mount unit reporting `active` is not proof it actually answers -- a network/FUSE session
# can die underneath an established mount and leave every filesystem call hanging instead of
# erroring, which `systemctl is-active` alone reads as healthy forever. Same probe primitive
# as example-api above; only the one-line snippet differs.
nixwatch.checks.example-mount = {
  probe = ''systemctl is-active --quiet example-mount.service && stat /mnt/example >/dev/null'';
  interval = "10m";
  deadline = "30m";
  timeout = "20s";
  severity = "warning";
  channel = "ops-noise";
  title = "example mount";
};

# The dead-man's-switch shape: a receiver watching "ops-noise" for silence longer than 15
# minutes is what actually closes this loop -- nixwatch only emits the beacon.
nixwatch.checks.example-watchdog-alive = {
  kind = "heartbeat";
  interval = "5m";
  deadline = "15m";
  severity = "info";
  channel = "ops-noise";
};
```

```console
$ systemctl list-timers 'nixwatch-check-*'
NEXT                        LEFT      LAST  PASSED  UNIT                              ACTIVATES
Thu 2026-07-30 12:01:00 UTC  38s left  n/a   n/a     nixwatch-check-example-api.timer  nixwatch-check-example-api.service
...

$ cat /var/lib/nixwatch/example-api
UP 1785412860
```

### Quickstart: the cluster half

A different evaluation entirely — a nixidy environment, with the app grammar imported alongside.
See [`examples/cluster/values.nix`](examples/cluster/values.nix) for the complete version `nix
flake check` renders and asserts.

```nix
nixidy.lib.mkEnv {
  inherit pkgs;
  modules = [
    nixk3s.nixidyModules.apps        # the grammar this module defines into -- required
    nixk3s.nixidyModules.addressing  # the band model -- optional
    nixwatch.nixidyModules.default
    ./values.nix
  ];
}
```

```nix
# values.nix
nixwatch.cluster.platform = {
  namespace = "example-observability";   # everything that EXPLAINS
  alarmNamespace = "example-status";     # everything that DECIDES -- must differ
  origin = "nixwatch";                   # only when the band model is in the render
};

nixwatch.cluster.metrics.example-metrics = {
  store = "victoria-metrics";
  version = "0.0.0";
  adopt = true;                          # only while taking over existing objects
  retention = "30d";                     # reaches this store as an argument
  activeSeries = 500000;                 # what a metrics store actually costs
  state.data.hostPath = "/example/state/metrics";
};

nixwatch.cluster.logs.example-logs = {
  store = "loki";
  version = "0.0.0";
  retention = "14d";
  ingestMiBPerDay = 2048;                # what a log store actually costs
  state.data.hostPath = "/example/state/logs";
};

nixwatch.cluster.shippers.example-shipper = {
  shipper = "alloy";
  ships = "example-logs";                # the push address is DERIVED from this
  manifests = [ (builtins.readFile ./rendered-shipper-chart.yaml) ];
};

nixwatch.cluster.dashboards.example-dashboard = {
  dashboard = "grafana";
  version = "0.0.0";
  slot = 96;
  exposure = "nb";
  reads = [ "example-metrics" "example-logs" ];   # names, never addresses
  state.data.hostPath = "/example/state/dashboard";
  credentials.adminPassword = { secret = "example-dashboard-admin"; key = "password"; };
};

# THE ALARM PATH, in its own namespace. Nothing here can name a store: `reads` is not an option on
# this group, and a target URL pointing into the observability path fails eval.
nixwatch.cluster.probers.example-status = {
  prober = "gatus";
  version = "0.0.0";
  slot = 97;
  exposure = "nb";
  state.data.hostPath = "/example/state/status";
  targets.example-site.url = "https://example.com/healthz";
};
```

```console
$ nix eval --json .#nixidyEnvs.default.config.nixwatch.cluster.retention
{"example-logs":{"enforced":false,"growth":"2048 MiB per day","pillar":"logs","retention":"14d",...},
 "example-metrics":{"enforced":true,"growth":"500000 active series","pillar":"metrics",...}}
```

## Options reference

`nixwatch.*` (`modules/default.nix`):

- `enable` — install every declared check's systemd service + timer pair.
- `stateDir` (default `/var/lib/nixwatch`) — one persisted `STATUS LAST_KNOWN_GOOD_EPOCH` file
  per check name. Losing its contents loses no DATA — every check just restarts from a clean
  "UP, as of now" baseline, the same grace period a brand-new check gets on its first run.
- `checks.<name>.kind` — `"probe"` (default) or `"heartbeat"`; see
  [The two check shapes](#the-two-check-shapes) above.
- `checks.<name>.probe` — shell snippet, last command's exit status is the verdict. Required
  for `kind = "probe"`, forbidden for `kind = "heartbeat"` (both asserted). The generic
  vehicle for any liveness question — an HTTP/TCP endpoint or a mount that reports itself
  active without actually answering are both ordinary probes (see the option's own
  description in `modules/default.nix` for a worked mount example). Runs under
  `timeout -k 5s <timeout>`, never under `set -e`.
- `checks.<name>.interval` / `.deadline` / `.timeout` — plain durations (`"30s"`/`"5m"`/
  `"2h"`/`"1d"`/a bare integer of seconds; see `lib/duration.nix`). `deadline` must never be
  shorter than `interval` (asserted, both directions — see
  [The one non-negotiable assertion](#the-one-non-negotiable-assertion) below). `timeout`
  bounds one run of `probe` (default `"30s"`; unused but still validated for `kind =
  "heartbeat"`) — enforced with a 5s kill-after grace (`lib/runner.nix`), not a plain
  `timeout`, because a probe that merely catches or ignores the first signal can otherwise
  make `timeout` itself wait past its own deadline (proven in `checks/behavior.nix`'s
  `hangCheck`).
- `checks.<name>.severity` — `"info"` / `"warning"` (default) / `"critical"`; maps onto
  nixpush's own `--priority` (low / default / urgent respectively) and is folded into the
  alert title.
- `checks.<name>.channel` — name of a `nixpush.channels.<name>` this check dispatches
  through. Asserted to exist whenever `nixpush.enable` is true; unchecked (and falls back to
  a bare `nixpush` on `$PATH`) when nixpush is not part of the composed system at all — see
  [Why nixwatch depends on nixpush](#why-nixwatch-depends-on-nixpush-and-never-as-a-flake-input).
- `checks.<name>.gatedBy` — name of another declared check whose current DOWN state freezes
  this check's tick entirely. `null` (default) means ungated. Self-reference and references to
  an undeclared check both fail the build (asserted, both directions).
- `checks.<name>.title` — human label folded into the alert/beacon title in place of the raw
  check name. `null` (default) uses the check name as-is.

`nixwatch.liveness.*` (`modules/liveness.nix`; see [is-it-live](#is-it-live-the-consumer-side-per-host)
above for the full picture):

- `enable` — install `nixwatch-is-it-live.service`/`.timer` and the report script itself.
- `interval` (default `"5m"`) — how often the survey re-runs; same duration grammar as
  `checks.<name>.interval`. Also runs once at boot.
- `subjects.<name>.moduleEnabled` — whether this subject's own nix* module is enabled on this
  host, handed in from the operator's own config (e.g. `config.nixnet.enable or false`); never
  read by nixwatch itself.
- `subjects.<name>.units` — systemd unit names expected `active` while `moduleEnabled` is true.
- `subjects.<name>.healthFile` / `.healthDomain` — path to a JSON document in nixnet's own
  HEALTH-1/HEALTH-2 shape (shared top-level `validUntil`, optional per-domain
  `.subjects.<domain>.state`); mutually exclusive with `verifyUnit` (asserted).
  `healthDomain` requires `healthFile` (asserted).
- `subjects.<name>.verifyUnit` — name of a nixboot-verify-shaped oneshot (`RemainAfterExit`,
  no artifact of its own); freshness means "ran and passed THIS boot", judged against
  `UserspaceTimestamp`. Mutually exclusive with `healthFile` (asserted).
- `subjects.<name>.title` — human label, same convention as `checks.<name>.title`.
- A subject declaring none of `units`/`healthFile`/`verifyUnit` fails the build (asserted) — it
  could never report anything but a vacuous, permanent pass.
- `package` (read-only) — the built `nixwatch-is-it-live` script; reference it by absolute
  store path from a check's own `probe`, never by bare command name (see
  [is-it-live](#is-it-live-the-consumer-side-per-host) above for why).

`nixwatch.cluster.*` (`modules/cluster.nix`; see
[The observability half](#the-observability-half-declared) above for the full picture). A different
module class — `nixidyModules`, not `nixosModules` — and a different evaluation:

- `platform.namespace` / `.alarmNamespace` — where the observability path and the alarm path land.
  Neither is defaulted, both are required the moment a workload of that path is declared, and they
  must differ. There is no per-workload `namespace` option anywhere.
- `platform.project` / `.clusterDomain` / `.origin` — the delivery project, the internal DNS domain
  every derived address is built from, and the declaring-origin name handed to the band model (null
  unless that model is part of the same render).
- `metrics.<name>` / `logs.<name>` / `traces.<name>` — the three pillars, one group each. All share
  `store` (from the catalogue), `retention` (required, and refused without a unit — it is passed
  verbatim to a program with its own default unit), `state`, `version`/`image`, `credentials`,
  `env`, `args`, `manifests`, `adopt`. `adopt` is meaningful only for image deliveries rendered
  through the app grammar; chart deliveries are refused because they either use server-side
  apply/diff unconditionally or render nothing here. Each pillar adds exactly one growth term:
  `activeSeries`, `ingestMiBPerDay`, `sampledPercent` (1–100). None of the three has the other two's.
- `shippers.<name>` — `shipper` (from the catalogue) and `ships`, the name of a declared LOG store.
  No `retention`, no growth term, no `exposure`, no `slot`: a shipper keeps nothing and is dialled
  by nothing.
- `dashboards.<name>` — `dashboard`, plus `reads` (names of declared stores, at least one) and the
  two fronted options `exposure` and `slot`. No URL option exists.
- `probers.<name>` — `prober`, plus `targets.<name>.url` (at least one) and the same two fronted
  options. **No option here can name anything on the observability path**, and every string it
  carries is scanned for one.
- Read-only reports: `retention` (what each pillar costs to keep, and whether the number is
  enforced), `dashboardSources`, `shipperTargets`, `proberTargets` (all derived, published for the
  configuration files this module does not render), `observabilityPath` / `alarmPath`,
  `unaddressed`, `slots`, `renderedByGrammar` / `renderedDirectly`. The shared factory additionally
  publishes `clusterSlots` (the same slot facts in its common report) and `notRendered` (chart
  declarations deliberately delivered by another Application).

## The one non-negotiable assertion

A check whose `deadline` is shorter than its own `interval` can never pass — with a tick only
ever arriving every `interval`, a shorter `deadline` can never be observed as satisfied, even
by a probe that recovers on its very first retry. Such a check would read as permanently DOWN
from the moment it starts, forever — the exact "trains everyone to ignore this channel"
failure `nixstorage`'s own `backups.nix` module independently arrived at under the header "AGE
IS NOT VALIDITY" for a different domain. `modules/default.nix` refuses this at build time
rather than at 3am; `checks/assertions.nix`'s `checks/deadline-shorter-than-interval-*` and
`checks/deadline-equal-to-interval-*`/`checks/deadline-longer-than-interval-*` entries prove
it fires when violated and stays silent when satisfied.

## Repository layout

| Path | What |
|---|---|
| `flake.nix` | `nixosModules.nixwatch`/`.default` (the alarm half); `nixidyModules.nixwatch`/`.default` (the observability half); `lib.parseDurationSeconds`; `lib.observability` |
| `modules/default.nix` | `nixwatch.*` option schema, assertions, systemd wiring — the only place `nixpush.*` is ever read, and only defensively |
| `lib/duration.nix` | the pure duration parser (`"5m"` → `300`); shared by `interval`/`deadline`/`timeout` |
| `lib/runner.nix` | the pure per-check script builder (`mkCheckRunner`) — the actual probe/heartbeat/gate/alert-on-transition logic, callable standalone |
| `modules/liveness.nix` | `nixwatch.liveness.*` option schema, assertions, systemd wiring for the is-it-live survey — imported by `modules/default.nix` |
| `lib/liveness.nix` | the pure is-it-live report builder (`mkLivenessReport`) — reads a health document or a verify unit per subject, callable standalone |
| `modules/cluster.nix` | Configures nixk3s's multi-root consumer factory at `nixwatch.cluster.*`, retaining only nixwatch's path, cost, relationship, credential and reporting adapters. Renders no Kubernetes object of its own |
| `lib/observability.nix` | the cluster catalogue: what each piece of software IS — its path, its delivery, its ports, the directories it cannot lose, how its retention reaches it. Knowledge, never values |
| `examples/host/` | a minimal composed system exercising every implemented option, with NO nixpush present — used by `nix flake check` |
| `examples/cluster/` | one complete declaration on both paths, with all three pillars — rendered and asserted field by field by `nix flake check` |
| `checks/duration.nix` | pure function tests for `lib/duration.nix` |
| `checks/assertions.nix` | eval-time build-fail/build-succeed tests for every `nixwatch.checks.*` assertion, both directions, including a hand-written nixpush option-surface stub (never the real nixpush flake) |
| `checks/liveness-assertions.nix` | the same eval-time build-fail/build-succeed shape, for every `nixwatch.liveness.*` assertion |
| `checks/behavior.nix` | a build-level proof that actually RUNS the generated check scripts against a fake `nixpush`, across repeated invocations — the one thing an eval-only test cannot see |
| `checks/liveness-behavior.nix` | the same build-level proof shape, for `nixwatch-is-it-live` against a fake `systemctl` and real, test-written JSON health-file fixtures |
| `checks/cluster-eval.nix` | every guard the cluster module makes, in both directions — plus the separations that are NOT guards, asserted as unknown-option errors rather than as rules somebody remembered |
| `checks/cluster-render.nix` | the manifests the cluster half actually produced, parsed and asserted field by field, including the two central ABSENCES: no observability coordinate in the alarm path's objects, and no derived address anywhere in the tree |
| `experiments/` | open questions, plus the script that checks every upstream coordinate in the catalogue against the registry that serves it |
| `studies/` | three write-ups from building the cluster half — the one-directional rule made structural, why the three pillars are three groups, and why an option nothing renders is never checked |
| `LICENSE` | MIT |

## Status

**Pre-alpha. Both halves are real.**
`modules/default.nix` + `lib/duration.nix` + `lib/runner.nix` are real and checked-in: a real
per-check systemd service + timer pair, a real generated script proven (in
`checks/behavior.nix`) to alert on transition only, freeze while gated, and beacon
unconditionally for a heartbeat — not stubs. Extracted and generalized from one private
operator's own systemd-timer watchdog engine; see
[What changed vs. the implementation this generalizes](#what-changed-vs-the-implementation-this-generalizes)
for exactly what did not survive the generalization, and why.

`modules/cluster.nix` + `lib/observability.nix` are real in the same sense: rendered through the
real app grammar and the real renderer by `nix flake check`, with the manifests read back and
asserted field by field. What is NOT claimed is production mileage — no declaration written
against it has run a cluster yet, and the growth terms it asks for have never been compared
against what a running store reports about itself (`experiments/README.md` #005).

- [x] `nixosModules.nixwatch` / `.default` (`modules/default.nix`)
- [x] `lib.parseDurationSeconds` (`lib/duration.nix`)
- [x] probe checks: alert-on-transition, time-based staleness, gated freeze
- [x] heartbeat checks: unconditional beacon
- [x] eval-time assertions for every non-negotiable, proven both directions
- [x] a build-level behavioral proof of the generated script's real, repeated-invocation behavior
- [x] `nixwatch.liveness.*` (`modules/liveness.nix` + `lib/liveness.nix`): per-host is-it-live
      survey — enabled modules, unit activity, health-document (`HEALTH-1`/`HEALTH-2`) or
      verify-unit freshness, with `UNKNOWN` reported as its own state rather than folded into
      green or red; proven in `checks/liveness-behavior.nix` against a fake `systemctl`
- [x] `nixidyModules.nixwatch` / `.default` (`modules/cluster.nix` + `lib/observability.nix`): the
      six workload groups, the three pillars each with the growth term that prices it, the
      dashboard's typed relationship to the stores it reads, a shipper that is not a store, and
      slotless workloads that are slotless structurally
- [x] the one-directional rule, structural in the cluster half: a path the catalogue owns, two
      namespaces that must differ, no option on an alarm-path workload that could name a store,
      and a scan of every free-text string it does carry — proven in both directions, mutation
      tested, and re-checked on the rendered bytes
- [ ] no declaration written against the cluster half has run a real cluster yet; the growth terms
      are unmeasured estimates (`experiments/README.md` #005) and a config-file retention is
      published rather than reconciled (#006)
- [ ] recovery hysteresis (see `experiments/README.md` #001)
- [ ] multi-hop `gatedBy` cycle detection beyond direct self-reference (see `experiments/README.md` #002)
- [ ] no real nix* module in this family writes a `HEALTH-1`/`HEALTH-2`-shaped health document
      yet (nixnet's own `checks/coverage.nix` records HEALTH-1/2/3 as unimplemented) —
      `healthFile`/`healthDomain` are proven against a hand-written fixture, not yet against a
      real writer

## Related projects

`nixwatch` is one of several small, independently-usable open-source projects sharing a
common design system:
[nixpush](https://github.com/julian-corbet/nixpush-corbet-ch) (the notification-dispatch
mechanism every alert and heartbeat this module raises actually travels through — named by
string, never a flake input; see
[Why nixwatch depends on nixpush](#why-nixwatch-depends-on-nixpush-and-never-as-a-flake-input)),
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) (the app grammar, shared consumer
factory, and band model governing the two reachable workloads' slots — a consumer still composes
the grammar directly, while this flake closes its exported cluster module over the matching factory),
[nixstorage](https://github.com/julian-corbet/nixstorage-corbet-ch) (a sibling in spirit —
the same "hard-won rules as enforced modules, not documentation to remember" shape, and the
same "read a sibling's config defensively, never as a flake input" convention this repo
reuses for nixpush), and
[nixpower](https://github.com/julian-corbet/nixpower-corbet-ch) (another sibling in the same
family). Use any of them together or standalone.

## License

MIT.
