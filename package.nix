# The nixwatch-frames build, shared by flake.nix's `packages` output. A pure Rust socket client
# now (no nixlock link, no Wayland/PAM), so this is a plain rustPlatform build with no C library
# link surface and no bindgen -- unlike nixwatch-kiosk before it (see this repo's git history and
# nixlock's own experiments/README.md #003 for what changed and why).
{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nixwatch-frames";
  version = "0.1.1";
  src = ./.;

  # Cargo.lock is committed so this builds fully offline and reproducibly -- importCargoLock
  # derives its own fixed-output fetch hash straight from the lockfile (every dependency here is
  # an ordinary crates.io registry dep now, so there is no outputHashes entry to maintain the way
  # the old nixlock git dependency needed one).
  cargoLock.lockFile = ./Cargo.lock;

  # One crate: a [lib] (the Gatus model + CPU dashboard renderer + the live-polled `Dashboard`,
  # all nixlock-free -- see src/lib.rs) plus a default [[bin]] named nixwatch-frames (the socket
  # client that streams `Dashboard`'s renders to nixlock's kiosk socket). buildRustPackage's
  # default checkPhase runs `cargo test`; only the binary is installed.
  meta = {
    description = "Streams the Gatus observability dashboard to nixlock's kiosk display socket";
    homepage = "https://github.com/julian-corbet/nixwatch-corbet-ch";
    license = lib.licenses.mit;
    mainProgram = "nixwatch-frames";
    platforms = lib.platforms.linux;
  };
}
