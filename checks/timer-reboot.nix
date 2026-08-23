# checks/timer-reboot.nix
#
# Runtime regression proof for the timer bootstrap contract. The failure this guards requires
# TWO boots: a persistent timer stamp from boot one, then timers.target starting only after a
# short OnBootSec deadline has already passed in boot two. An eval-only assertion can prove the
# unit text, but not that systemd actually schedules it after that sequence.
{ pkgs, nixwatchModule }:

pkgs.testers.runNixOSTest {
  name = "nixwatch-timer-survives-delayed-userspace";

  nodes.machine = { ... }: {
    imports = [ nixwatchModule ];

    nixwatch.enable = true;
    nixwatch.checks.timer-proof = {
      probe = ''
        mkdir -p /var/lib/nixwatch-timer-proof
        cat /proc/sys/kernel/random/boot_id > /var/lib/nixwatch-timer-proof/last-boot
      '';
      interval = "2s";
      deadline = "4s";
      timeout = "1s";
      channel = "unused-on-a-healthy-probe";
    };

    # Model a slow initrd/userspace handoff without making the VM itself interactive: the
    # timer is not activated until four seconds after kernel boot, twice its own interval.
    # AccuracySec keeps this runtime proof fast; RandomizedDelaySec remains the module's real
    # proportional jitter and is therefore still exercised.
    systemd.services.delay-timers-target = {
      description = "Delay timers.target beyond nixwatch's first interval";
      before = [ "timers.target" ];
      wantedBy = [ "timers.target" ];
      serviceConfig.Type = "oneshot";
      script = "sleep 4";
    };
    systemd.timers.nixwatch-check-timer-proof.timerConfig.AccuracySec = "1s";

    system.stateVersion = "25.05";
    virtualisation.memorySize = 512;
  };

  testScript = ''
    start_all()

    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds(
        "cmp -s /var/lib/nixwatch-timer-proof/last-boot /proc/sys/kernel/random/boot_id",
        timeout=30,
    )
    machine.succeed("test \"$(systemctl show -P SubState nixwatch-check-timer-proof.timer)\" = waiting")

    # /var persists, so the second boot begins with the first boot's nixwatch state and would
    # also begin with a systemd persistent stamp if the module ever reintroduced one. The
    # probe overwrites last-boot only after the timer really fires in this boot.
    # Power down cleanly and start the same persistent VM disk again. The test driver's
    # reboot() helper requires allow_reboot=True at VM creation time; shutdown()/start()
    # gives us the same two-boot state transition without depending on that transport mode.
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds(
        "cmp -s /var/lib/nixwatch-timer-proof/last-boot /proc/sys/kernel/random/boot_id",
        timeout=30,
    )
    machine.succeed("test \"$(systemctl show -P SubState nixwatch-check-timer-proof.timer)\" = waiting")
  '';
}
