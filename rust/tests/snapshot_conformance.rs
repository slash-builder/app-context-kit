//! Spec section 8. Adopts every snapshot the Dart test wrote from a real context
//! (`spec/conformance/snapshot_cases.json`) and refuses every case in `snapshot_negative_cases.json`.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use app_context_kit::{
    resolve, AppContext, ContextSnapshot, Manifest, Mode, OpenOptions, Platform, SettingsError,
};
use serde_json::{json, Value};

/// The root the Dart fixture uses. The Rust test swaps it for its own temp directory before it opens anything, so it
/// never touches the directories the Dart test uses.
const FIXTURE_ROOT: &str = "/tmp/app-context-snapshot-fixture";

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

fn manifest() -> Manifest {
    Manifest::from_value(
        &json!({"id": "com.slashbuilder.demo.notes-rust", "name": "Notes", "version": "0.1.0"}),
    )
    .unwrap()
}

fn platform(s: &str) -> Platform {
    s.parse().unwrap()
}

fn env_of(v: &Value) -> HashMap<String, String> {
    v.as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
        .collect()
}

fn temp(label: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "app-context-snapshot-{label}-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// Puts the temporary root into JSON text in place of the fixture root. The path is escaped first: a Windows path has backslashes,
/// which are not valid in JSON text as they stand.
fn swap_in_json(json_text: &str, root: &Path) -> String {
    let escaped = serde_json::to_string(root.to_str().unwrap()).unwrap();
    json_text.replace(FIXTURE_ROOT, &escaped[1..escaped.len() - 1])
}

#[test]
fn adopts_every_dart_snapshot_with_the_same_directories_and_instance() {
    let cases = load("snapshot_cases.json");
    assert!(cases.len() >= 6, "the fixture lost cases");
    let mut failures = Vec::new();
    for c in &cases {
        let name = c["name"].as_str().unwrap();
        let snap =
            ContextSnapshot::from_value(&c["snapshot"]).unwrap_or_else(|e| panic!("{name}: {e}"));
        let adopted = AppContext::adopt(&snap);

        // The directories the Rust resolver computes from the same inputs are the ones the Dart context wrote.
        let inputs = &c["inputs"];
        let resolved = resolve(
            &manifest(),
            platform(inputs["platform"].as_str().unwrap()),
            inputs["home"].as_str().unwrap(),
            &env_of(&inputs["env"]),
        )
        .unwrap();
        let mut check = |what: &str, got: &str, want: &str| {
            if got != want {
                failures.push(format!(
                    "{name}: {what}: adopted {got:?}, Rust resolve {want:?}"
                ));
            }
        };
        let d = adopted.dirs();
        check("data", &d.data, &resolved.dirs.data);
        check("config", &d.config, &resolved.dirs.config);
        check("state", &d.state, &resolved.dirs.state);
        check("cache", &d.cache, &resolved.dirs.cache);
        check("runtime", &d.runtime, &resolved.dirs.runtime);
        check(
            "roster",
            &adopted.roster_dir().to_string_lossy(),
            &resolved.roster,
        );
        check(
            "app id",
            adopted.app_id(),
            "com.slashbuilder.demo.notes-rust",
        );
        check(
            "instance",
            adopted.instance(),
            c["snapshot"]["instance"].as_str().unwrap(),
        );
        check("mode", adopted.mode().as_str(), resolved.mode.as_str());
        if adopted.is_scratch() != resolved.scratch {
            failures.push(format!("{name}: scratch differs"));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn a_rust_context_opened_on_the_same_inputs_makes_the_same_snapshot_but_for_the_instance() {
    let mut opened = 0;
    for c in load("snapshot_cases.json") {
        if c["kind"] != "real-context" {
            continue;
        }
        let name = c["name"].as_str().unwrap();
        let root = temp(name);
        let swap = |s: &str| s.replace(FIXTURE_ROOT, root.to_str().unwrap());
        let inputs = &c["inputs"];
        let env: HashMap<String, String> = env_of(&inputs["env"])
            .into_iter()
            .map(|(k, v)| (k, swap(&v)))
            .collect();
        let ctx = AppContext::open(
            manifest(),
            OpenOptions {
                env: Some(env),
                platform: Some(platform(inputs["platform"].as_str().unwrap())),
                home: Some(swap(inputs["home"].as_str().unwrap())),
                announce: false,
                ..OpenOptions::default()
            },
        )
        .unwrap();
        let mut want: Value =
            serde_json::from_str(&swap_in_json(&c["snapshot"].to_string(), &root)).unwrap();
        want["instance"] = json!(ctx.instance);
        assert_eq!(ctx.snapshot().to_value(), want, "{name}");
        opened += 1;
        drop(ctx);
        let _ = fs::remove_dir_all(&root);
    }
    assert!(opened >= 4);
}

#[test]
fn an_adopter_of_a_dart_snapshot_creates_no_roster_entry_and_writes_no_settings() {
    let cases = load("snapshot_cases.json");
    let c = cases.iter().find(|c| c["name"] == "scratch").unwrap();
    let root = temp("adopt-scratch");
    let text = swap_in_json(&c["snapshot"].to_string(), &root);
    let adopted = AppContext::adopt(&ContextSnapshot::parse(&text).unwrap());
    assert_eq!(adopted.mode(), Mode::Real);
    // what the owner (Dart) leaves behind: a settings file
    fs::create_dir_all(&adopted.dirs().config).unwrap();
    let cfg = Path::new(&adopted.dirs().config).join("config.json");
    fs::write(&cfg, r#"{"theme":"dark"}"#).unwrap();

    let mut settings = adopted.settings();
    assert_eq!(settings.get_or::<String>("theme", String::new()), "dark");
    assert_eq!(
        settings.set("theme", json!("light")),
        Err(SettingsError::ReadOnly)
    );
    assert_eq!(fs::read_to_string(&cfg).unwrap(), r#"{"theme":"dark"}"#);

    adopted.create_data_dir("blocks").unwrap();
    adopted.create_state_dir("log").unwrap();
    assert!(
        !adopted.roster_dir().exists(),
        "an adopter must not create the roster directory"
    );
    assert!(!Path::new(&adopted.dirs().cache).exists());
    assert!(!Path::new(&adopted.dirs().runtime).exists());
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn refuses_every_negative_case_with_the_listed_error_and_field() {
    let cases = load("snapshot_negative_cases.json");
    assert!(cases.len() >= 25);
    let mut failures = Vec::new();
    for c in &cases {
        let name = c["name"].as_str().unwrap();
        let got = match c["source"].as_str() {
            Some(text) => ContextSnapshot::parse(text),
            None => ContextSnapshot::from_value(&c["snapshot"]),
        };
        let Err(e) = got else {
            failures.push(format!("{name}: accepted, want {}", c["error"]));
            continue;
        };
        if e.code() != c["error"].as_str().unwrap() {
            failures.push(format!(
                "{name}: got {} ({e}), want {}",
                e.code(),
                c["error"]
            ));
        }
        if let Some(field) = c["field"].as_str() {
            if !e.to_string().contains(&format!("`{field}`"))
                && !e.to_string().contains(&format!("\"{field}\""))
            {
                failures.push(format!("{name}: message {e:?} does not name {field}"));
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
