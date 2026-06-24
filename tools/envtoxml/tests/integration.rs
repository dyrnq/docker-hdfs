//! Integration tests for the `envtoxml` binary.
//!
//! Each test writes a small XML fixture to a temp file, invokes the
//! compiled binary with crafted env vars, and asserts on the merged
//! result.
//!
//! Run:  cargo test  (from tools/envtoxml/)

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

/// Locate the compiled envtoxml binary the tests will invoke.
///
/// We try `CARGO_BIN_EXE_envtoxml` first — the official cargo hook
/// for finding same-package binaries from integration tests, and the
/// form recommended by the cargo book. Newer cargo (1.43+ in general,
/// 1.96 verified here) sets it automatically.
///
/// Fallback: derive from `CARGO_MANIFEST_DIR` + the standard
/// `target/<profile>/envtoxml` layout. Required for Cargo 1.83 (the
/// toolchain pinned in `Dockerfile.{debian,ubuntu}`'s builder stage
/// and the CI lint job) which does NOT set `CARGO_BIN_EXE_<name>` —
/// verified by `env::vars()` dump from a rust:1.83-slim-bookworm
/// container; only `CARGO_HOME`, `CARGO_MANIFEST_DIR`,
/// `CARGO_MANIFEST_PATH`, and the `CARGO_PKG_*` family are set, no
/// `CARGO_BIN_EXE_*`. We probe debug first, then release, so the
/// fallback works for both `cargo test` and `cargo test --release`.
fn bin() -> PathBuf {
    if let Ok(p) = env::var("CARGO_BIN_EXE_envtoxml") {
        return p.into();
    }
    let manifest = env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR not set — must run under cargo test");
    let manifest = PathBuf::from(manifest);
    for profile in ["debug", "release"] {
        let candidate = manifest.join("target").join(profile).join("envtoxml");
        if candidate.exists() {
            return candidate;
        }
    }
    panic!(
        "could not locate compiled envtoxml binary: tried \
         CARGO_BIN_EXE_envtoxml, {}/target/debug/envtoxml, \
         {}/target/release/envtoxml — run `cargo build` first",
        manifest.display(),
        manifest.display(),
    );
}

/// Write `xml` to a fresh temp file named `hdfs-site.xml` and return its path.
/// Naming the file `hdfs-site.xml` matters: the tool matches env var names
/// against the file's basename (minus .xml), so `HDFS-SITE.XML_*` targets it.
fn fixture(xml: &str) -> PathBuf {
    let dir = tempfile_dir();
    let path = dir.join("hdfs-site.xml");
    fs::write(&path, xml).unwrap();
    path
}

// Minimal temp dir helper (avoid pulling in the `tempfile` crate for one call).
fn tempfile_dir() -> PathBuf {
    let mut p = env::temp_dir();
    // Unique-ish name; tests run in parallel but each gets its own dir.
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let pid = std::process::id();
    p.push(format!("envtoxml-test-{}-{}", pid, n));
    fs::create_dir_all(&p).unwrap();
    p
}

const MINIMAL: &str = r#"<?xml version="1.0"?>
<configuration>
    <property><name>dfs.replication</name><value>1</value></property>
    <property><name>dfs.namenode.rpc-address</name><value>0.0.0.0:8020</value></property>
</configuration>
"#;

/// Run the binary against `file` with the given env overrides (plus a clean
/// baseline). Returns (exit_status, stdout, stderr).
fn run(file: &PathBuf, env_overrides: &[(&str, &str)]) -> (bool, String, String) {
    let mut cmd = Command::new(bin());
    cmd.arg(file);
    // Start from a minimal env so stray host `*.XML_*` vars can't leak in,
    // then add PATH so the binary runs and the overrides under test.
    cmd.env_clear();
    cmd.env("PATH", env::var("PATH").unwrap_or_default());
    for (k, v) in env_overrides {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("failed to run envtoxml");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

fn content(file: &PathBuf) -> String {
    fs::read_to_string(file).unwrap()
}

#[test]
fn overwrites_existing_property_in_place_no_duplicate() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(
        &f,
        &[("HDFS-SITE.XML_dfs.namenode.rpc-address", "hdfs.test:8020")],
    );
    assert!(ok);
    let c = content(&f);
    assert!(
        c.contains("<value>hdfs.test:8020</value>"),
        "new value written"
    );
    assert!(!c.contains("0.0.0.0:8020"), "old value gone");
    let n = c.matches("dfs.namenode.rpc-address").count();
    assert_eq!(n, 1, "property must not be duplicated, got {n}");
}

#[test]
fn appends_new_property_before_configuration_close() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(
        &f,
        &[("HDFS-SITE.XML_dfs.client.use.datanode.hostname", "true")],
    );
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("<name>dfs.client.use.datanode.hostname</name>"));
    assert!(c.contains("<value>true</value>"));
    // existing property untouched
    assert_eq!(c.matches("dfs.replication").count(), 1);
}

#[test]
fn escapes_special_xml_chars_in_value() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.x", "a&b<c>\"d'e")]);
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("<value>a&amp;b&lt;c&gt;&quot;d&apos;e</value>"));
    assert!(
        !c.contains("a&b<c>"),
        "raw unescaped chars must not survive"
    );
}

#[test]
fn value_with_equals_is_preserved_split_on_first_only() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.eq", "a=b=c")]);
    assert!(ok);
    assert!(content(&f).contains("<value>a=b=c</value>"));
}

#[test]
fn value_with_spaces_is_not_word_split() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.spaced", "a b c d")]);
    assert!(ok);
    assert!(content(&f).contains("<value>a b c d</value>"));
}

#[test]
fn rejects_config_key_with_markup() {
    let f = fixture(MINIMAL);
    let (ok, _, stderr) = run(&f, &[("HDFS-SITE.XML_bad<script>", "x")]);
    assert!(ok, "bad key is skipped, not fatal");
    assert!(stderr.contains("failed whitelist"), "should warn: {stderr}");
    assert!(
        !content(&f).contains("bad<script>"),
        "bad key must not be injected"
    );
}

#[test]
fn no_matching_env_is_noop_exit_zero() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("UNRELATED_VAR", "foo")]);
    assert!(ok);
    let c = content(&f);
    assert_eq!(c.matches("dfs.replication").count(), 1);
    assert_eq!(c.matches("dfs.namenode.rpc-address").count(), 1);
}

#[test]
fn file_targeting_isolation_core_vars_do_not_touch_hdfs_site() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(
        &f,
        &[
            ("HDFS-SITE.XML_dfs.only", "hdfs"),
            ("CORE-SITE.XML_fs.defaultFS", "file:///x"),
        ],
    );
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("dfs.only"), "hdfs-site got its own var");
    assert!(
        !c.contains("fs.defaultFS"),
        "hdfs-site must NOT get a core-site var"
    );
}

#[test]
fn case_insensitive_name_prefix_lowercase_env_matches() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("hdfs-site.xml_dfs.lower", "ok")]);
    assert!(ok);
    assert!(content(&f).contains("<name>dfs.lower</name>"));
}

#[test]
fn mixed_overwrite_and_append_in_one_run() {
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(
        &f,
        &[
            ("HDFS-SITE.XML_dfs.namenode.rpc-address", "new:9"),
            ("HDFS-SITE.XML_dfs.extra", "1"),
        ],
    );
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("<value>new:9</value>"));
    assert!(c.contains("<name>dfs.extra</name>"));
    assert_eq!(c.matches("dfs.namenode.rpc-address").count(), 1, "no dup");
}

#[test]
fn preserves_comments_byte_for_byte() {
    // The whole point of streaming (vs tree rebuild): comments + their
    // surrounding whitespace survive untouched when we only replace a value.
    let xml = r#"<?xml version="1.0"?>
<configuration>
    <!-- a comment with <weird> & chars that must survive -->
    <property><name>dfs.namenode.rpc-address</name><value>0.0.0.0:8020</value></property>
    <!-- trailing comment -->
</configuration>
"#;
    let f = fixture(xml);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.namenode.rpc-address", "x:1")]);
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("<!-- a comment with <weird> & chars that must survive -->"));
    assert!(c.contains("<!-- trailing comment -->"));
    assert!(c.contains("<value>x:1</value>"));
}

#[test]
fn refuses_non_xml_file() {
    let dir = tempfile_dir();
    let f = dir.join("notxml.txt");
    fs::write(&f, "nope").unwrap();
    let (ok, _, stderr) = run(&f, &[]);
    assert!(!ok, "non-xml file must exit non-zero");
    assert!(stderr.contains("not a *.xml"), "stderr: {stderr}");
}

#[test]
fn missing_file_with_override_is_hard_error() {
    // No overrides → the fast path returns success without reading the file
    // (a no-op, by design: nothing to merge, so the file need not exist).
    // But when an override IS present and the file is missing, that's a real
    // error the operator should see.
    let (ok, _, stderr) = run(
        &PathBuf::from("/nonexistent/hdfs-site.xml"),
        &[("HDFS-SITE.XML_dfs.x", "1")],
    );
    assert!(!ok);
    assert!(stderr.contains("read "), "stderr: {stderr}");
}

#[test]
fn remove_sentinel_deletes_existing_property() {
    // value = !remove → the whole <property> is dropped.
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.namenode.rpc-address", "!remove")]);
    assert!(ok);
    let c = content(&f);
    assert!(
        !c.contains("dfs.namenode.rpc-address"),
        "property must be deleted: {c}"
    );
    assert!(!c.contains("0.0.0.0:8020"), "its value must be gone too");
    // the other property survives untouched
    assert!(c.contains("dfs.replication"));
    // output still well-formed (the merge validates by construction, but
    // a stray truncation would leave dangling tags — re-check here)
    assert!(c.contains("</configuration>"));
}

#[test]
fn remove_sentinel_on_absent_key_is_noop() {
    // Removing a key that isn't in the XML: no-op, other props intact.
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.does.not.exist", "!remove")]);
    assert!(ok);
    let c = content(&f);
    assert!(c.contains("dfs.replication"));
    assert!(c.contains("dfs.namenode.rpc-address"));
    assert!(!c.contains("does.not.exist"));
}

#[test]
fn remove_sentinel_not_triggered_by_substring() {
    // Only EXACT value match triggers removal; a value merely containing
    // the sentinel substring is treated as a normal (escaped) value.
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(&f, &[("HDFS-SITE.XML_dfs.x", "prefix !remove suffix")]);
    assert!(ok);
    let c = content(&f);
    // appended as a normal property, NOT treated as a removal
    assert!(c.contains("<name>dfs.x</name>"));
    assert!(c.contains("prefix !remove suffix"));
}

#[test]
fn mixed_remove_overwrite_append_in_one_run() {
    // remove one, overwrite another, append a third — all in one pass.
    let f = fixture(MINIMAL);
    let (ok, _, _) = run(
        &f,
        &[
            ("HDFS-SITE.XML_dfs.replication", "!remove"),
            ("HDFS-SITE.XML_dfs.namenode.rpc-address", "new:9"),
            ("HDFS-SITE.XML_dfs.extra", "1"),
        ],
    );
    assert!(ok);
    let c = content(&f);
    assert!(!c.contains("dfs.replication"), "removed");
    assert!(c.contains("<value>new:9</value>"), "overwritten");
    assert!(c.contains("<name>dfs.extra</name>"), "appended");
    assert_eq!(c.matches("dfs.namenode.rpc-address").count(), 1, "no dup");
}

// -------------------------------------------------------------------------
// --create / ENVTOXML_CREATE tests
//
// The create mode lets the entrypoint (or a user) opt in to having
// envtoxml write a fresh minimal <configuration/> skeleton if the
// target file does NOT exist. Backward compat: without --create,
// missing file + overrides is still a hard error (operator typo).
// Missing file + no overrides remains a noop success (unchanged).
// -------------------------------------------------------------------------

/// Helper: invoke envtoxml with an extra `--create` flag and
/// per-call env overrides. Mirrors `run()` but passes the flag.
fn run_create(file: &PathBuf, env_overrides: &[(&str, &str)]) -> (bool, String, String) {
    let mut cmd = Command::new(bin());
    cmd.arg("--create");
    cmd.arg(file);
    cmd.env_clear();
    cmd.env("PATH", env::var("PATH").unwrap_or_default());
    for (k, v) in env_overrides {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("failed to run envtoxml");
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

/// A unique path that does NOT exist yet. Using a path inside the
/// per-test tempdir keeps parallel test runs isolated without
/// needing a teardown step.
/// A unique path that does NOT exist yet, named `hdfs-site.xml` so
/// the standard `HDFS-SITE.XML_*` env var prefix matches by
/// default. Each test gets its own tempdir (see `tempfile_dir`),
/// so parallel test runs don't collide.
fn missing_path() -> PathBuf {
    let dir = tempfile_dir();
    dir.join("hdfs-site.xml")
}

#[test]
fn create_mode_writes_empty_skeleton_when_no_overrides() {
    // --create + missing file + no overrides → write a minimal
    // valid <configuration/> so subsequent boots see a well-formed
    // file. Without this, the entrypoint's noop fast path would
    // leave the file absent (consistent with old behavior, but
    // useless for the "boot a fresh cluster from zero XML" case).
    let f = missing_path();
    assert!(!f.exists());
    let (ok, _, stderr) = run_create(&f, &[]);
    assert!(ok, "create+no-overrides should succeed: {stderr}");
    assert!(f.exists(), "file must be created");
    let c = content(&f);
    assert!(c.contains("<?xml"), "well-formed XML prolog");
    assert!(c.contains("<configuration>"));
    assert!(c.contains("</configuration>"));
    assert!(
        stderr.contains("created empty"),
        "stderr should announce creation: {stderr}"
    );
}

#[test]
fn create_mode_does_not_overwrite_existing_file() {
    // --create + existing file (with content) + no overrides →
    // leave the file untouched. --create is opt-in for the
    // missing-file case only.
    let f = fixture(MINIMAL);
    let before = content(&f);
    let (ok, _, _) = run_create(&f, &[]);
    assert!(ok);
    assert_eq!(content(&f), before, "file must not be overwritten");
}

#[test]
fn create_mode_appends_overrides_to_brand_new_file() {
    // --create + missing file + overrides → create skeleton, then
    // merge overrides into it. End result: a single XML with just
    // the override properties (no spurious duplication, no leftover
    // boilerplate that merge_file can't see).
    let f = missing_path();
    assert!(!f.exists());
    let (ok, _, stderr) = run_create(
        &f,
        &[
            ("HDFS-SITE.XML_dfs.replication", "3"),
            ("HDFS-SITE.XML_dfs.namenode.rpc-address", "nn:8020"),
        ],
    );
    assert!(ok, "create+overrides should succeed: {stderr}");
    let c = content(&f);
    assert!(c.contains("<name>dfs.replication</name><value>3</value>"));
    assert!(c.contains("<name>dfs.namenode.rpc-address</name><value>nn:8020</value>"));
    assert!(c.contains("</configuration>"), "well-formed close");
    assert_eq!(c.matches("dfs.replication").count(), 1, "no dup");
    assert_eq!(c.matches("dfs.namenode.rpc-address").count(), 1, "no dup");
    assert!(
        stderr.contains("created empty") || stderr.contains("created empty (--create"),
        "stderr should announce creation: {stderr}"
    );
    assert!(stderr.contains("merged 2 override"), "merge log: {stderr}");
}

#[test]
fn create_mode_off_with_no_overrides_keeps_noop_behavior() {
    // Backward compat: no flag, no overrides, missing file → exit 0,
    // file NOT created. Operators who don't opt in keep the
    // historic behavior.
    let f = missing_path();
    assert!(!f.exists());
    let (ok, _, _) = run(&f, &[]);
    assert!(ok, "missing file + no overrides is still success");
    assert!(!f.exists(), "file must NOT be created without --create");
}

#[test]
fn create_mode_off_with_overrides_still_errors_on_missing_file() {
    // Backward compat: no flag, has overrides, missing file → hard
    // error. The operator almost certainly typoed; failing loud is
    // correct.
    let f = missing_path();
    let (ok, _, stderr) = run(&f, &[("HDFS-SITE.XML_dfs.x", "1")]);
    assert!(
        !ok,
        "missing file + overrides + no --create is a hard error"
    );
    assert!(stderr.contains("read "), "stderr: {stderr}");
}

#[test]
fn create_mode_via_env_knob() {
    // The entrypoint sometimes cannot pass argv (e.g. when invoked
    // from a `case` that already built the argv), so we also
    // accept ENVTOXML_CREATE=1. Same observable behavior as the
    // --create flag.
    let f = missing_path();
    let mut cmd = Command::new(bin());
    cmd.arg(&f);
    cmd.env_clear();
    cmd.env("PATH", env::var("PATH").unwrap_or_default());
    cmd.env("ENVTOXML_CREATE", "1");
    let out = cmd.output().expect("failed to run envtoxml");
    assert!(out.status.success(), "ENVTOXML_CREATE=1 must enable create");
    assert!(f.exists(), "file must be created via env knob");
    let c = content(&f);
    assert!(c.contains("<configuration>"));
}

#[test]
fn create_mode_creates_parent_dir_if_missing() {
    // The file path includes a parent dir that doesn't exist yet.
    // --create should mkdir -p the parent (otherwise writing into
    // a not-yet-created dir fails with ENOENT). This matches the
    // entrypoint's typical usage where HADOOP_ETC may be a fresh
    // mount point on first boot.
    let dir = tempfile_dir();
    let nested = dir.join("sub").join("not-yet").join("hdfs-site.xml");
    assert!(!nested.exists());
    let (ok, _, stderr) = run_create(&nested, &[("HDFS-SITE.XML_dfs.x", "1")]);
    assert!(ok, "create+overrides in nested dir: {stderr}");
    assert!(nested.exists());
    let c = content(&nested);
    assert!(c.contains("<name>dfs.x</name>"));
}
