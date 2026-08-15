# nixwatch-frames on the home-manager plane: put the binary on PATH, render its per-host
# config.json, and run it as an ORDINARY graphical-session service.
#
# NOT THE LOCK COMMAND. nixlock is the locker (its own home-manager module,
# `nixlock.homeManagerModules.locker`, owns `nixdesktop.session.idleAndLock.lockCommand`);
# nixwatch-frames is a plain socket CLIENT that streams the Gatus dashboard onto nixlock's kiosk
# display socket (see nixlock's README "Streaming kiosk content" / BEHAVIORS.md DISPLAY-1/
# DISPLAY-2) and has no lock/idle role of its own at all. It needs no `kioskOutputs` and no
# `pamService` either -- the kiosk output's geometry comes from nixlock's own HELLO handshake at
# connect time, and unlock stays entirely nixlock's PAM concern; this module used to carry both
# (back when it linked nixlock in-process) and neither belongs here any more.
#
# GRAPHICAL-SESSION SERVICE, SAME SHAPE nixremote's console/sunshine modules USE. Ordered after
# `graphical-session.target` (so it inherits WAYLAND_DISPLAY/XDG_RUNTIME_DIR the compositor's own
# `--session`-equivalent launch exports into the systemd --user manager's GLOBAL environment) and
# restarted on failure -- nixlock is not always up first (e.g. right after a compositor restart,
# or if nixlock itself is mid-restart), and nixwatch-frames' own connect loop already retries with
# backoff, so a `Restart=on-failure` here only covers nixwatch-frames crashing outright, not the
# ordinary "nixlock isn't listening yet" case (that path never exits at all -- see the binary's
# own header).
#
# MECHANISM PUBLIC, VALUES PRIVATE. This module is the mechanism: it knows HOW to render the
# config and HOW to wire the service. The real value -- which Gatus API this host watches -- is a
# host's own business and lives in the private infra tree, not here. Everything in this file is
# either a neutral default or an example (`https://status.example.com/...`); nothing names a real
# host or URL.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixwatch.kiosk;
in
{
  options.nixwatch.kiosk = {
    enable = lib.mkEnableOption "nixwatch-frames as a graphical-session kiosk feed for nixlock";

    package = lib.mkPackageOption pkgs "nixwatch-frames" { };

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

    socketPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/user/1000/nixlock.sock";
      description = ''
        Path to nixlock's kiosk display Unix socket. `null` (the default)
        leaves it to the binary's own default, `$XDG_RUNTIME_DIR/nixlock.sock`
        -- the same default nixlock's own socket server resolves to, and
        correct as long as both run in the same session (the normal case:
        both are per-session graphical services sharing one
        `$XDG_RUNTIME_DIR`). Only set this to point at a different session's
        socket.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The binary on PATH, for interactive use / a keybind that restarts it.
    home.packages = [ cfg.package ];

    # The value channel this service's own ExecStart cannot carry inline. Keys match the binary's
    # own FileConfig (src/bin/nixwatch-frames.rs): gatus_url, socket_path.
    xdg.configFile."nixwatch-frames/config.json".text = builtins.toJSON (
      { gatus_url = cfg.gatusUrl; }
      // lib.optionalAttrs (cfg.socketPath != null) { socket_path = cfg.socketPath; }
    );

    systemd.user.services.nixwatch-frames = {
      Unit = {
        Description = "nixwatch-frames -- streams the Gatus dashboard to nixlock's kiosk socket";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${cfg.package}/bin/nixwatch-frames";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
