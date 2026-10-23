## What this changes

<!-- One or two sentences. What behaviour is different after this pull request? -->

## Which half

- [ ] Engine (`engine/`, wire format, layout)
- [ ] Plugin (`lua/`, `plugin/`, keys, windows)
- [ ] Repository, CI, release or documentation

## Checks

- [ ] `cargo test --workspace --locked`
- [ ] `cargo fmt -p md-render -- --check`
- [ ] `cargo clippy -p md-render --all-targets --locked -- -D warnings`
- [ ] `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua`
- [ ] `nvim -l tests/interactive/run.lua`
- [ ] Snapshots reviewed, not just accepted (`.snap.new` diffs read)
- [ ] `nvim --headless -u NONE -c 'helptags doc' -c q` produces no `doc/tags` diff

## Wire format

<!-- Only for engine output changes: does `docs/md-render-format.md` match
     `engine/src/wire.rs`, and is a wire-version bump needed? -->

- [ ] No wire-format change
- [ ] Wire-format change, and `wire.rs`, `docs/md-render-format.md` and
      `engine/tests/wire_format_doc.rs` were updated together

## OpenSpec

<!-- Planning for a non-trivial change lives in openspec/changes/<name>/. -->

- [ ] No planning change needed
- [ ] Change `<name>` implemented and validated
      (`npx --yes @fission-ai/openspec@1.13.2 validate --all --no-interactive`)
