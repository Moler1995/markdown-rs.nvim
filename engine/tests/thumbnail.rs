//! The `thumbnail` mode as a command.
//!
//! `image_art`'s own tests check the encoding. These check the contract the
//! plugin depends on: a complete request writes one file and nothing to
//! standard output, and every refusal exits non-zero with a diagnostic on
//! standard error that names what it refused.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_md-render")
}

fn image_fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/images")
        .join(name)
}

/// A fresh directory for one test, so parallel tests cannot share a file name.
fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(name);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .args(args)
        .output()
        .expect("the binary runs")
}

fn stderr_of(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// Run a request that must be refused, and check how it is refused.
fn assert_refused(args: &[&str], needle: &str) {
    let output = run(args);
    assert!(
        !output.status.success(),
        "{args:?} should have failed, stderr: {}",
        stderr_of(&output)
    );
    assert!(
        output.stdout.is_empty(),
        "a refusal must write nothing to stdout"
    );
    let stderr = stderr_of(&output);
    assert!(
        stderr.contains(needle),
        "stderr {stderr:?} must name {needle:?}"
    );
}

#[test]
fn a_complete_request_writes_one_file_and_nothing_to_stdout() {
    let dir = temp_dir("md-render-thumbnail-cli-test");
    let out = dir.join("thumb");
    let source = image_fixture("image_sample.png");
    let (source, out) = (
        source.to_str().expect("utf-8"),
        out.to_str().expect("utf-8"),
    );

    let output = run(&[
        "thumbnail",
        source,
        "--box",
        "16x8",
        "--out",
        out,
        "--background",
        "#282828",
    ]);

    assert!(output.status.success(), "stderr: {}", stderr_of(&output));
    assert!(output.stdout.is_empty(), "stdout must carry nothing");
    let written = std::fs::metadata(out).expect("the thumbnail exists");
    assert!(written.is_file());
    assert!(written.len() > 0, "the thumbnail is empty");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_crop_writes_the_rows_it_names() {
    let dir = temp_dir("md-render-thumbnail-cli-crop-test");
    let out = dir.join("full");
    let part = dir.join("part");
    let source = image_fixture("image_sample.png");
    let (source, out, part) = (
        source.to_str().expect("utf-8"),
        out.to_str().expect("utf-8"),
        part.to_str().expect("utf-8"),
    );

    let whole = run(&[
        "thumbnail",
        source,
        "--box",
        "16x8",
        "--out",
        out,
        "--background",
        "#282828",
    ]);
    assert!(whole.status.success(), "stderr: {}", stderr_of(&whole));

    let cut = run(&[
        "thumbnail",
        source,
        "--box",
        "16x8",
        "--crop",
        "2x4",
        "--out",
        part,
        "--background",
        "#282828",
    ]);
    assert!(cut.status.success(), "stderr: {}", stderr_of(&cut));

    let whole = std::fs::metadata(out).expect("the full box").len();
    let part = std::fs::metadata(part).expect("the crop").len();
    assert!(part > 0, "the crop is empty");
    assert!(part < whole, "a crop of half the rows is not smaller");

    // A crop that is not inside the box is refused, naming the option.
    assert_refused(
        &[
            "thumbnail",
            source,
            "--box",
            "16x8",
            "--crop",
            "6x4",
            "--out",
            dir.join("refused").to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        "--crop",
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn every_argument_is_required() {
    let dir = temp_dir("md-render-thumbnail-cli-args-test");
    let out = dir.join("thumb");
    let source = image_fixture("image_sample.png");
    let full = [
        "thumbnail",
        source.to_str().expect("utf-8"),
        "--box",
        "16x8",
        "--out",
        out.to_str().expect("utf-8"),
        "--background",
        "#282828",
    ];

    // Each name is what clap prints when the argument is missing.
    let cases: [(&[usize], &str); 4] = [
        (&[1], "SOURCE"),
        (&[2, 3], "--box"),
        (&[4, 5], "--out"),
        (&[6, 7], "--background"),
    ];
    for (removed, name) in cases {
        let args: Vec<&str> = full
            .iter()
            .enumerate()
            .filter(|(i, _)| !removed.contains(i))
            .map(|(_, arg)| *arg)
            .collect();
        let output = run(&args);
        assert!(!output.status.success(), "{name} may not be omitted");
        assert!(
            stderr_of(&output).contains(name),
            "stderr must name {name}: {}",
            stderr_of(&output)
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_missing_source_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-missing-test");
    let missing = dir.join("missing.png");
    let out = dir.join("thumb");
    let missing = missing.to_str().expect("utf-8");
    assert_refused(
        &[
            "thumbnail",
            missing,
            "--box",
            "8x4",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        missing,
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_directory_source_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-directory-test");
    let out = dir.join("thumb");
    let source = dir.to_str().expect("utf-8");
    assert_refused(
        &[
            "thumbnail",
            source,
            "--box",
            "8x4",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        source,
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unsupported_source_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-unsupported-test");
    let source = dir.join("notes.txt");
    std::fs::write(&source, b"not a picture").expect("write");
    let out = dir.join("thumb");
    let source = source.to_str().expect("utf-8");
    assert_refused(
        &[
            "thumbnail",
            source,
            "--box",
            "8x4",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        source,
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_box_with_no_room_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-narrow-box-test");
    let out = dir.join("thumb");
    let source = image_fixture("image_sample.png");
    assert_refused(
        &[
            "thumbnail",
            source.to_str().expect("utf-8"),
            "--box",
            "0x4",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        "--box",
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_box_over_the_pixel_bound_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-huge-box-test");
    let out = dir.join("thumb");
    let source = image_fixture("image_sample.png");
    assert_refused(
        &[
            "thumbnail",
            source.to_str().expect("utf-8"),
            "--box",
            "4000x2000",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        "--box",
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unwritable_output_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-unwritable-test");
    let out = dir.join("no-such-directory").join("thumb");
    let source = image_fixture("image_sample.png");
    let out = out.to_str().expect("utf-8");
    assert_refused(
        &[
            "thumbnail",
            source.to_str().expect("utf-8"),
            "--box",
            "8x4",
            "--out",
            out,
            "--background",
            "#000000",
        ],
        out,
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_source_over_the_decoding_limits_is_refused() {
    let dir = temp_dir("md-render-thumbnail-cli-oversized-test");
    let source = dir.join("oversized.png");
    let mut bytes = std::fs::read(image_fixture("image_sample.png")).expect("fixture bytes");
    // 16 MiB + 1: over the byte limit, with a header that is still readable.
    bytes.resize(16 * 1024 * 1024 + 1, 0);
    std::fs::write(&source, &bytes).expect("write");

    let out = dir.join("thumb");
    let source = source.to_str().expect("utf-8");
    assert_refused(
        &[
            "thumbnail",
            source,
            "--box",
            "8x4",
            "--out",
            out.to_str().expect("utf-8"),
            "--background",
            "#000000",
        ],
        source,
    );
    let _ = std::fs::remove_dir_all(&dir);
}
