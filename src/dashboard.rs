//! The `nixlock::KioskContent` impl: a live-polled Gatus dashboard. Owns exactly one background
//! thread (the poller) and one `Mutex` (the latest endpoint list) -- `paint` itself never blocks
//! on the network, so a slow/dead Gatus never stalls nixlock's render loop.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nixlock::{Frame, KioskContent};
use tiny_skia::Pixmap;

use crate::model::{self, Endpoint};
use crate::render::{self, Fonts, Header};

const POLL_INTERVAL: Duration = Duration::from_secs(15);

pub struct Dashboard {
    data: Arc<Mutex<Vec<Endpoint>>>,
    fonts: Fonts,
}

impl Dashboard {
    /// Loads `source` once synchronously (so the very first paint has data), then spawns a
    /// background thread that re-polls it every 15s into the shared `Mutex`. A failed poll
    /// (network hiccup, bad JSON) logs to stderr and leaves the previous data in place -- an
    /// endpoint list is more useful stale than replaced by nothing.
    pub fn new(source: String) -> Self {
        let initial = model::load(&source).unwrap_or_else(|e| {
            eprintln!("nixwatch-kiosk: initial load failed: {e}");
            Vec::new()
        });
        eprintln!("nixwatch-kiosk: loaded {} endpoints from {source}", initial.len());

        let data = Arc::new(Mutex::new(initial));
        let poll_data = Arc::clone(&data);
        std::thread::spawn(move || loop {
            std::thread::sleep(POLL_INTERVAL);
            match model::load(&source) {
                Ok(eps) => {
                    *poll_data.lock().unwrap() = eps;
                }
                Err(e) => eprintln!("nixwatch-kiosk: poll failed: {e}"),
            }
        });

        Dashboard { data, fonts: load_fonts() }
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

impl KioskContent for Dashboard {
    fn paint(&mut self, frame: &Frame) -> Vec<u8> {
        let eps = self.data.lock().unwrap();
        let (up, down, unknown) = counts(&eps);
        let (clock, date) = now_strings();
        let hdr = Header { clock: &clock, date: &date, total: eps.len(), up, down, unknown };

        let Some(mut pm) = Pixmap::new(frame.width, frame.height) else {
            // Only None for a zero-sized output -- 0 bytes is still exactly width*height*4.
            return Vec::new();
        };
        render::render_dashboard(&mut pm, &eps, &self.fonts, &hdr);
        pm.data().to_vec()
    }

    fn tick_interval(&self) -> Duration {
        Duration::from_secs(1)
    }
}
