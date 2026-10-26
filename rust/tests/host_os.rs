//! Behaviour that depends on the real operating system rather than on the `Platform` the other tests pass in. Written because
//! the other tests only ever ran on macOS (see docs/PLATFORMS.md); `tools/linux-test.sh` runs it in a Linux container.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use app_context_kit::roster::{new_instance_id, Roster};
use app_context_kit::{AppContext, ConfigStore, Manifest, OpenOptions, Platform};
use serde_json::json;

struct Tmp(PathBuf);

impl Tmp {
    fn new(what: &str) -> Tmp {
        static N: AtomicUsize = AtomicUsize::new(0);
        let p = std::env::temp_dir().join(format!(
            "app-context-host-{what}-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
    fn path(&self) -> &Path {
        &self.0
    }
    fn s(&self, rel: &str) -> String {
        self.0.join(rel).to_string_lossy().into_owned()
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn manifest() -> Manifest {
    Manifest::from_value(&json!({
        "id": "com.slashbuilder.demo.calc", "name": "Calc", "version": "0.1.0", "venue": {"mode": "off"}
    }))
    .unwrap()
}

fn open(env: HashMap<String, String>, home: &str) -> AppContext {
    AppContext::open(
        manifest(),
        OpenOptions {
            env: Some(env),
            // Platform is deliberately NOT overridden: this is the real host.
            home: Some(home.into()),
            announce: false,
            ..OpenOptions::default()
        },
    )
    .expect("open")
}

fn env(pairs: &[(&str, String)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

#[cfg(unix)]
fn is_root() -> bool {
    std::process::Command::new("id")
        .arg("-u")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "0")
        .unwrap_or(false)
}

#[test]
fn the_host_platform_is_what_the_os_says() {
    let want = if cfg!(target_os = "linux") {
        Platform::Linux
    } else if cfg!(target_os = "macos") {
        Platform::MacOs
    } else {
        Platform::Windows
    };
    assert_eq!(Platform::host(), want);
}

#[test]
fn open_on_the_real_host_puts_the_directories_where_the_os_convention_says() {
    let t = Tmp::new("dirs");
    let home = t.s("home");
    let x = |n: &str| t.s(&format!("xdg/{n}"));
    let ctx = open(
        env(&[
            ("HOME", home.clone()),
            ("XDG_DATA_HOME", x("data")),
            ("XDG_CONFIG_HOME", x("config")),
            ("XDG_STATE_HOME", x("state")),
            ("XDG_CACHE_HOME", x("cache")),
            ("XDG_RUNTIME_DIR", x("run")),
            // Windows takes its directories from these (the environment passed in replaces the real one)
            ("LOCALAPPDATA", x("local")),
            ("APPDATA", x("roaming")),
            ("TEMP", x("temp")),
        ]),
        &home,
    );
    let d = &ctx.resolved.dirs;
    if cfg!(target_os = "linux") {
        assert_eq!(d.data, format!("{}/com.slashbuilder.demo.calc", x("data")));
        assert_eq!(
            d.config,
            format!("{}/com.slashbuilder.demo.calc", x("config"))
        );
        assert_eq!(
            d.state,
            format!("{}/com.slashbuilder.demo.calc", x("state"))
        );
        assert_eq!(
            d.cache,
            format!("{}/com.slashbuilder.demo.calc", x("cache"))
        );
        assert_eq!(
            d.runtime,
            format!("{}/com.slashbuilder.demo.calc", x("run"))
        );
        assert_eq!(
            ctx.resolved.roster,
            format!("{}/app-context-roster", x("run"))
        );
    } else if cfg!(target_os = "macos") {
        assert!(
            d.data.starts_with(&format!("{home}/Library/")),
            "{}",
            d.data
        );
        assert!(
            d.config.starts_with(&format!("{home}/Library/")),
            "{}",
            d.config
        );
    }
    if cfg!(windows) {
        // compared by path components: the joined path may use backslashes where the test spelled forward slashes
        assert!(Path::new(&d.data).starts_with(x("local")), "{}", d.data);
        assert!(
            Path::new(&d.config).starts_with(x("roaming")),
            "{}",
            d.config
        );
        assert!(
            Path::new(&d.runtime).starts_with(x("temp")),
            "{}",
            d.runtime
        );
    }
    for dir in [&d.data, &d.config, &d.state, &d.cache, &d.runtime] {
        assert!(Path::new(dir).is_dir(), "{dir} was not created");
    }
}

#[cfg(target_os = "linux")]
#[test]
fn without_xdg_variables_linux_falls_back_to_the_home_relative_defaults() {
    let t = Tmp::new("fallback");
    let home = t.s("home");
    let ctx = open(env(&[("HOME", home.clone())]), &home);
    let d = &ctx.resolved.dirs;
    assert_eq!(
        d.data,
        format!("{home}/.local/share/com.slashbuilder.demo.calc")
    );
    assert_eq!(
        d.config,
        format!("{home}/.config/com.slashbuilder.demo.calc")
    );
    assert_eq!(
        d.state,
        format!("{home}/.local/state/com.slashbuilder.demo.calc")
    );
    assert_eq!(d.cache, format!("{home}/.cache/com.slashbuilder.demo.calc"));
    assert_eq!(
        d.runtime,
        format!("{home}/.local/state/com.slashbuilder.demo.calc/run")
    );
    assert_eq!(ctx.resolved.roster, "/tmp/app-context-roster");
}

#[test]
fn the_default_five_second_heartbeat_really_ticks() {
    let t = Tmp::new("beat");
    let roster = Roster::new(t.path().join("roster"));
    let ann = roster
        .announce(
            "com.slashbuilder.demo.calc",
            &new_instance_id(),
            "Calc",
            "0.1.0",
            Duration::from_secs(5),
        )
        .expect("announce");
    let beat = |file: &Path| -> String {
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
        v["heartbeatAt"].as_str().unwrap().to_string()
    };
    let first = beat(ann.file());
    std::thread::sleep(Duration::from_millis(5600));
    let second = beat(ann.file());
    assert!(
        second > first,
        "heartbeat did not advance: {first} then {second}"
    );
    let live = roster.running(chrono::Utc::now(), Duration::from_secs(15));
    assert_eq!(live.len(), 1);
    ann.withdraw().unwrap();
}

#[cfg(unix)]
#[test]
fn a_token_file_the_user_cannot_read_is_a_clear_problem() {
    use std::os::unix::fs::PermissionsExt;
    if is_root() {
        println!("SKIPPED: running as root, file mode bits do not apply");
        return;
    }
    let t = Tmp::new("token");
    let home = t.s("home");
    let f = t.path().join("token");
    std::fs::write(&f, "secret").unwrap();
    std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o000)).unwrap();
    // The shared manifest has venue mode "off"; this one is in the default "auto" mode, so it looks at the token.
    let m = Manifest::from_value(
        &json!({"id": "com.slashbuilder.demo.calc", "name": "Calc", "version": "0.1.0"}),
    )
    .unwrap();
    let ctx = AppContext::open(
        m,
        OpenOptions {
            env: Some(env(&[
                ("HOME", home.clone()),
                ("VENUE_TOKEN_FILE", f.to_string_lossy().into_owned()),
            ])),
            home: Some(home),
            announce: false,
            ..OpenOptions::default()
        },
    )
    .expect("auto mode degrades");
    std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(ctx.venue.kind(), "local");
    assert!(
        ctx.venue.description().contains("cannot be read"),
        "{}",
        ctx.venue.description()
    );
    assert!(ctx
        .notes
        .iter()
        .any(|n| n.severity == app_context_kit::Severity::Warning));
}

#[test]
fn a_config_write_is_a_rename_a_concurrent_reader_never_sees_a_partial_file() {
    let t = Tmp::new("atomic");
    let mut store = ConfigStore::open(&t.path().join("cfg"));
    store.set("n", json!(0)).unwrap();
    let path = store.path().to_path_buf();
    let stop = Arc::new(AtomicBool::new(false));
    let reader = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let (mut reads, mut bad) = (0u64, 0u64);
            while !stop.load(Ordering::Relaxed) {
                match std::fs::read_to_string(&path) {
                    Ok(s) => {
                        if serde_json::from_str::<serde_json::Value>(&s).is_err() {
                            bad += 1;
                        }
                    }
                    Err(_) => bad += 1,
                }
                reads += 1;
            }
            (reads, bad)
        })
    };
    let began = Instant::now();
    let mut writes = 0;
    while began.elapsed() < Duration::from_millis(1800) {
        writes += 1;
        store.set("n", json!(writes)).unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    let (reads, bad) = reader.join().unwrap();
    assert!(writes > 100, "only {writes} writes");
    assert_eq!(
        bad, 0,
        "{bad} of {reads} reads saw a missing or half-written config.json"
    );
}
