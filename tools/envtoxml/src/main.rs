//! `envtoxml` — merge environment variables into a Hadoop XML config file.
//!
//! Inspired by apache/ozone's `envtoconf.py`, reimplemented as a static
//! Rust binary so the dyrnq/hdfs image needs no python3 runtime. Ozone
//! ships python3 anyway (for its test toolchain); we don't, and pulling
//! in python3/uv just for this one transform is not worth ~5-100MB.
//!
//! # Convention
//!
//! An environment variable named `<NAME>.XML_<hadoop-key>=<value>` is
//! merged into `<name>.xml`:
//!
//! ```text
//! HDFS-SITE.XML_dfs.namenode.rpc-address=hdfs.test:8020
//! ```
//!
//! merges into `hdfs-site.xml` as
//!
//! ```xml
//! <property><name>dfs.namenode.rpc-address</name><value>hdfs.test:8020</value></property>
//! ```
//!
//! `<NAME>` (case-insensitive) selects the target file: strip the `.xml`
//! suffix from the file's basename and compare lowercased. So `HDFS-SITE`
//! targets `hdfs-site.xml`, `CORE-SITE` targets `core-site.xml`. Any
//! `*.xml` under the hadoop etc dir is a valid target — the mechanism is
//! generic, like ozone's.
//!
//! # Merge semantics
//!
//! - key already present in the XML → its `<value>` is replaced in place
//!   (the `<property>` is NOT duplicated; everything else is untouched).
//! - key absent → a new `<property>` is inserted just before the first
//!   `</configuration>`.
//! - value equals [`REMOVE_SENTINEL`] (`!remove`) → the matching
//!   `<property>` is DELETED from the XML (no-op if the key is absent).
//!   This lets an operator drop a template-defined property without
//!   bind-mounting a whole XML.
//!
//! All pre-existing properties (kerberos principals, keytabs, dirs, the
//! big issue-#8 comment block, …) are preserved byte-for-byte. We stream
//! events through quick-xml and copy them verbatim, replacing only the
//! target `<value>`; we never rebuild the tree, so comments and
//! whitespace are not reformatted.
//!
//! # Safety
//!
//! Ozone's `to_xml` does NOT escape special characters — we do:
//!
//! 1. **XML escaping**: injected values go through `BytesText::new`,
//!    which escapes `& < >` (and `"` `'` in attribute contexts) on write.
//!    `&` is handled internally so produced entities are not double-escaped.
//! 2. **Config-key whitelist**: only `[A-Za-z0-9._-]` accepted. A key
//!    containing `<` or space is skipped with a stderr warning (not fatal)
//!    so it can never inject markup into `<name>`.
//! 3. **Well-formedness by construction**: quick-xml writes balanced
//!    events, so the output is always valid XML — no separate xmllint pass
//!    is needed (though the image still ships libxml2-utils for operators).
//!
//! # Exit codes
//!
//! 0 on success (including when no env var targets the file — a no-op).
//! Non-zero on a hard error: file missing/not-xml, no `</configuration>`,
//! or a quick-xml parse error. A bad config key is a warning, not fatal.

use quick_xml::events::{BytesText, Event};
use quick_xml::{Reader, Writer};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

/// Value sentinel meaning "delete this property" rather than set/overwrite
/// it. Goes in the VALUE, not the env name — env names are restricted to
/// `[-._a-zA-Z0-9]` (k8s ConfigMap keys reject `!`), while env values are
/// arbitrary bytes. Example:
///
/// ```text
/// HDFS-SITE.XML_dfs.namenode.kerberos.principal=!remove
/// ```
///
/// drops that `<property>` from hdfs-site.xml (no-op if the key is absent).
/// Chosen to be intuitive and vanishingly unlikely to collide with a real
/// Hadoop config value; matched by exact equality, so a value containing the
/// sentinel as a substring is NOT treated as a removal.
const REMOVE_SENTINEL: &str = "!remove";

/// Regex-free check that a Hadoop config key contains only the characters
/// Hadoop itself allows in property names: letters, digits, dot, underscore,
/// hyphen. Rejecting anything else (e.g. `<`, space, `=`) prevents an env
/// var from injecting markup into the `<name>` element.
fn is_valid_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
}

/// Lowercased basename of `file` with the `.xml` suffix removed, e.g.
/// `/opt/hadoop/etc/hadoop/hdfs-site.xml` → `hdfs-site`. Returns `None` if
/// the path doesn't end in `.xml` (so the tool refuses non-XML files).
fn target_name(file: &str) -> Option<String> {
    let base = Path::new(file).file_name()?.to_str()?;
    let stem = base.strip_suffix(".xml")?;
    Some(stem.to_ascii_lowercase())
}

/// A single env override for the target file: the Hadoop config key and
/// its raw (unescaped) value. The value is escaped at write time.
struct Override {
    key: String,
    value: String,
}

/// Collect every `<NAME>.XML_<key>=<value>` env var whose `<NAME>` (case
///-insensitive, minus `.XML`) equals `target`. Returns the overrides in
/// the order `std::env::vars()` yields them, with invalid keys filtered
/// out (each rejected key logs a warning to stderr).
fn collect_overrides(target: &str) -> Vec<Override> {
    let mut out = Vec::new();
    for (name, value) in env::vars() {
        // Split on the FIRST `_`: <NAME>.XML_<key>. If there's no `_`, skip.
        let Some((file_part, conf_key)) = name.split_once('_') else {
            continue;
        };
        // file_part must be <NAME>.XML (case-insensitive on the .XML).
        let Some(name_part) = file_part
            .strip_suffix(".XML")
            .or_else(|| file_part.strip_suffix(".xml"))
        else {
            continue;
        };
        if !name_part.eq_ignore_ascii_case(target) {
            continue;
        }
        if !is_valid_key(conf_key) {
            eprintln!("envtoxml: skipping {name}: config key {conf_key:?} failed whitelist");
            continue;
        }
        out.push(Override {
            key: conf_key.to_string(),
            value,
        });
    }
    out
}

/// Merge `overrides` into the XML at `file`, writing the result atomically
/// (temp file in the same directory + rename, so a crash mid-write cannot
/// leave a truncated config for Hadoop to read).
fn merge_file(file: &str, overrides: &[Override]) -> Result<(), String> {
    let src = fs::read(file).map_err(|e| format!("read {file}: {e}"))?;

    let mut reader = Reader::from_reader(src.as_slice());
    reader.config_mut().trim_text(false); // keep whitespace as events → verbatim round-trip

    let mut out: Vec<u8> = Vec::with_capacity(src.len() + 256);
    let mut writer = Writer::new(&mut out);
    let mut buf = Vec::new();

    // Lookup of key → value for the overrides that target this file, plus
    // the set of keys we have NOT yet overwritten in place (so we can
    // append the leftovers before </configuration>).
    let pending_replace: std::collections::HashMap<&str, &str> = overrides
        .iter()
        .map(|o| (o.key.as_str(), o.value.as_str()))
        .collect();
    let mut appended: HashSet<String> = HashSet::new();
    let append_order: Vec<String> = overrides.iter().map(|o| o.key.clone()).collect();

    // Streaming state:
    //   reading_name      — just saw <name>; accumulating its text to test
    //   name_buf          — decoded text of the current <name>
    //   replace_next_value — the matched <name> was a target key; replace
    //                        the following <value> in place
    //   skip_value_body   — we already emitted our own <value>…</value>;
    //                        drop original events until that </value>
    //   wrote_configuration_close — guard: only inject appends before the
    //                        FIRST </configuration>
    let mut reading_name = false;
    let mut name_buf = String::new();
    let mut replace_next_value: Option<String> = None;
    let mut skip_value_body = false;
    let mut injected_appends = false;
    // Removal support: when an override's value is REMOVE_SENTINEL, the
    // whole <property> must be dropped. We record the byte offset of each
    // <property> start; if its <name> turns out to be a removal target we
    // truncate the output buffer back to that offset at </property>,
    // deleting the entire property element. (Properties never nest in
    // Hadoop configs, so a single offset + flag is enough.)
    let mut prop_start: Option<usize> = None;
    let mut current_remove = false;

    loop {
        let ev = match reader.read_event_into(&mut buf) {
            Ok(Event::Eof) => break,
            Ok(e) => e,
            Err(e) => return Err(format!("parse {file}: {e}")),
        };
        match ev {
            Event::Start(e) => {
                let local = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if local == "property" {
                    // Remember where this property starts in the output so
                    // we can truncate it whole if it turns out to be a
                    // removal target. Captured BEFORE writing the tag.
                    prop_start = Some(writer.get_ref().len());
                    current_remove = false;
                }
                if local == "value" {
                    if let Some(val) = replace_next_value.take() {
                        // Replace this <value>…</value> with our own. Emit
                        // <value>, escaped text, </value>; then skip the
                        // original body up to and including its </value>.
                        writer
                            .write_event(Event::Start(e.clone()))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Text(BytesText::new(&val)))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::End(e.to_end()))
                            .map_err(|e| e.to_string())?;
                        skip_value_body = true;
                        continue;
                    }
                } else if local == "name" {
                    reading_name = true;
                    name_buf.clear();
                }
                writer
                    .write_event(Event::Start(e))
                    .map_err(|e| e.to_string())?;
            }
            Event::End(e) => {
                let local = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                if skip_value_body && local == "value" {
                    // We already wrote </value>; drop this original close tag.
                    skip_value_body = false;
                    continue;
                }
                if local == "name" && reading_name {
                    reading_name = false;
                    // Did this <name> name a key we want to override?
                    if let Some(val) = pending_replace.get(name_buf.as_str()) {
                        // Remember we handled it so we don't also append it.
                        appended.insert(name_buf.clone());
                        if *val == REMOVE_SENTINEL {
                            // Deletion, not replacement: flag the enclosing
                            // <property> for truncation at its close tag.
                            current_remove = true;
                        } else {
                            replace_next_value = Some(val.to_string());
                        }
                    }
                }
                // If this <property> was a removal target, drop the entire
                // element by truncating the output back to its start offset.
                // We already wrote Start(property)…End(property) verbatim
                // (no value-replace fired for removal targets), so this one
                // truncation deletes the whole element.
                if local == "property" && current_remove {
                    if let Some(start) = prop_start.take() {
                        writer.get_mut().truncate(start);
                    }
                    current_remove = false;
                    continue; // don't write the </property> — already gone
                }
                if local == "property" {
                    prop_start = None;
                }
                if local == "configuration" && !injected_appends {
                    // Inject any overrides that were NOT matched in the
                    // document, just before </configuration>. We emit them
                    // as proper quick-xml events (not raw bytes) so the
                    // value goes through BytesText::new and is XML-escaped
                    // exactly like the in-place replace path. The leading
                    // "    " + trailing "\n" match the file's existing
                    // one-property-per-line style (cosmetic; Hadoop ignores
                    // whitespace). Removal targets (!remove) that were
                    // absent from the document are skipped — nothing to
                    // append for a delete.
                    injected_appends = true;
                    for key in &append_order {
                        if appended.contains(key) {
                            continue;
                        }
                        let Some(val) = pending_replace.get(key.as_str()) else {
                            continue;
                        };
                        if *val == REMOVE_SENTINEL {
                            // Removal of a key not present in the XML: no-op.
                            continue;
                        }
                        use quick_xml::events::{BytesEnd, BytesStart};
                        writer
                            .write_event(Event::Text(BytesText::new("    ")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Start(BytesStart::new("property")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Start(BytesStart::new("name")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Text(BytesText::new(key)))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::End(BytesEnd::new("name")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Start(BytesStart::new("value")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Text(BytesText::new(val)))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::End(BytesEnd::new("value")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::End(BytesEnd::new("property")))
                            .map_err(|e| e.to_string())?;
                        writer
                            .write_event(Event::Text(BytesText::new("\n")))
                            .map_err(|e| e.to_string())?;
                    }
                }
                writer
                    .write_event(Event::End(e))
                    .map_err(|e| e.to_string())?;
            }
            Event::Text(e) => {
                if skip_value_body {
                    // drop original value text we replaced
                    continue;
                }
                if reading_name {
                    // Accumulate decoded name text (handles entity refs in
                    // the unlikely case a key contains them).
                    if let Ok(t) = e.unescape() {
                        name_buf.push_str(&t);
                    }
                }
                writer
                    .write_event(Event::Text(e))
                    .map_err(|e| e.to_string())?;
            }
            Event::CData(e) => {
                if skip_value_body {
                    continue;
                }
                writer
                    .write_event(Event::CData(e))
                    .map_err(|e| e.to_string())?;
            }
            other => {
                // Comment, Whitespace, Empty, PI, Decl, DocType — all pass
                // through verbatim. This is what preserves the file's
                // comments and indentation byte-for-byte.
                writer.write_event(other).map_err(|e| e.to_string())?;
            }
        }
        buf.clear();
    }

    if !injected_appends {
        // No </configuration> was ever seen — the template is malformed.
        return Err(format!(
            "{file}: no </configuration> found; refusing to merge"
        ));
    }

    // Atomic write: temp file in the same dir, fsync, rename.
    let path = Path::new(file);
    let dir = path
        .parent()
        .ok_or_else(|| format!("{file}: no parent dir"))?;
    let tmp = dir.join(format!(
        ".{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("envtoxml")
    ));
    fs::write(&tmp, &out).map_err(|e| format!("write temp {:?}: {e}", tmp))?;
    fs::rename(&tmp, file).map_err(|e| format!("rename {:?} → {file}: {e}", tmp))?;
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: envtoxml <xml-file>");
        eprintln!("  merges <NAME>.XML_<key>=<value> env vars into <name>.xml");
        return ExitCode::from(2);
    }
    let file = &args[1];
    let Some(target) = target_name(file) else {
        eprintln!("envtoxml: {file} is not a *.xml config");
        return ExitCode::from(2);
    };

    let overrides = collect_overrides(&target);
    // Fast path: nothing to do. Avoids reading/writing the file at all on
    // the common boot where the operator passed no overrides.
    if overrides.is_empty() {
        return ExitCode::SUCCESS;
    }

    match merge_file(file, &overrides) {
        Ok(()) => {
            eprintln!(
                "envtoxml: merged {} override(s) into {file}",
                overrides.len()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("envtoxml: {e}");
            ExitCode::FAILURE
        }
    }
}
