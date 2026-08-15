//! The live-polled Gatus dashboard render. Owns exactly one background thread (the poller) and one
//! `Mutex` (the latest endpoint list) -- `render` itself never blocks on the network, so a
//! slow/dead Gatus never stalls the frame-streaming loop in `src/bin/nixwatch-frames.rs`.
//!
//! Deliberately nixlock-free: this is a plain `(state, size) -> Pixmap` renderer, with no
//! knowledge of Wayland, PAM, or nixlock's socket protocol at all -- `nixwatch-frames` is the only
//! thing that turns a rendered `Pixmap` into wire-protocol frames.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tiny_skia::Pixmap;

use crate::model::{self, Endpoint};
use crate::render::{self, Fonts, Header};

const POLL_INTERVAL: Duration = Duration::from_secs(15);

pub struct Dashboard {
    data: Arc<Mutex<Vec<Endpoint>>>,
    /// Bumped every time the poller replaces `data` with a new successful read. `nixwatch-frames`
    /// polls this (cheap: one atomic load) to stream a frame promptly after a real data refresh,
    /// rather than only ever on its own fixed cadence.
    version: Arc<AtomicU64>,
    fonts: Fonts,
}

impl Dashboard {
    /// Loads `source` once synchronously (so the very first render has data), then spawns a
    /// background thread that re-polls it every 15s into the shared `Mutex`. A failed poll
    /// (network hiccup, bad JSON) logs to stderr and leaves the previous data in place -- an
    /// endpoint list is more useful stale than replaced by nothing.
    pub fn new(source: String) -> Self {
        let initial = model::load(&source).unwrap_or_else(|e| {
            eprintln!("nixwatch-frames: initial load failed: {e}");
            Vec::new()
        });
        eprintln!("nixwatch-frames: loaded {} endpoints from {source}", initial.len());

        let data = Arc::new(Mutex::new(initial));
        let version = Arc::new(AtomicU64::new(0));
        let poll_data = Arc::clone(&data);
        let poll_version = Arc::clone(&version);
        std::thread::spawn(move || loop {
            std::thread::sleep(POLL_INTERVAL);
            match model::load(&source) {
                Ok(eps) => {
                    *poll_data.lock().unwrap() = eps;
                    poll_version.fetch_add(1, Ordering::Relaxed);
                }
                Err(e) => eprintln!("nixwatch-frames: poll failed: {e}"),
            }
        });

        Dashboard { data, version, fonts: load_fonts() }
    }

    /// Current data version -- compare against a previously observed value to detect a refresh.
    pub fn version(&self) -> u64 {
        self.version.load(Ordering::Relaxed)
    }

    /// Render one frame at `width` x `height` as a premultiplied-RGBA `Pixmap`. `None` only for a
    /// zero-sized request (`tiny_skia::Pixmap::new` itself refuses that).
    pub fn render(&self, width: u32, height: u32) -> Option<Pixmap> {
        let eps = self.data.lock().unwrap();
        let (up, down, unknown) = counts(&eps);
        let (clock, date) = now_strings();
        let hdr = Header { clock: &clock, date: &date, total: eps.len(), up, down, unknown };

        let mut pm = Pixmap::new(width, height)?;
        render::render_dashboard(&mut pm, &eps, &self.fonts, &hdr);
        Some(pm)
    }
}

fn load_fonts() -> Fonts {
    let settings = fontdue::FontSettings::default();
    let sans = fontdue::Font::from_bytes(&include_bytes!("../assets/Inter.ttf")[..], settings)
        .expect("load Inter");
    let mono = fontdue::Font::from_bytes(&include_bytes!("../assets/Mono.ttf")[..], settings)
        .expect("load Mono");
    Fonts { sans, mono }
}

fn counts(eps: &[Endpoint]) -> (usize, usize, usize) {
    let mut up = 0;
    let mut down = 0;
    let mut unk = 0;
    for e in eps {
        match e.up() {
            Some(true) => up += 1,
            Some(false) => down += 1,
            None => unk += 1,
        }
    }
    (up, down, unk)
}

fn now_strings() -> (String, String) {
    let now = chrono::Local::now();
    (now.format("%H:%M:%S").to_string(), now.format("%a %d %b %Y").to_string())
}
