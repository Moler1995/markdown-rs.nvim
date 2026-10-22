//! The dependency policy, made checkable.
//!
//! `engine/Cargo.toml` says the dependency set is deliberately small. That is
//! a claim about a file, so a test is the only honest way to keep it true: the
//! next person who adds a crate has to add it here too, with a reason, rather
//! than discovering the rule after the review.
//!
//! `image` is on the list on purpose — rendering a markdown image as
//! character cells means decoding it somewhere — but the list is the whole
//! sanctioned set, not a starting point.

use std::collections::BTreeSet;

/// Every crate the engine may depend on, and the one job it does.
///
/// Unit tests run against the library target, so this list is only the
/// library's dependencies; `[dev-dependencies]` are test scaffolding and are
/// deliberately out of scope.
const ALLOWED: &[(&str, &str)] = &[
    ("clap", "the command line"),
    ("image", "decoding image files for character-cell artwork"),
    ("mermaid-text", "diagram layout"),
    ("pulldown-cmark", "markdown parsing"),
    ("serde", "the wire format's derives"),
    ("serde_json", "the wire format"),
    ("syntect", "code block highlighting"),
    ("unicode-width", "display columns"),
];

/// The crate names declared under `[dependencies]` in a Cargo manifest.
///
/// The manifest is parsed line by line rather than as TOML to keep the test
/// free of a `toml` dependency — the same policy it is checking. Only a line
/// that opens in column zero declares a dependency; everything indented is a
/// continuation of an inline table such as `image`'s feature list.
fn dependency_names(manifest: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let mut in_dependencies = false;

    for line in manifest.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_dependencies = trimmed == "[dependencies]";
            continue;
        }
        if !in_dependencies || trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if line.starts_with([' ', '\t']) {
            continue;
        }
        let Some((name, _)) = line.split_once('=') else {
            continue;
        };
        names.insert(name.trim().to_string());
    }

    names
}

/// The parser sees the real manifest, including its multi-line feature list.
#[test]
fn the_manifest_parses() {
    let names = dependency_names(include_str!("../Cargo.toml"));

    assert!(
        names.contains("image"),
        "image is declared over several lines; the parser must still see it: {names:?}"
    );
    assert!(
        !names.contains("insta"),
        "[dev-dependencies] must not leak into the list: {names:?}"
    );
}

#[test]
fn every_dependency_is_on_the_allowlist() {
    let names = dependency_names(include_str!("../Cargo.toml"));
    assert!(!names.is_empty(), "parsed no dependencies at all");

    let allowed: BTreeSet<&str> = ALLOWED.iter().map(|(name, _)| *name).collect();
    let unexpected: Vec<&String> = names
        .iter()
        .filter(|name| !allowed.contains(name.as_str()))
        .collect();

    assert!(
        unexpected.is_empty(),
        "the engine gained dependencies outside the sanctioned set: {unexpected:?}\n\
         If it is deliberate, add each one to ALLOWED in this file with the job it does."
    );
}

#[test]
fn the_allowlist_describes_the_manifest() {
    let names = dependency_names(include_str!("../Cargo.toml"));

    for (name, reason) in ALLOWED {
        assert!(
            !reason.trim().is_empty(),
            "{name} is allowed but the list gives no reason"
        );
        assert!(
            names.contains(*name),
            "ALLOWED names {name}, but Cargo.toml does not declare it; \
             remove it from the list so the list keeps meaning something"
        );
    }
}
