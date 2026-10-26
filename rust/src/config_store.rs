//! A small JSON settings file (`config.json`) in the app's config directory.
//!
//! Writes are atomic: the new content goes to a temp file next to the target, is flushed to disk, and
//! is then renamed over the target.
//!
//! Spec section 5, item 3: a `config.json` that is not valid UTF-8 or not a JSON object is *damaged*.
//! `open` reports it in [`ConfigStore::problem`] and still opens, but `set` and `save` fail with
//! [`ConfigError::Damaged`] until the caller explicitly sets the file aside with
//! [`ConfigStore::set_aside_corrupt`] (it is renamed to `config.json.corrupt`, never deleted).

use std::fmt;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

#[derive(Debug)]
pub enum ConfigError {
    /// The file on disk is damaged (or unreadable), so saving would destroy it. Carries the problem text.
    Damaged(String),
    Io(io::Error),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Damaged(p) => {
                write!(f, "settings file is damaged, not saving over it: {p}")
            }
            ConfigError::Io(e) => write!(f, "settings I/O error: {e}"),
        }
    }
}

impl std::error::Error for ConfigError {}

impl From<io::Error> for ConfigError {
    fn from(e: io::Error) -> Self {
        ConfigError::Io(e)
    }
}

#[derive(Debug)]
pub struct ConfigStore {
    file: PathBuf,
    values: Map<String, Value>,
    problem: Option<String>,
}

impl ConfigStore {
    /// Opens `<config_dir>/config.json`. A missing file is an empty store; an unreadable or
    /// non-object file is an empty store with [`problem`](Self::problem) set.
    pub fn open(config_dir: &Path) -> ConfigStore {
        let file = config_dir.join("config.json");
        let mut store = ConfigStore {
            file,
            values: Map::new(),
            problem: None,
        };
        match fs::read(&store.file) {
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(Value::Object(map)) => store.values = map,
                    Ok(_) => store.problem = Some("config.json is not a JSON object".to_string()),
                    Err(e) => store.problem = Some(format!("config.json is not valid JSON: {e}")),
                },
                Err(_) => store.problem = Some("config.json is not valid UTF-8".to_string()),
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => store.problem = Some(format!("config.json cannot be read: {e}")),
        }
        store
    }

    /// Why the file is damaged or unreadable, if it is. While this is `Some`, saving is refused.
    pub fn problem(&self) -> Option<&str> {
        self.problem.as_deref()
    }

    pub fn path(&self) -> &Path {
        &self.file
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    /// The value for `key` as a `T`, or `fallback` if the key is absent or has another type. A whole
    /// JSON number reads as a float (`3` is `3.0` for `f64`); a fractional one does not read as an integer.
    pub fn get_or<T: DeserializeOwned>(&self, key: &str, fallback: T) -> T {
        self.values
            .get(key)
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or(fallback)
    }

    /// Sets `key` (JSON `null` removes it) and saves.
    /// Fails with [`ConfigError::Damaged`], leaving the store unchanged, while the file is damaged.
    pub fn set(&mut self, key: &str, value: Value) -> Result<(), ConfigError> {
        self.refuse_if_damaged()?;
        if value.is_null() {
            self.values.remove(key);
        } else {
            self.values.insert(key.to_string(), value);
        }
        self.save()
    }

    pub fn all(&self) -> &Map<String, Value> {
        &self.values
    }

    fn refuse_if_damaged(&self) -> Result<(), ConfigError> {
        match &self.problem {
            Some(p) => Err(ConfigError::Damaged(p.clone())),
            None => Ok(()),
        }
    }

    /// Writes the store atomically. Refuses while [`problem`](Self::problem) is set.
    pub fn save(&self) -> Result<(), ConfigError> {
        self.refuse_if_damaged()?;
        if let Some(parent) = self.file.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = self.file.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(&self.values).map_err(io::Error::from)?;
        {
            let mut f = File::create(&tmp)?;
            f.write_all(text.as_bytes())?;
            f.sync_all()?;
        }
        fs::rename(&tmp, &self.file)?;
        Ok(())
    }

    /// The caller's explicit decision to start over: moves the damaged file to
    /// `config.json.corrupt` (kept, not deleted), clears the problem and returns where it went.
    /// The store is empty afterwards. Does nothing (`Ok(None)`) when the file is not damaged.
    pub fn set_aside_corrupt(&mut self) -> Result<Option<PathBuf>, ConfigError> {
        if self.problem.is_none() {
            return Ok(None);
        }
        let aside = self.file.with_extension("json.corrupt");
        fs::rename(&self.file, &aside)?;
        self.problem = None;
        Ok(Some(aside))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;
    use serde_json::json;

    #[test]
    fn round_trips_and_is_atomic() {
        let dir = TempDir::new("cfg-rt");
        let mut s = ConfigStore::open(dir.path());
        assert!(s.problem().is_none());
        assert_eq!(s.get_or("fontSize", 12), 12);
        s.set("fontSize", json!(14)).unwrap();
        s.set("theme", json!("dark")).unwrap();
        // no temp file is left behind
        assert!(!dir.path().join("config.json.tmp").exists());

        let again = ConfigStore::open(dir.path());
        assert_eq!(again.get_or("fontSize", 0), 14);
        assert_eq!(again.get_or::<String>("theme", String::new()), "dark");
        // a value of the wrong type falls back
        assert!(again.get_or::<bool>("fontSize", true));
    }

    #[test]
    fn null_removes_a_key() {
        let dir = TempDir::new("cfg-null");
        let mut s = ConfigStore::open(dir.path());
        s.set("a", json!(1)).unwrap();
        s.set("a", Value::Null).unwrap();
        assert!(ConfigStore::open(dir.path()).get("a").is_none());
    }

    #[test]
    fn corrupt_file_is_reported_and_never_replaced() {
        let dir = TempDir::new("cfg-bad");
        fs::write(dir.path().join("config.json"), "{not json").unwrap();
        let mut s = ConfigStore::open(dir.path());
        assert!(s.problem().is_some());
        // Saving is refused, and the file is untouched.
        assert!(matches!(s.set("a", json!(1)), Err(ConfigError::Damaged(_))));
        assert_eq!(
            fs::read_to_string(dir.path().join("config.json")).unwrap(),
            "{not json"
        );
        // Starting over is an explicit act that keeps the old bytes.
        let aside = s.set_aside_corrupt().unwrap().unwrap();
        assert_eq!(fs::read_to_string(aside).unwrap(), "{not json");
        s.set("a", json!(1)).unwrap();
        assert_eq!(ConfigStore::open(dir.path()).get_or("a", 0), 1);
    }

    #[test]
    fn a_refused_set_leaves_the_store_unchanged() {
        let dir = TempDir::new("cfg-nochange");
        fs::write(dir.path().join("config.json"), "[1]").unwrap();
        let mut s = ConfigStore::open(dir.path());
        assert!(s.set("a", json!(1)).is_err());
        assert!(s.get("a").is_none());
        assert!(matches!(s.save(), Err(ConfigError::Damaged(_))));
    }

    #[test]
    fn a_file_that_is_not_utf8_is_damaged_and_kept_byte_for_byte() {
        let dir = TempDir::new("cfg-utf8");
        let bytes: &[u8] = b"{\"a\": \"\xff\xfe\"}";
        fs::write(dir.path().join("config.json"), bytes).unwrap();
        let mut s = ConfigStore::open(dir.path());
        assert!(
            s.problem().is_some_and(|p| p.contains("UTF-8")),
            "{:?}",
            s.problem()
        );
        assert!(matches!(s.set("a", json!(1)), Err(ConfigError::Damaged(_))));
        assert_eq!(fs::read(dir.path().join("config.json")).unwrap(), bytes);
        let aside = s.set_aside_corrupt().unwrap().unwrap();
        assert!(aside.ends_with("config.json.corrupt"));
        assert_eq!(fs::read(aside).unwrap(), bytes);
        assert!(!dir.path().join("config.json").exists());
        assert!(s.problem().is_none());
        s.set("a", json!(1)).unwrap();
    }

    #[test]
    fn setting_aside_a_healthy_file_does_nothing() {
        let dir = TempDir::new("cfg-aside-ok");
        let mut s = ConfigStore::open(dir.path());
        s.set("a", json!(1)).unwrap();
        assert_eq!(s.set_aside_corrupt().unwrap(), None);
        assert!(dir.path().join("config.json").exists());
    }

    #[test]
    fn a_whole_number_reads_as_a_float_but_a_fraction_does_not_read_as_an_int() {
        let dir = TempDir::new("cfg-f64");
        let mut s = ConfigStore::open(dir.path());
        s.set("whole", json!(3)).unwrap();
        s.set("frac", json!(2.5)).unwrap();
        s.set("text", json!("3")).unwrap();
        assert_eq!(s.get_or("whole", 0.0_f64), 3.0);
        assert_eq!(s.get_or("frac", 0.0_f64), 2.5);
        assert_eq!(s.get_or("frac", 7_i64), 7);
        assert_eq!(s.get_or("text", 1.5_f64), 1.5);
        // and it survives a round trip through the file
        let again = ConfigStore::open(dir.path());
        assert_eq!(again.get_or("whole", 0.0_f64), 3.0);
    }

    #[test]
    fn non_object_json_is_a_problem_too() {
        let dir = TempDir::new("cfg-arr");
        fs::write(dir.path().join("config.json"), "[1,2]").unwrap();
        assert!(ConfigStore::open(dir.path()).problem().is_some());
    }
}
