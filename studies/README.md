# studies

Written-up findings: things that were tried in [`../experiments/`](../experiments/README.md),
worked (or failed instructively), and are worth recording properly — with the reasoning, not
just the result.

A study earns its place here once it changed a decision in the main project. See the main
[README](../README.md) for the project itself.

Nothing has closed yet — nixwatch v1 is a fresh generalization out of one private
implementation's own systemd-timer watchdog engine, not yet run against a second, independent
deployment. See [`../experiments/README.md`](../experiments/README.md) for what's currently
open, including the two design choices (time-based staleness instead of a tick count,
un-hysteresized recovery) that most directly diverge from the implementation this module
generalizes.
