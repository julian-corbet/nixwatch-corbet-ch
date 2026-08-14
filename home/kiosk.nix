# nixwatch-kiosk on the home-manager plane: put the binary on PATH, render its per-host
# config.json, and (optionally) wire it in as the session's idle/lock command.
#
# MECHANISM PUBLIC, VALUES PRIVATE. This module is the mechanism: it knows HOW to render the
# config and HOW to hand the lock command to the session. The real values -- which Gatus API
# this host watches, which physical connector is the kiosk output -- are a host's own business
# and live in the private infra tree, not here (there they come from
# `nixdisplay.roles.kioskOutputs`, catalogued per host). Everything in this file is either a
# neutral default or an example (`https://status.example.com/...`, `DP-3`); nothing names a
# real host, URL, or output.
#
# BARE BINARY NAME, NOT "-f". `nixdesktop.session.idleAndLock.lockCommand` is set to the bare
# string `nixwatch-kiosk` -- the session layer's swayidle wiring appends `-f` itself when it
# invokes the configured lock command (the same COMPAT-1 contract nixlock's own locker.nix
# documents), so this module must never bake a flag onto the value it writes there.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixwatch.kiosk;
in
{
  options.nixwatch.kiosk = {
    enable = lib.mkEnableOption "nixwatch-kiosk as this session's screen locker";

    package = lib.mkPackageOption pkgs "nixwatch-kiosk" { };

    gatusUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        The Gatus observability API URL this kiosk polls for endpoint statuses
        (its `/api/v1/endpoints/statuses` JSON). A fact about this host's
        observability stack, not a default this module should invent -- there
        is no built-in fallback here (the binary itself falls back to a
        neutral placeholder if this is ever left unset upstream of it).
      '';
    };

    kioskOutputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "DP-3" ];
      description = ''
        Connector names of the outputs that stay a LIVE Gatus dashboard while
        every other output is a lock screen -- the same wlroots connector
        spelling (`DP-3`, `HDMI-A-1`, `eDP-1`) nixlock's own `kioskOutputs`
        expects, since this binary is the `KioskContent` nixlock renders on
        them. Empty means every output is a lock screen, no kiosk role.
      '';
    };

    pamService = lib.mkOption {
      type = lib.types.str;
      default = "nixlock";
      description = ''
        The PAM service nixlock authenticates against when this kiosk hands
        back to the lock screen. Must match a `security.pam.services.<name>`
        on the host -- same contract as nixlock's own `pamService` option,
        and normally the same value.
      '';
    };

    wireLockCommand = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to set the session's shared idle/lock command to the bare
        name `nixwatch-kiosk`. Default true, which is the fleet path: the
        session layer (nixdesktop) assembles swayidle as `nixwatch-kiosk -f`,
        which needs the bare process name (COMPAT-1). This WRITES
        `nixdesktop.session.idleAndLock.lockCommand`, so it requires that
        module to be composed into the same home-manager evaluation; a
        consumer who wires swayidle by hand sets this to false to avoid
        defining an option that then does not exist.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # The binary on PATH -- swayidle, `pkill`, and a compositor keybind all
      # invoke it by the bare name `nixwatch-kiosk`.
      home.packages = [ cfg.package ];

      # The value channel swayidle cannot reach (it invokes the lock command
      # as a black box, `<lockCommand> -f`, nothing more). Keys match the
      # binary's own FileConfig (src/bin/nixwatch-kiosk.rs): gatus_url,
      # kiosk_outputs, pam_service.
      xdg.configFile."nixwatch-kiosk/config.json".text = builtins.toJSON {
        gatus_url = cfg.gatusUrl;
        kiosk_outputs = cfg.kioskOutputs;
        pam_service = cfg.pamService;
      };
    }

    # The session wiring, guarded so this module does not force nixdesktop on
    # a standalone consumer (see `wireLockCommand`). `mkDefault` so a host
    # that deliberately runs some other locker for one session can still
    # override the command without a conflict.
    (lib.mkIf cfg.wireLockCommand {
      nixdesktop.session.idleAndLock.lockCommand = lib.mkDefault "nixwatch-kiosk";
    })
  ]);
}
