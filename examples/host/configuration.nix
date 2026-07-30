# examples/host/configuration.nix
#
# A minimal composed system exercising every implemented nixwatch option, used by
# `nix flake check`'s composed-host check (checks/default.nix's `modules-evaluate`). Every
# value here is generic and placeholder -- no real hostname, address, or topic ever belongs
# in this repo (see README's "no private context" note).
#
# Deliberately does NOT import nixpush at all: this is the graceful, ungated path this
# module's own README documents (config.nixpush.enable or false -> false, so the `channel`
# assertion never fires) -- proof that a host can adopt nixwatch on its own, before or
# without ever wiring up nixpush. checks/assertions.nix's own inline nixpush stub is what
# exercises the "channel must exist" half of that assertion; this example is the OTHER half,
# a real host that has no nixpush at all.
{ ... }:
{
  nixwatch.enable = true;

  nixwatch.checks = {
    # A plain active probe: reachability of some example internal service, checked every
    # minute, allowed to be unhealthy for up to 5 minutes before it pages.
    example-api = {
      probe = ''curl -sf -o /dev/null --max-time 10 http://example-api.internal/healthz'';
      interval = "1m";
      deadline = "5m";
      severity = "critical";
      channel = "ops-page";
      title = "example API";
    };

    # A shared precondition: if egress itself is down, example-api failing is not new
    # information -- it is gated below instead of paging independently.
    example-egress = {
      probe = ''curl -sf -o /dev/null --max-time 10 https://example.org/generate_204'';
      interval = "1m";
      deadline = "3m";
      severity = "warning";
      channel = "ops-noise";
      title = "example egress";
    };

    # Depends on egress in spirit (its own probe reaches the same path) -- gatedBy freezes
    # this check's tick while example-egress itself reads DOWN, so an egress outage pages
    # once (at example-egress), not twice.
    example-external-api = {
      probe = ''curl -sf -o /dev/null --max-time 10 https://api.example.org/status'';
      interval = "2m";
      deadline = "10m";
      severity = "warning";
      channel = "ops-noise";
      gatedBy = "example-egress";
      title = "example external API";
    };

    # The dead-man's-switch shape: an unconditional "still alive" beacon, on its own
    # schedule, dispatched through a channel a receiver with its own missed-heartbeat timeout
    # (or a human) is expected to be watching -- see the module README for why nixwatch
    # cannot enforce that expectation itself.
    example-watchdog-alive = {
      kind = "heartbeat";
      interval = "5m";
      deadline = "15m";
      severity = "info";
      channel = "ops-noise";
      title = "example watchdog heartbeat";
    };
  };

  # ── Stubs NixOS demands of any bootable system ───────────────────────────
  # tmpfs on / could never boot a real machine, which is the point: this
  # config exists to type-check the module, not to describe hardware.
  fileSystems."/" = {
    device = "nodev";
    fsType = "tmpfs";
  };

  boot.loader.grub = {
    enable = true;
    devices = [ "nodev" ];
  };

  networking.hostName = "example-node";
  system.stateVersion = "25.05";
}
