# A long initrd must not starve a recurring timer

## Finding

A recurring monotonic systemd timer built from all three of these settings can stop forever
after a reboot:

```ini
OnBootSec=5m
OnUnitActiveSec=5m
Persistent=true
```

The observed sequence was:

1. The timer ran normally before reboot, leaving a persistent timestamp.
2. The next boot spent longer than five minutes before `timers.target` activated the timer.
3. `OnBootSec=5m` was already in the past. The prior boot's persistent timestamp existed, while
   the triggered service had no activation timestamp in the current boot.
4. systemd loaded the timer as `active (elapsed)`, with no next elapse. `OnUnitActiveSec` could
   not seed itself because the service had not run once in this boot.

Every probe behind such a timer stopped at the same boundary. Their subjects remained healthy;
an external dead-man's-switch correctly reported missing heartbeats later. The alarm was not
wrong: the monitoring process itself had died.

## Decision

Seed recurring monotonic checks with `OnActiveSec=<interval>`, then recur with
`OnUnitActiveSec=<interval>`. `OnActiveSec` is relative to timer activation, so pre-userspace boot
duration cannot consume it.

Set `Persistent=false`. systemd documents persistence as a catch-up mechanism for `OnCalendar`
timers. A missed liveness probe cannot be made meaningful by replaying it after power returns: the
only useful fact is present health, which the activation-relative tick obtains.

This changes no health policy. Probe commands, failure deadlines, transition hysteresis, gates,
and delivery stay identical.

## Regression proof

`checks/timer-reboot.nix` boots a real NixOS VM twice. On both boots it delays `timers.target`
beyond the check's interval, and it preserves `/var` between boots. The probe records the kernel
boot ID only when the generated nixwatch timer actually fires. The test requires that record to
match on both boots and requires the timer to remain `waiting`, never `elapsed`.

This is intentionally a runtime proof. An evaluation test also locks the generated settings, but
only a two-boot systemd test exercises the state transition that caused the failure.
