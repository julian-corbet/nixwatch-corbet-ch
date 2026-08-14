// CPU rendering of the dashboard with tiny-skia (shapes) + fontdue (text). Produces a premultiplied
// RGBA Pixmap. The same Pixmap feeds both the --dump PNG and the nixlock kiosk wl_shm surface --
// nixlock owns the surface/commit, this module only ever fills a Pixmap it's handed.

use fontdue::Font;
use tiny_skia::{FillRule, Paint, PathBuilder, Pixmap, Rect, Transform};

use crate::model::Endpoint;

type Rgb = (u8, u8, u8);

// Palette — dark, violet-accented, calm. Never cream.
const BG: Rgb = (0x0d, 0x0d, 0x12);
const CARD: Rgb = (0x16, 0x16, 0x1f);
const CARD_LINE: Rgb = (0x26, 0x26, 0x33);
const TEXT: Rgb = (0xea, 0xea, 0xf2);
const MUTED: Rgb = (0x8a, 0x8a, 0x9c);
const FAINT: Rgb = (0x55, 0x55, 0x66);
const ACCENT: Rgb = (0xa7, 0x8b, 0xfa);
const GREEN: Rgb = (0x3f, 0xd0, 0x68);
const RED: Rgb = (0xf4, 0x53, 0x53);
const AMBER: Rgb = (0xf5, 0x9e, 0x0b);
const HIST_DOWN: Rgb = (0x7a, 0x2a, 0x2a);
const HIST_NONE: Rgb = (0x2a, 0x2a, 0x36);

pub struct Fonts {
    pub sans: Font,
    pub mono: Font,
}

// ---------- primitives ----------

fn solid(c: Rgb, a: u8) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color_rgba8(c.0, c.1, c.2, a);
    p.anti_alias = true;
    p
}

fn fill_rect(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, c: Rgb) {
    if let Some(r) = Rect::from_xywh(x, y, w, h) {
        pm.as_mut()
            .fill_rect(r, &solid(c, 255), Transform::identity(), None);
    }
}

fn rounded_rect(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, rad: f32, c: Rgb) {
    let r = rad.min(w / 2.0).min(h / 2.0);
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.quad_to(x + w, y, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.quad_to(x + w, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.quad_to(x, y + h, x, y + h - r);
    pb.line_to(x, y + r);
    pb.quad_to(x, y, x + r, y);
    pb.close();
    if let Some(path) = pb.finish() {
        pm.as_mut().fill_path(
            &path,
            &solid(c, 255),
            FillRule::Winding,
            Transform::identity(),
            None,
        );
    }
}

fn circle(pm: &mut Pixmap, cx: f32, cy: f32, r: f32, c: Rgb) {
    let mut pb = PathBuilder::new();
    pb.push_circle(cx, cy, r);
    if let Some(path) = pb.finish() {
        pm.as_mut().fill_path(
            &path,
            &solid(c, 255),
            FillRule::Winding,
            Transform::identity(),
            None,
        );
    }
}

#[inline]
fn blend(data: &mut [u8], i: usize, c: Rgb, cov: u8) {
    if cov == 0 {
        return;
    }
    let sa = cov as f32 / 255.0;
    let ia = 1.0 - sa;
    // Pixmap is premultiplied RGBA; text colour is opaque so src_premul = c*sa.
    data[i] = (c.0 as f32 * sa + data[i] as f32 * ia).round() as u8;
    data[i + 1] = (c.1 as f32 * sa + data[i + 1] as f32 * ia).round() as u8;
    data[i + 2] = (c.2 as f32 * sa + data[i + 2] as f32 * ia).round() as u8;
    data[i + 3] = (sa * 255.0 + data[i + 3] as f32 * ia).round() as u8;
}

fn text_width(font: &Font, text: &str, size: f32) -> f32 {
    text.chars()
        .map(|ch| font.metrics(ch, size).advance_width)
        .sum()
}

/// Draw a left-anchored string at baseline `by`. Returns advance width.
fn text(pm: &mut Pixmap, font: &Font, s: &str, x: f32, by: f32, size: f32, c: Rgb) -> f32 {
    let w = pm.width() as i32;
    let h = pm.height() as i32;
    let data = pm.data_mut();
    let mut pen = x;
    for ch in s.chars() {
        let (m, bitmap) = font.rasterize(ch, size);
        let gx = (pen + m.xmin as f32).round() as i32;
        let gy = (by - (m.height as f32 + m.ymin as f32)).round() as i32;
        for row in 0..m.height {
            for col in 0..m.width {
                let cov = bitmap[row * m.width + col];
                let px = gx + col as i32;
                let py = gy + row as i32;
                if px < 0 || py < 0 || px >= w || py >= h {
                    continue;
                }
                blend(data, ((py * w + px) * 4) as usize, c, cov);
            }
        }
        pen += m.advance_width;
    }
    pen - x
}

fn text_right(pm: &mut Pixmap, font: &Font, s: &str, right: f32, by: f32, size: f32, c: Rgb) {
    let w = text_width(font, s, size);
    text(pm, font, s, right - w, by, size, c);
}

fn truncate(font: &Font, s: &str, size: f32, max_w: f32) -> String {
    if text_width(font, s, size) <= max_w {
        return s.to_string();
    }
    let ell = "…";
    let ell_w = text_width(font, ell, size);
    let mut out = String::new();
    let mut w = 0.0;
    for ch in s.chars() {
        let cw = font.metrics(ch, size).advance_width;
        if w + cw + ell_w > max_w {
            break;
        }
        out.push(ch);
        w += cw;
    }
    out.push('…');
    out
}

// ---------- dashboard ----------

pub struct Header<'a> {
    pub clock: &'a str,
    pub date: &'a str,
    pub total: usize,
    pub up: usize,
    pub down: usize,
    pub unknown: usize,
}

pub fn render_dashboard(pm: &mut Pixmap, eps: &[Endpoint], fonts: &Fonts, hdr: &Header) {
    let w = pm.width() as f32;
    let h = pm.height() as f32;
    let pad = 30.0;

    // Background.
    fill_rect(pm, 0.0, 0.0, w, h, BG);

    // ---- header ----
    let hdr_h = 96.0;
    text(pm, &fonts.sans, "corbet", pad, 58.0, 40.0, TEXT);
    let cw = text_width(&fonts.sans, "corbet", 40.0);
    text(pm, &fonts.sans, "status", pad + cw + 14.0, 58.0, 40.0, ACCENT);
    // summary line
    let summary = format!(
        "{} services   ·   {} up   ·   {} down   ·   {} idle",
        hdr.total, hdr.up, hdr.down, hdr.unknown
    );
    text(pm, &fonts.sans, &summary, pad, 82.0, 16.0, MUTED);
    // clock (right)
    text_right(pm, &fonts.mono, hdr.clock, w - pad, 56.0, 42.0, TEXT);
    text_right(pm, &fonts.sans, hdr.date, w - pad, 82.0, 16.0, MUTED);
    // accent divider
    fill_rect(pm, pad, hdr_h, w - 2.0 * pad, 2.0, ACCENT);

    // ---- columns of group cards ----
    let cols = 4usize;
    let col_gap = 20.0;
    let top = hdr_h + 16.0;
    let bottom = h - pad;
    let avail_w = w - 2.0 * pad - (cols as f32 - 1.0) * col_gap;
    let col_w = avail_w / cols as f32;

    let group_head_h = 28.0;
    let row_h = 42.0;
    let card_pad = 10.0;
    let group_gap = 14.0;

    // Biggest groups first so a large group (e.g. PUBLIC=20) claims a column instead of
    // overflowing the bottom when it gets packed late.
    let mut groups = crate::model::grouped(eps);
    groups.sort_by_key(|(_, idxs)| std::cmp::Reverse(idxs.len()));

    // Greedy pack groups into the shortest column.
    let mut col_y = vec![top; cols];
    for (gname, idxs) in &groups {
        let card_h = group_head_h + idxs.len() as f32 * row_h + card_pad;
        // choose shortest column
        let (ci, _) = col_y
            .iter()
            .enumerate()
            .min_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap();
        let x = pad + ci as f32 * (col_w + col_gap);
        let y = col_y[ci];
        if y + 40.0 > bottom {
            continue; // out of room in the spike; skip overflow gracefully
        }

        // card background
        rounded_rect(pm, x, y, col_w, card_h, 12.0, CARD);

        // group header
        let gx = x + card_pad;
        let gtitle = gname.to_uppercase();
        text(pm, &fonts.sans, &gtitle, gx, y + 22.0, 14.0, ACCENT);
        let count = format!("{}", idxs.len());
        text_right(pm, &fonts.mono, &count, x + col_w - card_pad, y + 22.0, 14.0, FAINT);
        // separator under header
        fill_rect(pm, gx, y + group_head_h, col_w - 2.0 * card_pad, 1.0, CARD_LINE);

        // rows
        let inner_w = col_w - 2.0 * card_pad;
        for (ri, &ei) in idxs.iter().enumerate() {
            let e = &eps[ei];
            let ry = y + group_head_h + ri as f32 * row_h;
            let dot_cx = gx + 6.0;
            let dot_cy = ry + 15.0;
            let (dot, _label) = match e.up() {
                Some(true) => (GREEN, "up"),
                Some(false) => (RED, "down"),
                None => (AMBER, "?"),
            };
            circle(pm, dot_cx, dot_cy, 5.0, dot);

            // latency string, right side of the name line
            let lat = match e.latency_ms() {
                Some(ms) if ms >= 1000.0 => format!("{:.2} s", ms / 1000.0),
                Some(ms) => format!("{} ms", ms.round() as i64),
                None => "—".to_string(),
            };
            let lat_w = text_width(&fonts.mono, &lat, 14.0);
            text_right(pm, &fonts.mono, &lat, gx + inner_w, ry + 19.0, 14.0, MUTED);

            // name (truncated to remaining width)
            let name_x = gx + 18.0;
            let name_max = inner_w - 18.0 - lat_w - 10.0;
            let name = truncate(&fonts.sans, &e.name, 16.0, name_max);
            text(pm, &fonts.sans, &name, name_x, ry + 19.0, 16.0, TEXT);

            // history strip (raw recent results, oldest..newest) — rendered, not computed
            let strip_y = ry + 27.0;
            let strip_h = 6.0;
            let strip_x = name_x;
            let strip_w = inner_w - 18.0;
            let hist = e.history(48);
            if hist.is_empty() {
                fill_rect(pm, strip_x, strip_y, strip_w, strip_h, HIST_NONE);
            } else {
                let n = hist.len() as f32;
                let seg = (strip_w / n).max(1.0);
                for (k, ok) in hist.iter().enumerate() {
                    let sx = strip_x + k as f32 * seg;
                    let c = if *ok { GREEN } else { HIST_DOWN };
                    fill_rect(pm, sx, strip_y, (seg - 0.5).max(0.5), strip_h, c);
                }
            }
        }

        col_y[ci] = y + card_h + group_gap;
    }
}
