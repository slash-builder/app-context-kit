//! Directory and mode resolution: a pure function of manifest, platform, home and env.
//!
//! Spec section 2. Nothing here touches the filesystem or the host environment, so the
//! platform is a parameter and every platform can be tested on any host.

use std::collections::HashMap;
use std::fmt;
use std::str::FromStr;

use crate::manifest::Manifest;

/// The target platform. This is a parameter, never the host OS.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    MacOs,
    Windows,
}

impl Platform {
    /// The platform this binary was compiled for (anything not macOS or Windows counts as Linux).
    pub fn host() -> Platform {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(windows) {
            Platform::Windows
        } else {
            Platform::Linux
        }
    }

    fn sep(self) -> char {
        if self == Platform::Windows {
            '\\'
        } else {
            '/'
        }
    }
}

impl FromStr for Platform {
    type Err = ResolveError;

    fn from_str(s: &str) -> Result<Platform, ResolveError> {
        match s {
            "linux" => Ok(Platform::Linux),
            "macos" => Ok(Platform::MacOs),
            "windows" => Ok(Platform::Windows),
            _ => Err(ResolveError::BadPlatform),
        }
    }
}

/// `real` or `mock`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Real,
    Mock,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Real => "real",
            Mode::Mock => "mock",
        }
    }

    pub(crate) fn parse(s: &str) -> Option<Mode> {
        match s {
            "real" => Some(Mode::Real),
            "mock" => Some(Mode::Mock),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveError {
    /// A Windows default needed `LOCALAPPDATA`, `APPDATA` or `TEMP` and it was unset or empty.
    MissingEnv,
    /// `<PREFIX>_MODE` or `APP_CONTEXT_MODE` held something other than `real` or `mock`.
    BadMode,
    /// A platform name other than the three in the spec. Not in the spec; the Rust crate's choice.
    BadPlatform,
}

impl ResolveError {
    pub fn code(self) -> &'static str {
        match self {
            ResolveError::MissingEnv => "missing-env",
            ResolveError::BadMode => "bad-mode",
            ResolveError::BadPlatform => "bad-platform",
        }
    }
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cannot resolve app context: {}", self.code())
    }
}

impl std::error::Error for ResolveError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dirs {
    pub data: String,
    pub config: String,
    pub state: String,
    pub cache: String,
    pub runtime: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub prefix: String,
    pub dirs: Dirs,
    pub roster: String,
    pub scratch: bool,
    pub mode: Mode,
}

/// The environment as a plain map, so tests need no process state.
pub type Env = HashMap<String, String>;

/// An env var that counts as set only when non-empty.
fn var<'a>(env: &'a Env, key: &str) -> Option<&'a str> {
    env.get(key).map(String::as_str).filter(|v| !v.is_empty())
}

/// Drops trailing separators. On Windows both `\` and `/` count as separators.
fn trim_trailing(s: &str, platform: Platform) -> &str {
    if platform == Platform::Windows {
        s.trim_end_matches(['/', '\\'])
    } else {
        s.trim_end_matches('/')
    }
}

/// Joins `base` and `parts` with the platform separator, trimming a trailing separator on `base`.
fn join(platform: Platform, base: &str, parts: &[&str]) -> String {
    join_with(platform, platform.sep(), base, parts)
}

fn join_with(platform: Platform, sep: char, base: &str, parts: &[&str]) -> String {
    let mut out = trim_trailing(base, platform).to_string();
    for part in parts {
        out.push(sep);
        out.push_str(part);
    }
    out
}

/// A Windows root variable, required only when a default that needs it is used.
fn win_env<'a>(env: &'a Env, key: &str) -> Result<&'a str, ResolveError> {
    var(env, key).ok_or(ResolveError::MissingEnv)
}

#[derive(Clone, Copy)]
enum Kind {
    Data,
    Config,
    State,
    Cache,
    Runtime,
}

impl Kind {
    fn lower(self) -> &'static str {
        match self {
            Kind::Data => "data",
            Kind::Config => "config",
            Kind::State => "state",
            Kind::Cache => "cache",
            Kind::Runtime => "runtime",
        }
    }
}

/// The platform default for one directory kind.
fn platform_default(
    kind: Kind,
    platform: Platform,
    id: &str,
    home: &str,
    env: &Env,
) -> Result<String, ResolveError> {
    match platform {
        Platform::Linux => {
            // (XDG variable, fallback under home, then the app id)
            let xdg = |key: &str, fallback: &str| -> String {
                let base = match var(env, key) {
                    Some(b) => trim_trailing(b, platform).to_string(),
                    None => join(platform, home, &[fallback]),
                };
                join(platform, &base, &[id])
            };
            Ok(match kind {
                Kind::Data => xdg("XDG_DATA_HOME", ".local/share"),
                Kind::Config => xdg("XDG_CONFIG_HOME", ".config"),
                Kind::State => xdg("XDG_STATE_HOME", ".local/state"),
                Kind::Cache => xdg("XDG_CACHE_HOME", ".cache"),
                Kind::Runtime => match var(env, "XDG_RUNTIME_DIR") {
                    Some(r) => join(platform, r, &[id]),
                    // The fixture "hyphen-in-id" shows this is the DEFAULT state dir
                    // plus /run, even when state itself is overridden.
                    None => join(
                        platform,
                        &platform_default(Kind::State, platform, id, home, env)?,
                        &["run"],
                    ),
                },
            })
        }
        Platform::MacOs => {
            let lib = join(platform, home, &["Library"]);
            Ok(match kind {
                Kind::Data => join(platform, &lib, &["Application Support", id, "data"]),
                Kind::Config => join(platform, &lib, &["Preferences", id]),
                Kind::State => join(platform, &lib, &["Application Support", id, "state"]),
                Kind::Cache => join(platform, &lib, &["Caches", id]),
                Kind::Runtime => join(platform, var(env, "TMPDIR").unwrap_or("/tmp"), &[id]),
            })
        }
        Platform::Windows => Ok(match kind {
            Kind::Data => join(platform, win_env(env, "LOCALAPPDATA")?, &[id, "data"]),
            Kind::Config => join(platform, win_env(env, "APPDATA")?, &[id]),
            Kind::State => join(platform, win_env(env, "LOCALAPPDATA")?, &[id, "state"]),
            Kind::Cache => join(platform, win_env(env, "LOCALAPPDATA")?, &[id, "cache"]),
            Kind::Runtime => join(platform, win_env(env, "TEMP")?, &[id]),
        }),
    }
}

fn default_roster(platform: Platform, env: &Env) -> Result<String, ResolveError> {
    Ok(match platform {
        Platform::Linux => join(
            platform,
            var(env, "XDG_RUNTIME_DIR").unwrap_or("/tmp"),
            &["app-context-roster"],
        ),
        Platform::MacOs => join(
            platform,
            var(env, "TMPDIR").unwrap_or("/tmp"),
            &["app-context-roster"],
        ),
        Platform::Windows => join(platform, win_env(env, "TEMP")?, &["app-context-roster"]),
    })
}

/// The env prefix: the manifest's `envPrefix`, else the upper-cased last id segment with every
/// character outside `A-Z0-9` replaced by `_`.
pub fn prefix_for(manifest: &Manifest) -> String {
    match &manifest.env_prefix {
        Some(p) => p.clone(),
        None => manifest
            .id_last_segment()
            .chars()
            .map(|c| c.to_ascii_uppercase())
            .map(|c| {
                if c.is_ascii_uppercase() || c.is_ascii_digit() {
                    c
                } else {
                    '_'
                }
            })
            .collect(),
    }
}

/// Resolves the app context. Pure: the same inputs always give the same answer.
pub fn resolve(
    manifest: &Manifest,
    platform: Platform,
    home: &str,
    env: &Env,
) -> Result<Resolved, ResolveError> {
    let prefix = prefix_for(manifest);
    let id = manifest.id.as_str();

    let mode_value = var(env, &format!("{prefix}_MODE")).or_else(|| var(env, "APP_CONTEXT_MODE"));
    let mode = match mode_value {
        None => Mode::Real,
        Some(v) => Mode::parse(v).ok_or(ResolveError::BadMode)?,
    };

    let scratch_root = var(env, "APP_CONTEXT_SCRATCH");

    let dir = |kind: Kind| -> Result<String, ResolveError> {
        let override_key = format!("{prefix}_{}_DIR", kind.lower().to_ascii_uppercase());
        if let Some(exact) = var(env, &override_key) {
            Ok(exact.to_string())
        } else if let Some(s) = scratch_root {
            // Scratch joins with '/' on every platform.
            Ok(join_with(platform, '/', s, &[id, kind.lower()]))
        } else {
            platform_default(kind, platform, id, home, env)
        }
    };
    let dirs = Dirs {
        data: dir(Kind::Data)?,
        config: dir(Kind::Config)?,
        state: dir(Kind::State)?,
        cache: dir(Kind::Cache)?,
        runtime: dir(Kind::Runtime)?,
    };

    let roster = if let Some(exact) = var(env, "APP_CONTEXT_ROSTER_DIR") {
        exact.to_string()
    } else if let Some(s) = scratch_root {
        join_with(platform, '/', s, &["roster"])
    } else {
        default_roster(platform, env)?
    };

    Ok(Resolved {
        prefix,
        dirs,
        roster,
        scratch: scratch_root.is_some(),
        mode,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn calc() -> Manifest {
        Manifest::from_value(&serde_json::json!(
            {"id": "com.slashbuilder.demo.calc", "name": "Calc", "version": "0.1.0"}
        ))
        .unwrap()
    }

    fn env(pairs: &[(&str, &str)]) -> Env {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    // Choices the fixtures do not pin down (the Rust crate's choices).

    #[test]
    fn a_root_directory_base_joins_without_a_double_separator() {
        let r = resolve(
            &calc(),
            Platform::Linux,
            "/home/user",
            &env(&[("XDG_DATA_HOME", "/")]),
        );
        assert_eq!(r.unwrap().dirs.data, "/com.slashbuilder.demo.calc");
    }

    #[test]
    fn a_backslash_is_not_a_separator_on_linux() {
        let r = resolve(
            &calc(),
            Platform::Linux,
            "/home/user",
            &env(&[("XDG_DATA_HOME", "/x\\")]),
        );
        assert_eq!(r.unwrap().dirs.data, "/x\\/com.slashbuilder.demo.calc");
    }

    #[test]
    fn overrides_are_used_exactly_as_given_even_with_a_trailing_slash() {
        let r = resolve(
            &calc(),
            Platform::Linux,
            "/h",
            &env(&[("CALC_DATA_DIR", "/o/")]),
        );
        assert_eq!(r.unwrap().dirs.data, "/o/");
    }

    #[test]
    fn windows_needs_no_env_when_everything_is_overridden() {
        let e = env(&[
            ("CALC_DATA_DIR", "D:\\d"),
            ("CALC_CONFIG_DIR", "D:\\c"),
            ("CALC_STATE_DIR", "D:\\s"),
            ("CALC_CACHE_DIR", "D:\\k"),
            ("CALC_RUNTIME_DIR", "D:\\r"),
            ("APP_CONTEXT_ROSTER_DIR", "D:\\roster"),
        ]);
        assert!(resolve(&calc(), Platform::Windows, "C:\\u", &e).is_ok());
        // ...but the roster default still needs TEMP.
        let mut e = e;
        e.remove("APP_CONTEXT_ROSTER_DIR");
        assert_eq!(
            resolve(&calc(), Platform::Windows, "C:\\u", &e),
            Err(ResolveError::MissingEnv)
        );
    }

    #[test]
    fn a_bad_global_mode_is_ignored_when_the_app_mode_is_set() {
        let e = env(&[("APP_CONTEXT_MODE", "garbage"), ("CALC_MODE", "real")]);
        assert_eq!(
            resolve(&calc(), Platform::Linux, "/h", &e).unwrap().mode,
            Mode::Real
        );
    }

    #[test]
    fn unknown_platform_names_are_rejected() {
        assert_eq!("plan9".parse::<Platform>(), Err(ResolveError::BadPlatform));
    }
}
