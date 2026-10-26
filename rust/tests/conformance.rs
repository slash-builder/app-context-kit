//! Runs every case in ../spec/conformance/*.json against the Rust implementation.
//!
//! Each case is checked independently and every failure is reported together, so one bad case
//! does not hide the others.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use app_context_kit::{resolve, Manifest, Platform};
use serde_json::Value;

fn load(name: &str) -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../spec/conformance")
        .join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    match serde_json::from_str::<Value>(&text).expect("fixture is JSON") {
        Value::Array(cases) => cases,
        other => panic!("{name}: expected an array, got {other}"),
    }
}

fn str_field<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key]
        .as_str()
        .ok_or_else(|| format!("fixture field {key} is not a string"))
}

/// Compares and, on mismatch, returns a message naming the field.
fn same<T: PartialEq + std::fmt::Debug>(field: &str, got: T, want: T) -> Result<(), String> {
    if got == want {
        Ok(())
    } else {
        Err(format!("{field}: got {got:?}, want {want:?}"))
    }
}

fn check_manifest(case: &Value) -> Result<(), String> {
    // A case carries either a parsed `manifest` value or a `source` text that goes through
    // `Manifest::parse` (so `not-json` is reachable).
    let got = match case["source"].as_str() {
        Some(text) => Manifest::parse(text),
        None => Manifest::from_value(&case["manifest"]),
    };
    if case["valid"].as_bool() == Some(true) {
        let m = got.map_err(|e| format!("expected valid, got {e}"))?;
        let d = &case["defaults"];
        let kits: Vec<String> = d["kits"]
            .as_array()
            .ok_or("defaults.kits missing")?
            .iter()
            .filter_map(|k| k.as_str().map(str::to_string))
            .collect();
        same("kits", m.kits, kits)?;
        same(
            "venue mode",
            m.venue_mode.as_str(),
            str_field(d, "venueMode")?,
        )?;
        same(
            "venue consumer",
            m.venue_consumer.as_str(),
            str_field(d, "venueConsumer")?,
        )
    } else {
        let err = got.err().map(|e| e.code());
        same("error code", err, Some(str_field(case, "error")?))
    }
}

fn check_context(case: &Value) -> Result<(), String> {
    let manifest =
        Manifest::from_value(&case["manifest"]).map_err(|e| format!("manifest invalid: {e}"))?;
    let platform: Platform = str_field(case, "platform")?
        .parse()
        .map_err(|e| format!("{e}"))?;
    let env: HashMap<String, String> = case["env"]
        .as_object()
        .ok_or("env is not an object")?
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string()))
        .collect();
    let got = resolve(&manifest, platform, str_field(case, "home")?, &env);

    if let Some(code) = case["error"].as_str() {
        return same("error code", got.err().map(|e| e.code()), Some(code));
    }
    let r = got.map_err(|e| format!("expected success, got {e}"))?;
    let want = &case["expect"];
    let d = &want["dirs"];
    same("prefix", r.prefix.as_str(), str_field(want, "prefix")?)?;
    same("dirs.data", r.dirs.data.as_str(), str_field(d, "data")?)?;
    same(
        "dirs.config",
        r.dirs.config.as_str(),
        str_field(d, "config")?,
    )?;
    same("dirs.state", r.dirs.state.as_str(), str_field(d, "state")?)?;
    same("dirs.cache", r.dirs.cache.as_str(), str_field(d, "cache")?)?;
    same(
        "dirs.runtime",
        r.dirs.runtime.as_str(),
        str_field(d, "runtime")?,
    )?;
    same("roster", r.roster.as_str(), str_field(want, "roster")?)?;
    same("scratch", Some(r.scratch), want["scratch"].as_bool())?;
    same("mode", r.mode.as_str(), str_field(want, "mode")?)
}

fn run_all(file: &str, expected_count: usize, check: fn(&Value) -> Result<(), String>) {
    let cases = load(file);
    assert_eq!(
        cases.len(),
        expected_count,
        "{file}: fixture count changed; update this test"
    );
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let name = c["name"].as_str().unwrap_or("<unnamed>");
            check(c).err().map(|e| format!("{file} / {name}: {e}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "{} of {} cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn manifest_cases() {
    run_all("manifest_cases.json", 36, check_manifest);
}

#[test]
fn context_cases() {
    run_all("context_cases.json", 25, check_context);
}
