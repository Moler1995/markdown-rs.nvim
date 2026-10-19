//! Ported from `markdown-reader` revision 4f0f635 (2026-10-14), MIT, (c) leboiko.
//!
//! Saturating numeric casts.
//!
//! The layout code counts things as `usize` and addresses display coordinates
//! as `u16`/`u32`. Every conversion between them has to saturate rather than
//! wrap, so they live here instead of being open-coded at each call site.

/// `usize` to `u32`, saturating at [`u32::MAX`].
#[must_use]
pub fn u32_sat(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// `usize` to `u16`, saturating at [`u16::MAX`].
#[must_use]
pub fn u16_sat(value: usize) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}
