# The nixwatch-kiosk build, shared by flake.nix's `packages` output. Mirrors nixlock's own
# package.nix (same rustPlatform.buildRustPackage shape, same three runtime libraries) because
# this binary links nixlock as a library and inherits its whole runtime link surface.
{ lib, rustPlatform, pkg-config, wayland, libxkbcommon, pam }:

rustPlatform.buildRustPackage {
  pname = "nixwatch-kiosk";
  version = "0.1.0";
  src = ./.;

  # Cargo.lock is committed so this builds fully offline and reproducibly. `nixlock` is a git
  # dependency (not published to crates.io -- both crates are `publish = false`), so
  # importCargoLock needs its fixed-output fetch hash spelled out explicitly here; cargoLock's
  # normal "derive the hash from the lockfile" path only covers registry deps. Re-run
  # `cargo generate-lockfile`/`cargo update -p nixlock` after bumping the pinned rev, and refresh
  # this hash the same way it was minted (see README's build note): start from
  # `lib.fakeHash`, build, and copy the "got: sha256-..." hash nix prints back in.
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "nixlock-0.1.0" = "sha256-XJ9dGlUqC9touUM5wOn+DMDLk9dZGhXf3G+05IBtye8=";
    };
  };

  # pkg-config locates the three C libraries below. bindgenHook is a member of `rustPlatform`
  # itself, NOT a separate callPackage argument -- pam-sys (via pam-client, pulled in
  # transitively through nixlock) runs bindgen against <security/pam_appl.h> at build time, and
  # the hook is what wires up libclang / the right sysroot for that generated FFI.
  nativeBuildInputs = [ pkg-config rustPlatform.bindgenHook ];

  # nixwatch-kiosk itself only talks HTTP (ureq) and draws into a Vec<u8> (tiny-skia/fontdue) --
  # every one of these three comes in transitively through linking nixlock: a Wayland client
  # (wayland), an XKB keymap for the lock-screen fallback on Session outputs (libxkbcommon), and
  # PAM (pam) for the same fallback's unlock prompt.
  buildInputs = [ wayland libxkbcommon pam ];

  meta = {
    description = "Renders the Gatus observability dashboard as nixlock kiosk content";
    homepage = "https://github.com/julian-corbet/nixwatch-corbet-ch";
    license = lib.licenses.mit;
    mainProgram = "nixwatch-kiosk";
    platforms = lib.platforms.linux;
  };
}
