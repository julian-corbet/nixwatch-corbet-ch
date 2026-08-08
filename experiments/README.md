# experiments

Throwaway trials: spikes, one-off scripts, things tried and abandoned or not yet worth
writing up. Nothing here is guaranteed to work, be maintained, or survive the next cleanup
pass.

If something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

See the main [README](../README.md) for the project itself.

- `verify-upstream-coordinates.sh` — every upstream coordinate in
  [`../lib/observability.nix`](../lib/observability.nix) checked against the registry or chart
  repository it names: container image repositories through the registry API, and chart
  repositories through their `index.yaml`. `--tags N` additionally shows some of what upstream is
  publishing, which is the question this repository deliberately cannot answer from its own data —
  it pins no versions anywhere. Reads the coordinates out of the catalogue rather than a second
  hand-kept list.

  **It earned its place on its first run, and not in the way it was meant to.** Three of the eight
  coordinates came back FAIL, and all three existed. The bug was in the script: `grep -q` exits the
  instant it matches, the process piping into it then dies of SIGPIPE with status 141, and under
  `set -o pipefail` the pipeline's status is that 141 rather than grep's own 0. A successful match
  on a large input reads as a failure — and a small input passes, because the writer finishes before
  grep can exit. So the failure only appears against real inputs, which is the shape of bug that
  survives review and every short test. The fix is a here-string instead of a pipeline; the finding
  is that `grep -q` and `pipefail` are a trap in any verification script, and worth checking for in
  the siblings that share this script's shape.

  Second, smaller finding, recorded so nobody copies a string out of the output: `--tags` is a HINT
  rather than a listing. A registry lists tags in its own order, which is not recency, and includes
  per-architecture build tags nobody should declare; a chart index grep can pick up a DEPENDENCY's
  version constraint rather than the chart's own version. Enough to answer "is anything published
  here at all", not enough to answer "what should I pin".

## Why the coordinate check lives here and not in `checks/`

`checks/` is `nix flake check`-wired and evaluates offline. It proves how a declaration RESOLVES,
exhaustively and in both directions, and it reads the rendered manifests back. What it cannot prove
is that a registry still serves a repository today, or that a chart repository has not been renamed.
Those are facts about the world: they change without this repository changing, and asserting them at
eval time would need either network access from a pure evaluation or a snapshot that silently goes
stale.

## Open questions worth an experiment, not yet run

nixwatch v1 is a fresh scaffold, generalized out of one private implementation's own
systemd-timer watchdog engine. Every claim below is reasoned from that implementation's own
history, not independently measured against a second, unrelated deployment.

## 001 — is immediate, un-hysteresized recovery the right default?

**Question:** the implementation this module generalizes required recovery hysteresis
symmetric to its own failure hysteresis (a probe had to succeed `failThreshold` consecutive
times before flipping back to UP, specifically so a FLAPPING probe pages once on recovery,
not once per flap). `lib/runner.nix`'s probe branch does not carry this over: the very first
success after a DOWN state flips it back to UP and sends exactly one RECOVERED, full stop. Is
that the right simplification, or does a probe that flaps right around its own `deadline`
boundary now produce a DOWN/RECOVERED/DOWN/RECOVERED storm the old hysteresis would have
suppressed?

**Hypothesis:** probably fine for most checks, because `deadline` is measured in real elapsed
time rather than a tick count — a probe would have to fail, recover, and fail again, all
within less than one `interval`, to flap at all, which the fixed per-check `interval` already
makes unlikely for anything but a sub-second probe on a very short interval. Worth watching
specifically on a check whose `interval` is set unusually short (a few seconds) against a
genuinely flaky dependency.

**Method sketch:** run a real check against a deliberately flaky dependency (a service
restarting on a tight loop) for an hour, count DOWN/RECOVERED pairs, and compare against what
the old failThreshold-style hysteresis would have produced on the same trace.

**Status:** RESOLVED 2026-07-30, in the "make it available, don't force it" direction rather
than "prove the simplification safe": a real deployment migrating onto this module (the
private implementation this repo generalizes from) turned out to depend on its own
symmetric recovery hysteresis in production, with a real page-vs-noise split riding on it --
deleting that behavior silently, on the theory that it was "probably fine," is exactly the
kind of regression that trains an operator to ignore alerts. `nixwatch.checks.<name>
.recoverAfter` (a real elapsed-time span, same grammar as `deadline`) now lets a check opt
into the old symmetric behavior; the default stays immediate-flip, since the hypothesis above
is still believed true for MOST checks and a needless recoverAfter only delays a genuine
recovery's own alert. See `lib/runner.nix`'s recovery branch and
`checks/behavior.nix`'s own `recoverAfter` proof (streak accumulation across ticks, and reset
on a mid-streak failure) for the concrete implementation this closed to.

## 002 — does `gatedBy` need to support a chain, not just one hop?

**Question:** `nixwatch.checks.<name>.gatedBy` names exactly one other check. A check gated
by a check that is itself gated by a third works mechanically (each script only ever reads
its OWN immediate gate's state file), but nothing in this module reasons about the resulting
chain as a whole — there is no cycle detection beyond direct self-reference, and no way to ask
"is this check transitively frozen" without walking the chain by hand.

**Hypothesis:** a same-tick-freeze via a two-hop chain (A gated by B gated by C) should just
work, since each hop is evaluated independently against persisted state, not recomputed as a
graph. A genuine cycle (A gated by B gated by A) is NOT currently caught — the direct
self-reference assertion in `modules/default.nix` only rejects `gatedBy = <own name>`, one
hop, not a longer cycle. Worth a proper graph-cycle assertion once a real deployment actually
wants a chain longer than two.

**Status:** open. No real deployment has declared a `gatedBy` chain longer than one hop yet.

## 003 — is the jitter formula (`min(interval/5, 30s)`, floored at 1s) the right default?

**Question:** `modules/default.nix` computes `RandomizedDelaySec` as roughly a fifth of each
check's own `interval`, capped at 30 seconds and floored at 1 second, so a fixed jitter tuned
for a 5-minute tick doesn't dwarf a 10-second one. This ratio was picked by inspection, not
measured against real thundering-herd behavior across many checks sharing one host.

**Hypothesis:** probably fine for the check counts one host plausibly runs (a handful to a
few dozen), but unmeasured for a host running very many checks on very short intervals, where
even a proportional jitter might still cluster enough ticks to matter for `MemoryMax`
contention across simultaneously-running oneshots.

**Status:** open. No host running more than a handful of nixwatch checks at once has been
observed yet.

## 004 — should `timeout`'s systemd-unit backstop margin (`+60s`) be configurable?

**Question:** each check's systemd service sets `TimeoutStartSec = timeout + 60s` as a
last-resort backstop above the probe's own `timeout` (see `modules/default.nix`). The 60s
margin is a guess at "enough slack for process startup + the send() call's own network round
trip," not measured against a real, slow `nixpush send` invocation under load.

**Status:** open. No real measurement of `nixpush send`'s own worst-case latency has fed back
into this constant yet.

## 005 — is a declared growth term worth anything if nothing ever measures it?

**Question:** each pillar declares what drives its size — `activeSeries`, `ingestMiBPerDay`,
`sampledPercent` — and every one of them is an ESTIMATE that no rendered object reads and nothing
enforces. `nixwatch.cluster.retention` publishes them beside the retention they multiply against,
which is what makes "what does this stack cost to keep" answerable from the declaration. But a
number nobody checks against reality is a number that drifts, and a stack whose declared cardinality
is a tenth of its real one reads as a plan while being a fiction.

**Hypothesis:** the estimate earns its place even unmeasured, because its VALUE is at declaration
time — it is the number a person has to look up before adding a pillar, and the difference between
"we run a trace store" and "we run a trace store sized for a tenth of production". Whether it stays
accurate afterwards is a different question from whether stating it was worth it. What would settle
this is comparing the declared numbers against what the running stores report about themselves after
a month.

**Method sketch:** query each store for its own actual figure — active series, bytes ingested per
day, spans accepted — and compare against the declaration. If the two diverge by an order of
magnitude within a month, the estimate is decoration and should either be dropped or reconciled by
something that reads both.

**Status:** open. Nothing here has run against a real deployment yet.

## 006 — should a config-file retention be reconciled rather than published?

**Question:** two of the three store entries take their retention from their own configuration file,
which this module does not render. The declared number is published with `enforced = false`, and the
file that has to implement it is the consumer's. So a declaration saying `30d` beside a file saying
`7d` is a lie this repository cannot catch — it can only make the two visible in one place each.

**Hypothesis:** rendering those configuration files here would be the wrong fix, and for the same
reason the app grammar exists: the file's schema belongs to somebody else's release, and a module
that renders one is a second implementation that goes stale on the vendor's schedule rather than
ours. The right fix, if there is one, is probably a CHECK rather than a renderer — something that
reads the consumer's rendered ConfigMap and compares the number against the declaration, which is
possible in a private consumer's own render and not possible here.

**Status:** open, and deliberately so. The honest half is shipped (the report says which retentions
are enforced and which are not); what is missing is a way for a consumer to close the loop without
this repository growing a config renderer.
