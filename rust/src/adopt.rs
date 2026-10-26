//! Sharing one context between a Dart UI and a Rust core (spec section 8).
//!
//! The side that opened the context (normally the Dart UI, through `AppContext.open`) hands the other side
//! a [`ContextSnapshot`]: plain data describing the directories, the instance id and the mode. The Rust core
//! calls [`AppContext::adopt`] on it and gets an [`AdoptedContext`].
//!
//! # One owner per file
//!
//! * The **owner** (the side that opened the context) owns `config.json` and the roster entry: it announces,
//!   heartbeats, withdraws, and is the only writer of settings.
//! * An **adopter** announces nothing, starts no heartbeat, never writes `config.json`. It reads settings
//!   through [`ReadOnlySettings`], which refuses every write, and it owns the files it creates under
//!   `data` and `state` (and nothing else). It may create directories under those two and no others.
//!
//! If both sides opened a context, the app would be in the roster twice under two instance ids and two code
//! paths would write one settings file; this module exists so that cannot happen by accident.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::de::{self, Deserializer};
use serde::ser::Serializer;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::app_context::AppContext;
use crate::config_store::ConfigStore;
use crate::manifest::is_reverse_dns;
use crate::resolve::{Dirs, Mode};
use crate::roster::is_instance_id;

/// The snapshot schema this crate reads and writes. A change to the shape bumps it (unknown fields are an error).
pub const SNAPSHOT_SCHEMA: u64 = 1;

/// Why a snapshot was refused. Only the first failure is reported, in the order the spec lists them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotError {
    /// The text is not JSON.
    NotJson(String),
    /// The JSON is not an object.
    NotObject,
    /// `schema` is present but is not the number this crate reads.
    UnknownSchema(String),
    /// A required field is absent (dotted for nested ones: `dirs.data`).
    MissingField(String),
    /// A field this schema does not define.
    UnknownField(String),
    /// A field has the wrong type or an invalid value.
    BadField { field: String, why: &'static str },
    /// A directory is not an absolute path (in the syntax of any supported platform).
    RelativePath { field: String, path: String },
}

impl SnapshotError {
    /// The stable code the conformance fixtures use.
    pub fn code(&self) -> &'static str {
        match self {
            SnapshotError::NotJson(_) => "not-json",
            SnapshotError::NotObject => "not-object",
            SnapshotError::UnknownSchema(_) => "unknown-schema",
            SnapshotError::MissingField(_) => "missing-field",
            SnapshotError::UnknownField(_) => "unknown-field",
            SnapshotError::BadField { .. } => "bad-field",
            SnapshotError::RelativePath { .. } => "relative-path",
        }
    }
}

impl fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SnapshotError::NotJson(e) => write!(f, "snapshot is not JSON: {e}"),
            SnapshotError::NotObject => write!(f, "snapshot is not a JSON object"),
            SnapshotError::UnknownSchema(s) => {
                write!(
                    f,
                    "snapshot schema {s} is not supported (this crate reads {SNAPSHOT_SCHEMA})"
                )
            }
            SnapshotError::MissingField(n) => write!(f, "snapshot is missing `{n}`"),
            SnapshotError::UnknownField(n) => write!(f, "snapshot has an unknown field `{n}`"),
            SnapshotError::BadField { field, why } => write!(f, "snapshot field `{field}`: {why}"),
            SnapshotError::RelativePath { field, path } => {
                write!(
                    f,
                    "snapshot field `{field}` is not an absolute path: {path:?}"
                )
            }
        }
    }
}

impl std::error::Error for SnapshotError {}

/// What an adopter can get wrong after the snapshot was accepted.
#[derive(Debug)]
pub enum AdoptError {
    /// A file or directory name that is empty, absolute, or climbs out with `..`.
    BadName(String),
    Io {
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for AdoptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AdoptError::BadName(n) => write!(f, "not a relative name inside the directory: {n:?}"),
            AdoptError::Io { path, source } => write!(f, "{}: {source}", path.display()),
        }
    }
}

impl std::error::Error for AdoptError {}

/// Plain data describing an open context. Cannot be built without passing the checks in [`from_value`](Self::from_value),
/// so [`AppContext::adopt`] is infallible.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextSnapshot {
    app_id: String,
    instance: String,
    mode: Mode,
    scratch: bool,
    dirs: Dirs,
    roster: String,
}

const TOP_FIELDS: [&str; 7] = [
    "schema", "appId", "instance", "mode", "scratch", "dirs", "roster",
];
const DIR_FIELDS: [&str; 5] = ["data", "config", "state", "cache", "runtime"];

/// Absolute in the syntax of any supported platform, whatever the host is: `/x`, `\\server\share`, `C:\x`, `C:/x`.
fn looks_absolute(p: &str) -> bool {
    let b = p.as_bytes();
    p.starts_with('/')
        || p.starts_with("\\\\")
        || (b.len() >= 3
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && (b[2] == b'\\' || b[2] == b'/'))
}

fn bad(field: &str, why: &'static str) -> SnapshotError {
    SnapshotError::BadField {
        field: field.to_string(),
        why,
    }
}

fn path_field(field: &str, v: &Value) -> Result<String, SnapshotError> {
    let s = v.as_str().ok_or_else(|| bad(field, "must be a string"))?;
    if s.is_empty() {
        return Err(bad(field, "is empty"));
    }
    if s.contains('\0') {
        return Err(bad(field, "contains a NUL character"));
    }
    Ok(s.to_string())
}

impl ContextSnapshot {
    /// Parses and checks snapshot text. See [`from_value`](Self::from_value) for the order of the checks.
    pub fn parse(text: &str) -> Result<ContextSnapshot, SnapshotError> {
        let v: Value =
            serde_json::from_str(text).map_err(|e| SnapshotError::NotJson(e.to_string()))?;
        ContextSnapshot::from_value(&v)
    }

    /// Checks, first failure only, in this order: not an object; `schema` missing or not 1; any other required
    /// field missing (in the order of the spec's shape, `dirs.*` dotted); an unknown field; a field of the wrong
    /// type or pattern (appId, instance, mode, scratch, then the directories); a relative path.
    pub fn from_value(v: &Value) -> Result<ContextSnapshot, SnapshotError> {
        let obj = v.as_object().ok_or(SnapshotError::NotObject)?;
        match obj.get("schema") {
            None => return Err(SnapshotError::MissingField("schema".into())),
            Some(s) if s.as_u64() == Some(SNAPSHOT_SCHEMA) => {}
            Some(s) => return Err(SnapshotError::UnknownSchema(s.to_string())),
        }
        for k in &TOP_FIELDS[1..] {
            if !obj.contains_key(*k) {
                return Err(SnapshotError::MissingField((*k).to_string()));
            }
        }
        let dirs_obj = match &obj["dirs"] {
            Value::Object(m) => Some(m),
            _ => None,
        };
        if let Some(m) = dirs_obj {
            for k in DIR_FIELDS {
                if !m.contains_key(k) {
                    return Err(SnapshotError::MissingField(format!("dirs.{k}")));
                }
            }
        }
        for k in obj.keys() {
            if !TOP_FIELDS.contains(&k.as_str()) {
                return Err(SnapshotError::UnknownField(k.clone()));
            }
        }
        let dirs_obj = dirs_obj.ok_or_else(|| bad("dirs", "must be an object"))?;
        for k in dirs_obj.keys() {
            if !DIR_FIELDS.contains(&k.as_str()) {
                return Err(SnapshotError::UnknownField(format!("dirs.{k}")));
            }
        }

        let app_id = obj["appId"].as_str().filter(|s| is_reverse_dns(s));
        let app_id = app_id
            .ok_or_else(|| bad("appId", "must be a reverse-DNS id"))?
            .to_string();
        let instance = obj["instance"].as_str().filter(|s| is_instance_id(s));
        let instance = instance
            .ok_or_else(|| bad("instance", "must be 8 lowercase hex digits"))?
            .to_string();
        let mode = obj["mode"].as_str().and_then(Mode::parse);
        let mode = mode.ok_or_else(|| bad("mode", "must be \"real\" or \"mock\""))?;
        let scratch = obj["scratch"]
            .as_bool()
            .ok_or_else(|| bad("scratch", "must be true or false"))?;

        let mut paths = Vec::new();
        for k in DIR_FIELDS {
            let name = format!("dirs.{k}");
            paths.push((name.clone(), path_field(&name, &dirs_obj[k])?));
        }
        paths.push(("roster".to_string(), path_field("roster", &obj["roster"])?));
        for (field, path) in &paths {
            if !looks_absolute(path) {
                return Err(SnapshotError::RelativePath {
                    field: field.clone(),
                    path: path.clone(),
                });
            }
        }
        let mut it = paths.into_iter().map(|(_, p)| p);
        let dirs = Dirs {
            data: it.next().unwrap(),
            config: it.next().unwrap(),
            state: it.next().unwrap(),
            cache: it.next().unwrap(),
            runtime: it.next().unwrap(),
        };
        let roster = it.next().unwrap();
        Ok(ContextSnapshot {
            app_id,
            instance,
            mode,
            scratch,
            dirs,
            roster,
        })
    }

    /// The snapshot as the JSON object the Dart side writes.
    pub fn to_value(&self) -> Value {
        json!({
            "schema": SNAPSHOT_SCHEMA,
            "appId": self.app_id,
            "instance": self.instance,
            "mode": self.mode.as_str(),
            "scratch": self.scratch,
            "dirs": {
                "data": self.dirs.data,
                "config": self.dirs.config,
                "state": self.dirs.state,
                "cache": self.dirs.cache,
                "runtime": self.dirs.runtime,
            },
            "roster": self.roster,
        })
    }

    pub fn to_json(&self) -> String {
        self.to_value().to_string()
    }

    pub fn app_id(&self) -> &str {
        &self.app_id
    }
    pub fn instance(&self) -> &str {
        &self.instance
    }
    pub fn mode(&self) -> Mode {
        self.mode
    }
    pub fn is_scratch(&self) -> bool {
        self.scratch
    }
    pub fn dirs(&self) -> &Dirs {
        &self.dirs
    }
    pub fn roster(&self) -> &str {
        &self.roster
    }
}

impl Serialize for ContextSnapshot {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.to_value().serialize(s)
    }
}

impl<'de> Deserialize<'de> for ContextSnapshot {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        ContextSnapshot::from_value(&v).map_err(de::Error::custom)
    }
}

/// A context somebody else opened. It exposes where things are and who the app is, and nothing that announces.
///
/// It holds no roster entry, no heartbeat and no settings writer. The only directories it can create are under
/// `data` and `state`.
#[derive(Debug, Clone)]
pub struct AdoptedContext {
    snapshot: ContextSnapshot,
}

/// A name relative to a directory: `/`-separated, no empty, `.` or `..` part, no `\`, `:` or NUL.
fn check_relative(name: &str) -> Result<Vec<&str>, AdoptError> {
    let parts: Vec<&str> = name.split('/').collect();
    let ok = !name.is_empty()
        && parts
            .iter()
            .all(|p| !p.is_empty() && *p != "." && *p != ".." && !p.contains(['\\', ':', '\0']));
    if ok {
        Ok(parts)
    } else {
        Err(AdoptError::BadName(name.to_string()))
    }
}

/// Joins in the directory's own separator style, so a Windows-shaped snapshot joins with `\` on any host.
fn join_in(dir: &str, parts: &[&str]) -> PathBuf {
    let sep = if dir.contains('\\') && !dir.contains('/') {
        '\\'
    } else {
        '/'
    };
    let mut s = dir.trim_end_matches(['/', '\\']).to_string();
    for p in parts {
        s.push(sep);
        s.push_str(p);
    }
    PathBuf::from(s)
}

impl AdoptedContext {
    pub fn snapshot(&self) -> &ContextSnapshot {
        &self.snapshot
    }
    pub fn app_id(&self) -> &str {
        self.snapshot.app_id()
    }
    /// The owner's instance id. The adopter has none of its own: there is one copy of the app, so one instance.
    pub fn instance(&self) -> &str {
        self.snapshot.instance()
    }
    pub fn mode(&self) -> Mode {
        self.snapshot.mode()
    }
    pub fn is_mock(&self) -> bool {
        self.snapshot.mode() == Mode::Mock
    }
    pub fn is_scratch(&self) -> bool {
        self.snapshot.is_scratch()
    }
    pub fn dirs(&self) -> &Dirs {
        self.snapshot.dirs()
    }
    /// Where the owner's roster entry lives. Informational: the adopter never writes there.
    pub fn roster_dir(&self) -> &Path {
        Path::new(self.snapshot.roster())
    }
    pub fn data_dir(&self) -> &Path {
        Path::new(&self.dirs().data)
    }
    pub fn state_dir(&self) -> &Path {
        Path::new(&self.dirs().state)
    }

    /// A path under the data directory (`name` may have `/` parts; no `..`). Nothing is created.
    pub fn data_file(&self, name: &str) -> Result<PathBuf, AdoptError> {
        Ok(join_in(&self.dirs().data, &check_relative(name)?))
    }

    /// A path under the state directory. Nothing is created.
    pub fn state_file(&self, name: &str) -> Result<PathBuf, AdoptError> {
        Ok(join_in(&self.dirs().state, &check_relative(name)?))
    }

    /// Creates (if missing) the directory `name` under `data` and returns it. The data directory itself is
    /// created too if the owner has not yet.
    pub fn create_data_dir(&self, name: &str) -> Result<PathBuf, AdoptError> {
        let p = self.data_file(name)?;
        fs::create_dir_all(&p).map_err(|source| AdoptError::Io {
            path: p.clone(),
            source,
        })?;
        Ok(p)
    }

    /// Creates (if missing) the directory `name` under `state` and returns it.
    pub fn create_state_dir(&self, name: &str) -> Result<PathBuf, AdoptError> {
        let p = self.state_file(name)?;
        fs::create_dir_all(&p).map_err(|source| AdoptError::Io {
            path: p.clone(),
            source,
        })?;
        Ok(p)
    }

    /// The owner's settings, read-only. Reads the file as it is now; call [`ReadOnlySettings::reload`] to see a
    /// later change by the owner.
    pub fn settings(&self) -> ReadOnlySettings {
        ReadOnlySettings {
            store: ConfigStore::open(Path::new(&self.dirs().config)),
        }
    }
}

/// Why a write to adopted settings was refused. There is only one reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsError {
    /// The settings belong to the side that opened the context.
    ReadOnly,
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "settings are owned by the side that opened the context; an adopter cannot write them"
        )
    }
}

impl std::error::Error for SettingsError {}

/// `config.json` as an adopter sees it: readable, never writable. Opening it creates nothing.
#[derive(Debug)]
pub struct ReadOnlySettings {
    store: ConfigStore,
}

impl ReadOnlySettings {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.store.get(key)
    }
    pub fn get_or<T: serde::de::DeserializeOwned>(&self, key: &str, fallback: T) -> T {
        self.store.get_or(key, fallback)
    }
    pub fn all(&self) -> &Map<String, Value> {
        self.store.all()
    }
    /// Why the file is damaged, if it is (the owner decides what to do about it).
    pub fn problem(&self) -> Option<&str> {
        self.store.problem()
    }
    pub fn path(&self) -> &Path {
        self.store.path()
    }
    /// Reads the file again.
    pub fn reload(&mut self) {
        let dir = self
            .store
            .path()
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        self.store = ConfigStore::open(&dir);
    }
    /// Always refused.
    pub fn set(&mut self, _key: &str, _value: Value) -> Result<(), SettingsError> {
        Err(SettingsError::ReadOnly)
    }
    /// Always refused.
    pub fn save(&self) -> Result<(), SettingsError> {
        Err(SettingsError::ReadOnly)
    }
}

impl AppContext {
    /// Adopt a context another side opened (spec section 8). Announces nothing, starts nothing, writes nothing.
    pub fn adopt(snapshot: &ContextSnapshot) -> AdoptedContext {
        AdoptedContext {
            snapshot: snapshot.clone(),
        }
    }

    /// This context as a snapshot, for handing to a second runtime. Same shape the Dart `AppContext.snapshot()` writes.
    pub fn snapshot(&self) -> ContextSnapshot {
        ContextSnapshot {
            app_id: self.manifest.id.clone(),
            instance: self.instance.clone(),
            mode: self.resolved.mode,
            scratch: self.resolved.scratch,
            dirs: self.resolved.dirs.clone(),
            roster: self.resolved.roster.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    fn good(root: &str) -> Value {
        json!({
            "schema": 1, "appId": "com.slashbuilder.demo.notes-rust", "instance": "0a1b2c3d", "mode": "real", "scratch": true,
            "dirs": {"data": format!("{root}/d"), "config": format!("{root}/c"), "state": format!("{root}/s"),
                     "cache": format!("{root}/k"), "runtime": format!("{root}/r")},
            "roster": format!("{root}/roster"),
        })
    }

    fn code(v: Value) -> &'static str {
        ContextSnapshot::from_value(&v).unwrap_err().code()
    }

    #[test]
    fn accepts_a_good_snapshot_and_round_trips() {
        let s = ContextSnapshot::from_value(&good("/x")).unwrap();
        assert_eq!(s.to_value(), good("/x"));
        let again: ContextSnapshot =
            serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
        assert_eq!(again, s);
    }

    #[test]
    fn refuses_in_the_documented_order() {
        assert_eq!(
            ContextSnapshot::parse("{nope").unwrap_err().code(),
            "not-json"
        );
        assert_eq!(code(json!([1])), "not-object");
        assert_eq!(code(json!({})), "missing-field");
        let mut v = good("/x");
        v["schema"] = json!(2);
        assert_eq!(code(v), "unknown-schema");
        let mut v = good("/x");
        v["schema"] = json!("1");
        assert_eq!(code(v), "unknown-schema");
        let mut v = good("/x");
        v["dirs"].as_object_mut().unwrap().remove("state");
        let e = ContextSnapshot::from_value(&v).unwrap_err();
        assert_eq!(e, SnapshotError::MissingField("dirs.state".into()));
        let mut v = good("/x");
        v["extra"] = json!(1);
        assert_eq!(code(v), "unknown-field");
        let mut v = good("/x");
        v["instance"] = json!("ABCDEF01");
        assert_eq!(code(v), "bad-field");
        let mut v = good("/x");
        v["dirs"]["cache"] = json!("rel/cache");
        let e = ContextSnapshot::from_value(&v).unwrap_err();
        assert!(
            matches!(e, SnapshotError::RelativePath { ref field, .. } if field == "dirs.cache")
        );
        // a missing field is reported before a bad one
        let mut v = good("/x");
        v["mode"] = json!("fake");
        v.as_object_mut().unwrap().remove("roster");
        assert_eq!(code(v), "missing-field");
    }

    #[test]
    fn absolute_means_absolute_on_any_platform() {
        for p in ["/a", "C:\\a", "c:/a", "\\\\srv\\share\\a"] {
            assert!(looks_absolute(p), "{p}");
        }
        for p in ["a", "./a", "a/b", "C:a", "C:", "a\\b"] {
            assert!(!looks_absolute(p), "{p}");
        }
    }

    #[test]
    fn names_cannot_climb_out() {
        let ctx = AppContext::adopt(&ContextSnapshot::from_value(&good("/x")).unwrap());
        assert_eq!(
            ctx.data_file("blocks/ab").unwrap(),
            PathBuf::from("/x/d/blocks/ab")
        );
        for bad in ["", "..", "a/../b", "/abs", "a//b", "a\\b", "C:x", "./a"] {
            assert!(
                matches!(ctx.data_file(bad), Err(AdoptError::BadName(_))),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_windows_shaped_snapshot_joins_with_backslashes() {
        let v = json!({
            "schema": 1, "appId": "com.slashbuilder.demo.calc", "instance": "c0ffee01", "mode": "real", "scratch": false,
            "dirs": {"data": "C:\\Users\\a\\AppData\\Local\\com.slashbuilder.demo.calc\\data", "config": "C:\\c", "state": "C:\\s",
                     "cache": "C:\\k", "runtime": "C:\\r"},
            "roster": "C:\\t\\app-context-roster",
        });
        let ctx = AppContext::adopt(&ContextSnapshot::from_value(&v).unwrap());
        assert_eq!(
            ctx.data_file("blocks/ab").unwrap().to_string_lossy(),
            "C:\\Users\\a\\AppData\\Local\\com.slashbuilder.demo.calc\\data\\blocks\\ab"
        );
    }

    #[test]
    fn adopting_announces_nothing_and_never_writes_settings() {
        let t = TempDir::new("adopt");
        let root = t.path().to_str().unwrap().to_string();
        let ctx = AppContext::adopt(&ContextSnapshot::from_value(&good(&root)).unwrap());
        // the owner wrote a setting; the adopter reads it
        fs::create_dir_all(&ctx.dirs().config).unwrap();
        fs::write(
            Path::new(&ctx.dirs().config).join("config.json"),
            r#"{"fontSize":14}"#,
        )
        .unwrap();
        let before = fs::read(Path::new(&ctx.dirs().config).join("config.json")).unwrap();
        let mut s = ctx.settings();
        assert_eq!(s.get_or("fontSize", 0), 14);
        assert_eq!(s.set("fontSize", json!(20)), Err(SettingsError::ReadOnly));
        assert_eq!(s.save(), Err(SettingsError::ReadOnly));
        assert_eq!(fs::read(s.path()).unwrap(), before);
        // it may create directories under data and state
        let blocks = ctx.create_data_dir("blocks").unwrap();
        assert!(blocks.is_dir());
        assert!(ctx.create_state_dir("log").unwrap().is_dir());
        // and it created no roster entry
        assert!(!ctx.roster_dir().exists());
        // the settings file it read from is the only thing in config
        assert_eq!(fs::read_dir(&ctx.dirs().config).unwrap().count(), 1);
        // a later change by the owner shows after reload
        fs::write(s.path(), r#"{"fontSize":16}"#).unwrap();
        s.reload();
        assert_eq!(s.get_or("fontSize", 0), 16);
    }

    #[test]
    fn a_rust_owned_context_hands_over_the_same_snapshot() {
        use crate::app_context::OpenOptions;
        use crate::manifest::Manifest;
        let t = TempDir::new("adopt-own");
        let mut env = std::collections::HashMap::new();
        env.insert(
            "APP_CONTEXT_SCRATCH".to_string(),
            t.path().to_str().unwrap().to_string(),
        );
        let m = Manifest::parse(
            r#"{"id":"com.slashbuilder.demo.notes-rust","name":"N","version":"0.1.0"}"#,
        )
        .unwrap();
        let ctx = AppContext::open(
            m,
            OpenOptions {
                env: Some(env),
                home: Some("/h".into()),
                announce: false,
                ..OpenOptions::default()
            },
        )
        .unwrap();
        let snap = ctx.snapshot();
        assert_eq!(snap.instance(), ctx.instance);
        assert_eq!(snap.dirs(), &ctx.resolved.dirs);
        let adopted = AppContext::adopt(&snap);
        assert_eq!(adopted.data_dir(), Path::new(&ctx.resolved.dirs.data));
        assert!(adopted.is_scratch());
    }
}
