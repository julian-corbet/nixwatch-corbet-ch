//! nixwatch-kiosk's own library half: the Gatus model (`model`) and the CPU dashboard renderer
//! (`render`), kept `nixlock`-free so a future web build can reuse them without pulling in
//! Wayland/PAM at all. The `nixlock::KioskContent` glue that turns the render into live kiosk
//! content lives in `dashboard` -- see `src/bin/nixwatch-kiosk.rs` for the binary that wires it
//! to `nixlock::run`.

pub mod dashboard;
pub mod model;
pub mod render;

pub use dashboard::Dashboard;
pub use model::Endpoint;
pub use render::{Fonts, Header};
