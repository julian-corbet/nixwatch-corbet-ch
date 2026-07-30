# experiments

Throwaway trials: spikes, one-off scripts, things tried and abandoned or not yet worth
writing up. Nothing here is guaranteed to work, be maintained, or survive the next cleanup
pass.

If something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

See the main [README](../README.md) for the project itself.

## Open questions worth an experiment, not yet run

nixwatch v1 is a fresh scaffold, generalized out of one private implementation's own
`fleet-watchdog.nix`. Every claim below is reasoned from that implementation's own history,
not independently measured against a second, unrelated deployment.

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

**Status:** open. No real flapping dependency has exercised this module yet.

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
