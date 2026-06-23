//! Integration tests for the `envtoxml` binary.
//!
//! Each test writes a small XML fixture to a temp file, invokes the
//! compiled binary with crafted env vars, and asserts on the merged
//! result. The binary path comes from the `CARGO_BIN_EXE_envtoxml`
//! env var that cargo sets for integration tests.
//!
//! Run:  cargo test  (from tools/envtoxml/)

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn bin() -> PathBuf {
    env::var("CARGO_BIN_EXE_envtoxml")
        .expect("CARGO_BIN_EXE_envtoxml not set")
        .into()
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
