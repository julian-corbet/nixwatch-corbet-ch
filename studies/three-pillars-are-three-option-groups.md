# Three pillars are three option groups, not one group with a `kind`

**Finding:** metrics, logs and traces are not three instances of one concept. They are three
concepts that happen to share a verb. Declaring them through one option shape with a `kind` field
produces a declaration from which nobody can tell what any of them costs — which is the single
question a person actually asks about a telemetry store, and the one a stack silently answers wrong
until a disk fills.

## The shape that was rejected

The obvious model is one group:

```nix
stores.example = { kind = "metrics"; retention = "30d"; size = "…"; };
```

It is shorter, it is uniform, and it is wrong in a specific way: there is no honest `size`. The
three pillars are priced by three different questions, and a field that tries to be all three is a
field that is accurate for none.

- A **metrics** store is priced by CARDINALITY. Sampling twice as often costs a slightly larger
  compressed column and nothing else; one label whose values are unbounded — a request id, a pod
  name in a crash loop — multiplies the number of series, and each series carries its own index
  entry and its own retention, including long after nothing writes to it.
- A **log** store is priced by BYTES PER DAY. Nothing about the number of things being watched
  predicts it. One component switched to debug logging doubles the bill without a single declaration
  changing anywhere.
- A **trace** store is priced by HOW MUCH IS KEPT AT ALL. A trace is one document per request with a
  span per hop, so at full traffic it outgrows a metrics store covering the same period by orders of
  magnitude — and unlike the other two, the usual answer is not a shorter retention but keeping less
  of it.

That last asymmetry is what settles the argument. Sampling is not a knob the other two pillars have
turned off; it is a knob they must not have. A metrics store that dropped nine samples in ten draws a
graph that is simply wrong, and a log store that dropped nine lines in ten dropped the one line
somebody was looking for. A shared shape either offers `sampling` to all three — where two of them
are traps — or offers it to none, where the pillar that needs it has no way to say so.

## What shipped

Three groups. Each requires `retention`, and each requires one growth term that the other two do not
have as an option at all:

| group | growth term | what it means |
|---|---|---|
| `metrics` | `activeSeries` | how many distinct series exist at once |
| `logs` | `ingestMiBPerDay` | how much arrives per day |
| `traces` | `sampledPercent` | how much of the traffic is kept, 1–100 |

Asking a metrics store how many bytes a day it takes is an unknown option. So is asking a log store
what fraction it samples. There is no `pillar` field anywhere in the catalogue either — the group IS
the pillar, so there is nothing to edit that would turn one into another.

The three land in one read-only report, `nixwatch.cluster.retention`, which is the deliverable this
split exists for: one row per store, saying what it holds, how long, and what drives its size in the
unit that actually drives it. One shared shape would have produced one column that fits none of them.

## Two things the split made possible that were not the goal

**An honest `enforced` flag.** Once each store's retention is stated in one place, it becomes worth
asking whether the number reaches the running process. Some of these programs take retention as a
command-line argument, which the module renders; others read it from their own configuration file,
which the module does not. Both are in the report, and the second is marked `enforced = false`
rather than assumed. A declaration saying thirty days beside a config file saying seven is a lie no
module in this repository can catch, and saying so is better than implying otherwise.

**A refusal with real teeth: retention is passed verbatim.** This repository's own duration grammar
(shared with the host half's `interval` and `deadline`) reads a bare integer as SECONDS. The metrics
store reads a bare number as MONTHS. Two grammars that disagree about the default unit must never be
silently bridged, so a unitless retention is refused rather than translated — `30` is not thirty of
anything until it says which.

And one consequence that runs the other way: an unbacked store makes its declared retention a
fiction. It keeps data until the next restart, not for the period stated three lines above, and
reports itself healthy throughout. That is why backing every directory the catalogue names is
mandatory rather than advisory, and why the refusal's message talks about retention rather than
about volumes.
