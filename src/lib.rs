//! nixwatch-frames' own library half: the Gatus model (`model`), the CPU dashboard renderer
//! (`render`), and the live-polled `Dashboard` (`dashboard`) that combines them -- all kept
//! entirely `nixlock`-free (no Wayland, no PAM), so a future web build can reuse them just as
//! easily as `src/bin/nixwatch-frames.rs` does. That binary is the only thing in this crate that
//! turns a rendered `Dashboard` frame into nixlock's kiosk-socket wire protocol.

pub mod dashboard;
pub mod model;
pub mod render;

pub use dashboard::Dashboard;
pub use model::Endpoint;
pub use render::{Fonts, Header};
