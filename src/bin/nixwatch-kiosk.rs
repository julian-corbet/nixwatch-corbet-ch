// nixwatch-kiosk [--dump <out.png>] [--source <file|url>]
//
// Default: runs as a nixlock `KioskContent` process, rendering the Gatus dashboard live on the
// configured kiosk outputs. Config precedence per field: $XDG_CONFIG_HOME/nixwatch-kiosk/
// config.json (falling back to ~/.config/nixwatch-kiosk/config.json) -- fields `gatus_url` /
// `kiosk_outputs` / `pam_service` -- then the GATUS_URL / KIOSK_OUTPUT / PAM_SERVICE env vars,
// then a neutral built-in default.
//
// --dump renders exactly one frame headlessly to a PNG (tiny_skia::Pixmap::save_png) through the
// same Dashboard::paint the live path uses -- no Wayland connection needed, so it verifies the
// render (fonts, layout, Gatus parsing) in CI or over SSH.

use nixlock::{AuthState, AuthView, Config, Frame, KioskContent, OutputRole};
use nixwatch::Dashboard;
use serde::Deserialize;
use tiny_skia::{IntSize, Pixmap};

// A neutral placeholder -- the real URL is a per-host runtime config value, never baked in here.
const DEFAULT_GATUS_URL: &str = "https://status.example.com/api/v1/endpoints/statuses";
const DEFAULT_PAM_SERVICE: &str = "nixlock";

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    gatus_url: Option<String>,
    kiosk_outputs: Option<Vec<String>>,
    pam_service: Option<String>,
}

fn config_path() -> Option<std::path::PathBuf> {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
        .ok()?;
    Some(base.join("nixwatch-kiosk").join("config.json"))
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
            eprintln!("nixwatch-kiosk: {}: {e} (ignoring)", path.display());
            FileConfig::default()
        }
    }
}

struct Resolved {
    gatus_url: String,
    kiosk_outputs: Vec<String>,
    pam_service: String,
}

fn resolve_config() -> Resolved {
    let file = load_file_config();
    let gatus_url = file
        .gatus_url
        .or_else(|| std::env::var("GATUS_URL").ok())
        .unwrap_or_else(|| DEFAULT_GATUS_URL.to_string());
    let kiosk_outputs = file
        .kiosk_outputs
        .or_else(|| std::env::var("KIOSK_OUTPUT").ok().map(|o| vec![o]))
        .unwrap_or_default();
    let pam_service = file
        .pam_service
        .or_else(|| std::env::var("PAM_SERVICE").ok())
        .unwrap_or_else(|| DEFAULT_PAM_SERVICE.to_string());
    Resolved { gatus_url, kiosk_outputs, pam_service }
}

fn arg(flag: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == flag).and_then(|i| a.get(i + 1).cloned())
}

fn main() {
    if let Some(out) = arg("--dump") {
        let resolved = resolve_config();
        let source = arg("--source").unwrap_or(resolved.gatus_url);
        let mut dashboard = Dashboard::new(source);

        let (w, h) = (1920u32, 1080u32);
        let frame = Frame {
            role: OutputRole::Kiosk,
            output_name: "dump",
            width: w,
            height: h,
            auth: AuthView { state: AuthState::Idle(0), caps_lock: false },
        };
        let raw = dashboard.paint(&frame);
        let size = IntSize::from_wh(w, h).expect("nonzero dump size");
        let pm = Pixmap::from_vec(raw, size).expect("paint() returns a premultiplied w*h*4 RGBA buffer");
        pm.save_png(&out).expect("save png");
        eprintln!("nixwatch-kiosk: dumped {w}x{h} -> {out}");
        return;
    }

    let resolved = resolve_config();
    eprintln!(
        "nixwatch-kiosk: gatus_url={} kiosk_outputs={:?} pam_service={}",
        resolved.gatus_url, resolved.kiosk_outputs, resolved.pam_service
    );
    let dashboard = Dashboard::new(resolved.gatus_url);
    let config = Config {
        kiosk_outputs: resolved.kiosk_outputs,
        pam_service: resolved.pam_service,
        username: None,
    };
    if let Err(e) = nixlock::run(config, dashboard) {
        eprintln!("nixwatch-kiosk: {e}");
        std::process::exit(1);
    }
}
