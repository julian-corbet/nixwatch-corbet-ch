# studies

Written-up findings: things that were tried in [`../experiments/`](../experiments/README.md),
worked (or failed instructively), and are worth recording properly — with the reasoning, not
just the result.

A study earns its place here once it changed a decision in the main project. See the main
[README](../README.md) for the project itself.

| File | Finding |
|---|---|
| `the-alarm-path-is-not-declarable-against-the-stores.md` | The one-directional rule does not survive into a cluster declaration as a rule — it survives as an absence of options plus a scan of the strings that remain, and both halves are needed. Produced the path field the catalogue owns, the two namespaces, the absence of `reads`/`ships`/`namespace` on a prober, the free-text scan against derived coordinates, and the mutation test that watches the guard fire. |
| `three-pillars-are-three-option-groups.md` | Metrics, logs and traces are priced by three different questions, so a shared option shape has no honest size field — and sampling is not a knob the other two turned off, it is one they must not have. Produced the three separate groups, the three required growth terms, the `nixwatch.cluster.retention` report with its honest `enforced` flag, and the refusal of a unitless retention. |
| `an-option-nothing-renders-is-never-checked.md` | A required option with a constrained type is enforced only when something forces it, and only FAILING assertions have their messages forced — so a trace store keeping zero percent of the traffic rendered green. Produced the growth-term assertion that exists for what it forces rather than what it compares, and a rule for the next module in this family: ask what forces each option, and never rely on a message to do it. |
| `long-initrd-must-not-starve-a-timer.md` | A recurring monotonic timer can become permanently `active (elapsed)` after a boot whose pre-userspace phase outlasts `OnBootSec`, when a persistent stamp supplies stale cross-boot state and `OnUnitActiveSec` has no current-boot anchor. Produced activation-relative seeding, no calendar persistence on monotonic checks, and a two-boot VM regression proof. |

Nothing from the ALARM half has closed yet — see
[`../experiments/README.md`](../experiments/README.md) for what is still open there, including the
two design choices (time-based staleness instead of a tick count, un-hysteresized recovery by
default) that most directly diverge from the implementation this repository generalizes.
