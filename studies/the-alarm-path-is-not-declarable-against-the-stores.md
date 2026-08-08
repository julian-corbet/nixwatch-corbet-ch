# The alarm path is not declarable against the stores

**Finding:** the one-directional rule this repository rests on — *the alarm path may never acquire a
dependency on the observability path* — does not survive into a cluster declaration as a rule. It
survives as an absence of options plus a scan of the strings that remain, and both halves are
necessary: removing either one lets the dependency back in through a route nobody would call a
dependency while writing it.

## Why the rule needs help at all

The host half of this repository cannot break the rule by accident. A probe is a shell snippet on a
systemd timer with no query language, no client library and no cluster; pointing it at a time-series
database would take a deliberate `curl` at a deliberate address.

The cluster half is the opposite. Its declarations sit in one file with the stores, in one option
namespace, rendered into one cluster by one tool. Every address the module derives is *right there*
in the same evaluation. The distance between "an active prober" and "an active prober that asks the
metrics store whether the metrics store is up" is one line, and that line looks reasonable: it reads
as one more endpoint in a list of endpoints.

That is the whole problem. The failure it produces is not an error at all — it is silence. When the
stack is what died, a probe pointed into it does not report an outage: it reports nothing, because
the thing that would have raised the alarm is inside the blast radius. Silence then reads as health,
which is the exact incident this repository was generalized out of.

## What was built

Four levels, and the interesting part is that only two of them are code that runs.

1. **A workload's path is not declarable.** It is a field on the catalogue entry, because whether a
   piece of software decides that something is broken or explains afterwards what happened is a
   property of the software. Nothing in a declaration can move a workload between paths.
2. **There is no `namespace` option anywhere.** A workload's namespace is its path's namespace, and
   the two are separate, defaultless platform options that must differ. The prober cannot be moved
   next to the stores by editing one line, because there is no line.
3. **An alarm-path workload has no option that could name a store.** `reads` exists on dashboards;
   `ships` exists on shippers; a prober has neither. Writing one is "the option does not exist" —
   not a warning, not a review comment, and not something a future contributor can argue with.
4. **Every free-text string an alarm-path workload does carry is scanned** — its probe targets, its
   environment, its arguments — against the derived in-cluster addresses of the observability path,
   that path's own DNS suffix, and its workloads by name where a URL's authority begins. A hit fails
   evaluation quoting the rule.

Levels 1–3 cost nothing to run and cannot drift, because they are shapes rather than checks. Level 4
is the one that catches the reasonable-looking line, and it exists because levels 1–3 only close the
routes that are *about* the stores. `targets.<name>.url` is not about the stores; it is about
whatever a person wants to probe, and it accepts a whole URL by design — a black-box probe reaches a
thing the way anything else reaches it, so there is nothing to derive and nothing to type.

## The two things that were harder than expected

**The needles have to be precise, or the guard is worse than nothing.** The first shape tried was
the observability namespace as a bare substring. That refuses `https://monitoring.example.com/health`
— a perfectly legitimate external target — for a stack whose namespace happens to be called
`monitoring`. A guard that cries wolf is a guard somebody switches off, and switching this one off is
the failure it exists to prevent. What shipped matches only unambiguous shapes: the full derived
in-cluster host, the `.<namespace>.svc` DNS suffix, and `//<name>:` or `//<name>/` — a bare name only
where a URL's authority begins. Every needle is built from the same derivation the dashboards' own
addresses come from, so the guard cannot drift away from the addresses it is guarding.

**A rule enforced only in the model is not enforced.** The eval-time refusal is checked in both
directions — four separate declarations that must fail, one control that must render — and then
checked again on the bytes: the render check greps every object of the alarm path for every
coordinate of the observability path and asserts it finds nothing. Then the guard itself was
mutation-tested: weakening the assertion to `true` makes all four refusals render and turns three
named check assertions red; restoring it turns them green. A guard nobody has watched fire is a
comment.

## What is deliberately not forbidden

The reverse direction. A dashboard reading a prober's status would be the *safe* direction — the
explaining half depending on the deciding half costs nothing when the cluster dies, because both die
together anyway. It is not forbidden here; it is merely unrepresentable, because a prober is not a
store and `reads` resolves only against stores. That asymmetry is the rule stated correctly: this was
never about coupling in general, only about which way it points.

## The limit that no option fixes

The in-cluster prober cannot outlive the cluster it runs in. When the node dies it dies with it and
raises no alarm about anything, including itself. Nothing in the module improves that, and the module
says so in three places rather than one, because the temptation to treat a status page as the alarm
is exactly what the extra namespace, the missing options and the string scan are all defending
against. The half of this repository that runs on each host's own systemd timers, outside every
cluster, is not redundant with this one: one survives, one explains.
