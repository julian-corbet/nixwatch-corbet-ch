// nixwatch-frames [--dump <out.png>] [--source <file|url>]
//
// A socket CLIENT for nixlock's kiosk display socket (nixlock's own `crate::socket`, documented
// in its README's "Streaming kiosk content" and BEHAVIORS.md's DISPLAY-1/DISPLAY-2). It connects
// to `$XDG_RUNTIME_DIR/nixlock.sock` (retrying with backoff if nixlock is not up yet OR its kiosk
// surface has not been configured yet), reads the HELLO (magic + kiosk geometry), then renders the
// Gatus dashboard at that size and streams it as premultiplied-RGBA frames roughly once a second,
// and promptly after a data refresh. Pure socket client: no Wayland, no PAM, no nixlock link at
// all -- see `src/dashboard.rs`'s own header.
//
// Config precedence per field: $XDG_CONFIG_HOME/nixwatch-frames/config.json (falling back to
// ~/.config/nixwatch-frames/config.json) -- fields `gatus_url` / `socket_path` -- then the
// GATUS_URL / NIXLOCK_SOCKET env vars, then a neutral built-in default.
//
// --dump renders exactly one frame headlessly to a PNG (tiny_skia::Pixmap::save_png) through the
// same Dashboard::render the live path uses -- no socket connection needed, so it verifies the
// render (fonts, layout, Gatus parsing) in CI or over SSH.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use nixwatch::Dashboard;
use serde::Deserialize;

// A neutral placeholder -- the real URL is a per-host runtime config value, never baked in here.
const DEFAULT_GATUS_URL: &str = "https://status.example.com/api/v1/endpoints/statuses";
const MAGIC: &[u8; 8] = b"NIXLOCK1";

// Frame cadence: stream at least once a second, and promptly (next tick) after the poller in
// Dashboard actually refreshes -- see Dashboard::version.
const MIN_FRAME_INTERVAL: Duration = Duration::from_millis(200);
const MAX_FRAME_INTERVAL: Duration = Duration::from_secs(1);

// Reconnect backoff: nixlock may not be up yet (or may be mid-restart) when this starts.
const INITIAL_BACKOFF: Duration = Duration::from_millis(250);
const MAX_BACKOFF: Duration = Duration::from_secs(5);

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    gatus_url: Option<String>,
    socket_path: Option<String>,
}

fn config_path() -> Option<std::path::PathBuf> {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
        .ok()?;
    Some(base.join("nixwatch-frames").join("config.json"))
}

fn load_file_config() -> FileConfig {
    let Some(path) = config_path() else {
        return FileConfig::default();
    };
    let Ok(bytes) = std::fs::read(&path) else {
        return FileConfig::default();
    };
    match serde_json::from_slice(&bytes) {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("nixwatch-frames: {}: {e} (ignoring)", path.display());
            FileConfig::default()
        }
    }
}

/// `--dump` needs only this -- resolving a socket path it will never dial is pointless work with
/// a real failure mode (a bare `nix run`/CI/SSH invocation with no `$XDG_RUNTIME_DIR` at all would
/// otherwise fail `--dump` for a reason that has nothing to do with what `--dump` actually does).
fn resolve_gatus_url(file: &FileConfig) -> String {
    file.gatus_url
        .clone()
        .or_else(|| std::env::var("GATUS_URL").ok())
        .unwrap_or_else(|| DEFAULT_GATUS_URL.to_string())
}

struct Resolved {
    gatus_url: String,
    socket_path: PathBuf,
}

fn resolve_config() -> Resolved {
    let file = load_file_config();
    let gatus_url = resolve_gatus_url(&file);
    let socket_path = file
        .socket_path
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("NIXLOCK_SOCKET").map(PathBuf::from))
        .or_else(|| {
            std::env::var_os("XDG_RUNTIME_DIR").map(|d| PathBuf::from(d).join("nixlock.sock"))
        })
        .unwrap_or_else(|| {
            // Same channel nixlock's own default resolves against (its README/socket module) --
            // if this session has neither a configured socket_path nor XDG_RUNTIME_DIR, there is
            // no sane guess left to make; fail loudly rather than dial a made-up path.
            eprintln!(
                "nixwatch-frames: no socket_path configured and $XDG_RUNTIME_DIR is unset -- \
                 cannot locate nixlock's kiosk socket"
            );
            std::process::exit(1);
        });
    Resolved {
        gatus_url,
        socket_path,
    }
}

fn arg(flag: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter()
        .position(|x| x == flag)
        .and_then(|i| a.get(i + 1).cloned())
}

fn main() {
    if let Some(out) = arg("--dump") {
        let gatus_url = resolve_gatus_url(&load_file_config());
        let source = arg("--source").unwrap_or(gatus_url);
        let dashboard = Dashboard::new(source);

        let (w, h) = (1920u32, 1080u32);
        let pm = dashboard
            .render(w, h)
            .expect("Dashboard::render returns Some for a nonzero size");
        pm.save_png(&out).expect("save png");
        eprintln!("nixwatch-frames: dumped {w}x{h} -> {out}");
        return;
    }

    let resolved = resolve_config();
    eprintln!(
        "nixwatch-frames: gatus_url={} socket={}",
        resolved.gatus_url,
        resolved.socket_path.display()
    );
    let dashboard = Dashboard::new(resolved.gatus_url);
    run_client(&resolved.socket_path, &dashboard);
}

/// Connect-stream-reconnect forever. A disconnect (nixlock restarted, socket vanished, geometry
/// went to 0x0) is not fatal -- it just goes back to the top of this loop with backoff.
fn run_client(socket_path: &std::path::Path, dashboard: &Dashboard) {
    run_client_with(socket_path, dashboard, std::thread::sleep, |_, _| false);
}

/// The production client never stops. The two injected callbacks make the reconnect state machine
/// behavior-testable without weakening that contract: tests can observe a retry, suppress the real
/// sleep, and stop after a fake nixlock has received the eventual frame.
fn run_client_with<S, F>(
    socket_path: &std::path::Path,
    dashboard: &Dashboard,
    mut sleep: S,
    mut stop_after: F,
) where
    S: FnMut(Duration),
    F: FnMut(usize, RetryReason) -> bool,
{
    let mut backoff = INITIAL_BACKOFF;
    let mut attempts = 0usize;
    loop {
        let reason = match connect_and_stream(socket_path, dashboard) {
            Ok(Exit::GeometryPending) => {
                eprintln!(
                    "nixwatch-frames: nixlock kiosk geometry is not configured yet (0x0); reconnecting"
                );
                RetryReason::GeometryPending
            }
            Ok(Exit::Disconnected) => {
                eprintln!("nixwatch-frames: disconnected from nixlock; reconnecting");
                backoff = INITIAL_BACKOFF; // a connection that actually worked resets the backoff
                RetryReason::Disconnected
            }
            Err(e) => {
                eprintln!(
                    "nixwatch-frames: connect to {} failed: {e}",
                    socket_path.display()
                );
                RetryReason::ConnectFailed
            }
        };
        attempts += 1;
        if stop_after(attempts, reason) {
            return;
        }
        sleep(backoff);
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RetryReason {
    /// A real nixlock accepted the connection, but its kiosk surface had not received its first
    /// configure yet. This is a startup race, never proof that the host permanently has no kiosk.
    GeometryPending,
    /// A nonzero-geometry stream ended after at least one successful handshake.
    Disconnected,
    /// The socket could not be connected/read or did not speak the nixlock protocol.
    ConnectFailed,
}

enum Exit {
    /// HELLO reported 0x0. A host with no configured kiosk and a just-started nixlock whose kiosk
    /// surface has not received its first configure are indistinguishable on the wire. Reconnect
    /// with capped backoff: that converges the real startup race and never burns CPU in either case.
    GeometryPending,
    /// The stream ended (nixlock exited/restarted, or rejected a frame hard enough to close it).
    Disconnected,
}

fn connect_and_stream(
    socket_path: &std::path::Path,
    dashboard: &Dashboard,
) -> std::io::Result<Exit> {
    let mut stream = UnixStream::connect(socket_path)?;

    let mut hello = [0u8; 20]; // 8 magic + 4 width + 4 height + 4 scale
    stream.read_exact(&mut hello)?;
    if &hello[0..8] != MAGIC {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "HELLO magic mismatch -- not nixlock's kiosk socket",
        ));
    }
    let width = u32::from_le_bytes(hello[8..12].try_into().unwrap());
    let height = u32::from_le_bytes(hello[12..16].try_into().unwrap());
    let scale = u32::from_le_bytes(hello[16..20].try_into().unwrap());
    eprintln!("nixwatch-frames: connected; kiosk geometry {width}x{height} (scale {scale})");

    if width == 0 || height == 0 {
        return Ok(Exit::GeometryPending);
    }

    let mut last_version = None::<u64>;
    let mut last_sent = Instant::now() - MAX_FRAME_INTERVAL; // send the first frame immediately
    loop {
        let version = dashboard.version();
        let due = last_sent.elapsed() >= MAX_FRAME_INTERVAL;
        let refreshed = last_version != Some(version);
        if due || refreshed {
            let Some(pm) = dashboard.render(width, height) else {
                std::thread::sleep(MIN_FRAME_INTERVAL);
                continue;
            };
            if let Err(e) = write_frame(&mut stream, width, height, pm.data()) {
                // A write failure means the connection is gone (nixlock closed it, e.g. a newer
                // client took over, or nixlock itself exited) -- go back to reconnect/backoff.
                eprintln!("nixwatch-frames: write failed: {e}");
                return Ok(Exit::Disconnected);
            }
            last_version = Some(version);
            last_sent = Instant::now();
        }
        std::thread::sleep(MIN_FRAME_INTERVAL);
    }
}

fn write_frame(
    stream: &mut UnixStream,
    width: u32,
    height: u32,
    rgba: &[u8],
) -> std::io::Result<()> {
    stream.write_all(&width.to_le_bytes())?;
    stream.write_all(&height.to_le_bytes())?;
    stream.write_all(rgba)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::net::Shutdown;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn write_hello(stream: &mut UnixStream, width: u32, height: u32, scale: u32) {
        stream.write_all(MAGIC).unwrap();
        stream.write_all(&width.to_le_bytes()).unwrap();
        stream.write_all(&height.to_le_bytes()).unwrap();
        stream.write_all(&scale.to_le_bytes()).unwrap();
    }

    /// Reproduces the production failure exactly: nixwatch connects in the narrow interval after
    /// nixlock starts listening but before the compositor configures the kiosk surface. The first
    /// HELLO is therefore 0x0. That must cause a bounded-backoff reconnect, not a successful process
    /// exit; once the second connection reports real geometry, a complete frame must arrive.
    #[test]
    fn zero_geometry_reconnects_then_streams_after_surface_configuration() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let test_dir = std::env::temp_dir().join(format!(
            "nixwatch-frames-startup-race-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&test_dir).unwrap();
        let socket_path = test_dir.join("nixlock.sock");
        let source_path = test_dir.join("gatus.json");
        fs::write(&source_path, b"[]").unwrap();

        let listener = UnixListener::bind(&socket_path).unwrap();
        let received_frame = Arc::new(AtomicBool::new(false));
        let server_received_frame = Arc::clone(&received_frame);
        let server = thread::spawn(move || {
            let (mut before_configure, _) = listener.accept().unwrap();
            write_hello(&mut before_configure, 0, 0, 0);
            drop(before_configure);

            let (mut after_configure, _) = listener.accept().unwrap();
            let (width, height) = (64u32, 32u32);
            write_hello(&mut after_configure, width, height, 1);

            let mut header = [0u8; 8];
            after_configure.read_exact(&mut header).unwrap();
            assert_eq!(u32::from_le_bytes(header[0..4].try_into().unwrap()), width);
            assert_eq!(u32::from_le_bytes(header[4..8].try_into().unwrap()), height);

            let mut rgba = vec![0u8; width as usize * height as usize * 4];
            after_configure.read_exact(&mut rgba).unwrap();
            assert!(
                rgba.iter().any(|byte| *byte != 0),
                "renderer sent an empty frame"
            );
            server_received_frame.store(true, Ordering::SeqCst);
            after_configure.shutdown(Shutdown::Both).unwrap();
        });

        let dashboard = Dashboard::new(source_path.to_string_lossy().into_owned());
        let mut retries = Vec::new();
        let mut sleeps = Vec::new();
        run_client_with(
            &socket_path,
            &dashboard,
            |duration| sleeps.push(duration),
            |attempt, reason| {
                retries.push(reason);
                attempt >= 2
            },
        );

        server.join().unwrap();
        assert!(received_frame.load(Ordering::SeqCst));
        assert_eq!(
            retries,
            vec![RetryReason::GeometryPending, RetryReason::Disconnected]
        );
        assert_eq!(sleeps, vec![INITIAL_BACKOFF]);

        fs::remove_dir_all(test_dir).unwrap();
    }
}
