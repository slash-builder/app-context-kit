//! The root namespace for one running app: who it is, where its things live, its settings, its
//! place in the roster and its Venue session. Spec sections 3 and 4.

use std::fmt;
use std::fs;
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use crate::config_store::ConfigStore;
use crate::manifest::{Manifest, VenueMode};
use crate::resolve::{resolve, Env, Mode, Platform, ResolveError, Resolved};
use crate::roster::{new_instance_id, Announcement, Roster, HEARTBEAT};
use crate::venue::{FakeVenue, LocalVenue, VenueError, VenueSession};

/// How much a [`Note`] matters to the person (spec section 5, item 9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    /// Nothing is wrong: what Venue is, that it is off.
    Info,
    /// Something is degraded but the app works: a damaged settings file, Venue not answering.
    Warning,
    /// Something failed outright. Nothing in `open` produces one yet (a degraded Venue is a
    /// warning); it is part of the vocabulary so apps and the Flutter banner can use it.
    Error,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Info => "info",
            Severity::Warning => "warning",
            Severity::Error => "error",
        }
    }
}

/// Something worth telling the person, in plain words, with how much it matters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    pub severity: Severity,
    pub text: String,
}

impl Note {
    pub fn new(severity: Severity, text: impl Into<String>) -> Note {
        Note {
            severity,
            text: text.into(),
        }
    }
}

/// One thing that went wrong while closing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloseError {
    /// What was being closed: `roster`, `hook`, or `venue`.
    pub what: &'static str,
    pub message: String,
}

/// Everything that went wrong in one `close()`, raised together after every step ran.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloseErrors(pub Vec<CloseError>);

impl fmt::Display for CloseErrors {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} error(s) while closing:", self.0.len())?;
        for e in &self.0 {
            write!(f, " [{}: {}]", e.what, e.message)?;
        }
        Ok(())
    }
}

impl std::error::Error for CloseErrors {}

#[derive(Debug)]
pub enum ContextError {
    Resolve(ResolveError),
    Io {
        path: PathBuf,
        source: io::Error,
    },
    Venue(VenueError),
    /// The body of [`AppContext::run`] finished (its value is dropped) but closing failed.
    Close(CloseErrors),
}

impl fmt::Display for ContextError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ContextError::Resolve(e) => write!(f, "{e}"),
            ContextError::Io { path, source } => write!(f, "{}: {source}", path.display()),
            ContextError::Venue(e) => write!(f, "{e}"),
            ContextError::Close(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for ContextError {}

impl From<ResolveError> for ContextError {
    fn from(e: ResolveError) -> Self {
        ContextError::Resolve(e)
    }
}

impl From<VenueError> for ContextError {
    fn from(e: VenueError) -> Self {
        ContextError::Venue(e)
    }
}

/// Everything `open` can be told instead of reading the host. All fields are optional.
pub struct OpenOptions {
    /// Defaults to the process environment.
    pub env: Option<Env>,
    /// Defaults to the host platform.
    pub platform: Option<Platform>,
    /// Defaults to `HOME`, then `USERPROFILE`, then `/`.
    pub home: Option<String>,
    /// Write a presence file and heartbeat. Default true.
    pub announce: bool,
    pub heartbeat: Duration,
    /// How many holds the in-memory fake Venue grants at once in `mock` mode. Default 1. This is a
    /// parameter, not an environment variable (spec section 5, item 8).
    pub fake_capacity: usize,
    /// Use this session instead of choosing one (a test seam, like the Dart `transport`).
    pub venue: Option<Arc<dyn VenueSession>>,
}

impl Default for OpenOptions {
    fn default() -> Self {
        OpenOptions {
            env: None,
            platform: None,
            home: None,
            announce: true,
            heartbeat: HEARTBEAT,
            fake_capacity: 1,
            venue: None,
        }
    }
}

/// A close hook: an error (or a panic) is reported but does not stop the others.
type CloseHook = Box<dyn FnOnce() -> Result<(), String> + Send>;

pub struct AppContext {
    pub manifest: Manifest,
    pub resolved: Resolved,
    pub env: Env,
    pub config: ConfigStore,
    pub roster: Roster,
    pub venue: Arc<dyn VenueSession>,
    /// This context's random 8-hex-digit instance id (the `@INSTANCE` in its roster file name).
    pub instance: String,
    /// Things worth telling the person, in plain words, each with a severity (a damaged settings
    /// file, Venue not answering).
    pub notes: Vec<Note>,
    announcement: Option<Announcement>,
    on_close: Vec<CloseHook>,
    closed: bool,
}

fn nonempty<'a>(env: &'a Env, key: &str) -> Option<&'a str> {
    env.get(key).map(String::as_str).filter(|v| !v.is_empty())
}

impl AppContext {
    /// Resolve, create the directories, read settings, announce in the roster, open Venue.
    pub fn open(manifest: Manifest, opts: OpenOptions) -> Result<AppContext, ContextError> {
        let env = opts
            .env
            .unwrap_or_else(|| std::env::vars().collect::<Env>());
        let platform = opts.platform.unwrap_or_else(Platform::host);
        let home = opts
            .home
            .or_else(|| nonempty(&env, "HOME").map(str::to_string))
            .or_else(|| nonempty(&env, "USERPROFILE").map(str::to_string))
            .unwrap_or_else(|| "/".to_string());

        let resolved = resolve(&manifest, platform, &home, &env)?;
        for d in [
            &resolved.dirs.data,
            &resolved.dirs.config,
            &resolved.dirs.state,
            &resolved.dirs.cache,
            &resolved.dirs.runtime,
        ] {
            fs::create_dir_all(d).map_err(|source| ContextError::Io {
                path: PathBuf::from(d),
                source,
            })?;
        }

        let instance = new_instance_id();
        let mut notes = Vec::new();
        let config = ConfigStore::open(Path::new(&resolved.dirs.config));
        if let Some(p) = config.problem() {
            notes.push(Note::new(
                Severity::Warning,
                format!("Settings: {p}. They will not be saved until the file is set aside."),
            ));
        }

        // Venue first: if it refuses to open (mode `on`), nothing has been announced yet, so nothing leaks.
        let (venue, venue_severity) = match opts.venue {
            Some(v) => (v, Severity::Info),
            None => open_venue(&manifest, &resolved, &env, opts.fake_capacity)?,
        };
        notes.push(Note::new(venue_severity, venue.description()));

        let roster = Roster::new(&resolved.roster);
        let announcement = if opts.announce {
            match roster.announce(
                &manifest.id,
                &instance,
                &manifest.name,
                &manifest.version,
                opts.heartbeat,
            ) {
                Ok(a) => Some(a),
                Err(source) => {
                    let _ = venue.close();
                    return Err(ContextError::Io {
                        path: PathBuf::from(&resolved.roster),
                        source,
                    });
                }
            }
        } else {
            None
        };

        Ok(AppContext {
            manifest,
            resolved,
            env,
            config,
            roster,
            venue,
            instance,
            notes,
            announcement,
            on_close: Vec::new(),
            closed: false,
        })
    }

    /// The whole life of an app: open, run, close. The context closes even if `body` panics (then
    /// by `Drop`, which cannot report errors). If `body` returns and closing fails, the result is
    /// [`ContextError::Close`] and the body's value is dropped.
    pub fn run<T>(
        manifest: Manifest,
        opts: OpenOptions,
        body: impl FnOnce(&mut AppContext) -> T,
    ) -> Result<T, ContextError> {
        let mut ctx = AppContext::open(manifest, opts)?;
        let value = body(&mut ctx);
        ctx.close().map_err(ContextError::Close)?;
        Ok(value)
    }

    pub fn mode(&self) -> Mode {
        self.resolved.mode
    }

    pub fn is_mock(&self) -> bool {
        self.resolved.mode == Mode::Mock
    }

    pub fn is_scratch(&self) -> bool {
        self.resolved.scratch
    }

    /// A file under the app's data directory.
    pub fn data_file(&self, name: &str) -> PathBuf {
        Path::new(&self.resolved.dirs.data).join(name)
    }

    /// Run `f` when the context closes (after the roster entry is withdrawn, before Venue goes).
    /// Hooks run last-registered first. A panic in `f` is caught and reported by `close` like an error.
    pub fn on_close(&mut self, f: impl FnOnce() + Send + 'static) {
        self.on_close_fallible(move || {
            f();
            Ok::<(), String>(())
        });
    }

    /// Like [`on_close`](Self::on_close) for a hook that can fail; its error is reported by `close`
    /// after every other hook has run.
    pub fn on_close_fallible<E: fmt::Display>(
        &mut self,
        f: impl FnOnce() -> Result<(), E> + Send + 'static,
    ) {
        self.on_close
            .push(Box::new(move || f().map_err(|e| e.to_string())));
    }

    /// Withdraws from the roster, runs every close hook (even if an earlier one failed or panicked),
    /// then closes Venue last. Every failure is returned together, after all of it ran.
    ///
    /// Idempotent: the second call does nothing and returns `Ok`. Also happens on drop (errors lost).
    pub fn close(&mut self) -> Result<(), CloseErrors> {
        let errors = self.close_inner();
        if errors.is_empty() {
            Ok(())
        } else {
            Err(CloseErrors(errors))
        }
    }

    /// True once `close` has run (or begun running).
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    fn close_inner(&mut self) -> Vec<CloseError> {
        if self.closed {
            return Vec::new();
        }
        self.closed = true;
        let mut errors = Vec::new();
        if let Some(a) = self.announcement.take() {
            if let Err(e) = a.withdraw() {
                errors.push(CloseError {
                    what: "roster",
                    message: e.to_string(),
                });
            }
        }
        while let Some(hook) = self.on_close.pop() {
            match catch_unwind(AssertUnwindSafe(hook)) {
                Ok(Ok(())) => {}
                Ok(Err(message)) => errors.push(CloseError {
                    what: "hook",
                    message,
                }),
                Err(panic) => errors.push(CloseError {
                    what: "hook",
                    message: format!("panicked: {}", panic_text(panic.as_ref())),
                }),
            }
        }
        // Venue goes last, so a hook can still use it.
        if let Err(e) = self.venue.close() {
            errors.push(CloseError {
                what: "venue",
                message: e.to_string(),
            });
        }
        errors
    }
}

fn panic_text(p: &(dyn std::any::Any + Send)) -> String {
    p.downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| p.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "(non-string panic)".to_string())
}

impl Drop for AppContext {
    fn drop(&mut self) {
        // Errors cannot be reported from here; call `close()` to see them.
        let _ = self.close_inner();
    }
}

/// The session chosen, and how loudly its description should be shown.
type Opened = (Arc<dyn VenueSession>, Severity);

/// Spec sections 3 and 5: mock gives the fake; `off` never connects; otherwise find a token and, if
/// the daemon answers, connect. `auto` degrades to a local session and says why; `on` fails.
/// Neither the token nor the daemon is looked at in `mock` or `off`.
fn open_venue(
    manifest: &Manifest,
    resolved: &Resolved,
    env: &Env,
    fake_capacity: usize,
) -> Result<Opened, ContextError> {
    if resolved.mode == Mode::Mock {
        return Ok((Arc::new(FakeVenue::new(fake_capacity)), Severity::Info));
    }
    let mode = manifest.venue_mode;
    if mode == VenueMode::Off {
        return Ok((
            Arc::new(LocalVenue::new("Venue is off for this app")),
            Severity::Info,
        ));
    }

    match find_token(env, &resolved.dirs.config) {
        TokenLookup::Found(_) => {}
        TokenLookup::Problem(problem) => {
            // A configuration error: no fall-through to <config>/venue-token.
            if mode == VenueMode::On {
                return Err(
                    VenueError::Unavailable(format!("Venue is required but {problem}")).into(),
                );
            }
            return Ok((Arc::new(LocalVenue::new(&problem)), Severity::Warning));
        }
        TokenLookup::NotFound => {
            if mode == VenueMode::On {
                return Err(VenueError::Unavailable(
                    "Venue is required but no token was found".to_string(),
                )
                .into());
            }
            return Ok((
                Arc::new(LocalVenue::new("Venue not configured")),
                Severity::Info,
            ));
        }
    }

    connect(mode)
}

/// This crate has no remote Venue session, so a token that was found cannot be used to reach a daemon. `auto`
/// degrades to a local session and says why; `on` fails to open. (The Dart core has the session that talks to a daemon.)
fn connect(mode: VenueMode) -> Result<Opened, ContextError> {
    if mode == VenueMode::On {
        return Err(VenueError::Unavailable(
            "Venue is required but this crate has no remote Venue session".to_string(),
        )
        .into());
    }
    Ok((
        Arc::new(LocalVenue::new("this crate has no remote Venue session")),
        Severity::Warning,
    ))
}

/// The result of looking for a Venue token.
#[derive(Debug, PartialEq, Eq)]
enum TokenLookup {
    Found(String),
    /// No token anywhere: Venue is simply not configured.
    NotFound,
    /// `VENUE_TOKEN_FILE` is set but unusable. Names the problem in a sentence fragment.
    Problem(String),
}

/// Token lookup order (spec section 5, item 2): `VENUE_TOKEN`; else the file named by
/// `VENUE_TOKEN_FILE`; else `<config>/venue-token`. An empty variable counts as unset. If
/// `VENUE_TOKEN_FILE` **is** set but the file is missing, empty or unreadable, that is a
/// configuration error and the lookup does **not** fall through to `<config>/venue-token`.
fn find_token(env: &Env, config_dir: &str) -> TokenLookup {
    if let Some(t) = nonempty(env, "VENUE_TOKEN") {
        return TokenLookup::Found(t.to_string());
    }
    if let Some(f) = nonempty(env, "VENUE_TOKEN_FILE") {
        let problem =
            |why: &str| TokenLookup::Problem(format!("VENUE_TOKEN_FILE is set to {f} but {why}"));
        return match fs::read_to_string(f) {
            Ok(text) if !text.trim().is_empty() => TokenLookup::Found(text.trim().to_string()),
            Ok(_) => problem("the file is empty"),
            Err(e) if e.kind() == io::ErrorKind::NotFound => problem("the file does not exist"),
            Err(e) if e.kind() == io::ErrorKind::InvalidData => {
                problem("the file is not valid text")
            }
            Err(e) => problem(&format!("the file cannot be read ({e})")),
        };
    }
    match fs::read_to_string(Path::new(config_dir).join("venue-token")) {
        Ok(text) if !text.trim().is_empty() => TokenLookup::Found(text.trim().to_string()),
        _ => TokenLookup::NotFound,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roster::STALE_AFTER;
    use crate::testutil::TempDir;
    use crate::venue::VenueNeed;
    use serde_json::json;
    use std::sync::Mutex;

    fn manifest(extra: serde_json::Value) -> Manifest {
        let mut m = json!({"id": "com.slashbuilder.demo.calc", "name": "Calc", "version": "0.1.0"});
        if let (Some(base), Some(more)) = (m.as_object_mut(), extra.as_object()) {
            base.extend(more.clone());
        }
        Manifest::from_value(&m).unwrap()
    }

    fn opts(tmp: &TempDir, more: &[(&str, &str)]) -> OpenOptions {
        let mut env = Env::new();
        env.insert(
            "APP_CONTEXT_SCRATCH".into(),
            tmp.path().to_string_lossy().into_owned(),
        );
        for (k, v) in more {
            env.insert((*k).into(), (*v).into());
        }
        OpenOptions {
            env: Some(env),
            platform: Some(Platform::Linux),
            home: Some("/nonexistent".into()),
            ..OpenOptions::default()
        }
    }

    /// Options with no roster file, for tests that are not about the roster.
    fn quiet(tmp: &TempDir, more: &[(&str, &str)]) -> OpenOptions {
        let mut o = opts(tmp, more);
        o.announce = false;
        o
    }

    fn open(tmp: &TempDir, more: &[(&str, &str)], m: serde_json::Value) -> AppContext {
        AppContext::open(manifest(m), quiet(tmp, more)).unwrap()
    }

    fn note_texts(ctx: &AppContext) -> Vec<(Severity, &str)> {
        ctx.notes
            .iter()
            .map(|n| (n.severity, n.text.as_str()))
            .collect()
    }

    #[test]
    fn open_creates_dirs_announces_and_closes_cleanly() {
        let tmp = TempDir::new("ctx-open");
        let mut ctx = AppContext::open(manifest(json!({})), opts(&tmp, &[])).unwrap();
        for d in [
            &ctx.resolved.dirs.data,
            &ctx.resolved.dirs.config,
            &ctx.resolved.dirs.state,
            &ctx.resolved.dirs.cache,
            &ctx.resolved.dirs.runtime,
        ] {
            assert!(Path::new(d).is_dir(), "{d}");
        }
        assert!(ctx.is_scratch());
        let roster = ctx.roster.clone();
        let running = roster.running(chrono::Utc::now(), STALE_AFTER);
        assert_eq!(running.len(), 1);
        assert_eq!(running[0].id, "com.slashbuilder.demo.calc");
        assert_eq!(running[0].instance.as_deref(), Some(ctx.instance.as_str()));
        ctx.close().unwrap();
        assert!(roster.running(chrono::Utc::now(), STALE_AFTER).is_empty());
    }

    // --- spec section 5, item 5: instance ids

    #[test]
    fn each_context_draws_its_own_instance_id_and_two_copies_coexist() {
        let tmp = TempDir::new("ctx-instances");
        let mut a = AppContext::open(manifest(json!({})), opts(&tmp, &[])).unwrap();
        let mut b = AppContext::open(manifest(json!({})), opts(&tmp, &[])).unwrap();
        assert_ne!(a.instance, b.instance);
        assert_eq!(a.instance.len(), 8);
        assert!(a.instance.bytes().all(|c| c.is_ascii_hexdigit()));
        let roster = a.roster.clone();
        let now = chrono::Utc::now();
        assert_eq!(roster.running(now, STALE_AFTER).len(), 2);
        assert!(roster
            .dir()
            .join(format!("com.slashbuilder.demo.calc@{}.json", a.instance))
            .exists());

        // The first to exit takes only its own file; the survivor is still there at once.
        a.close().unwrap();
        let left = roster.running(chrono::Utc::now(), STALE_AFTER);
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].instance.as_deref(), Some(b.instance.as_str()));
        b.close().unwrap();
        assert!(roster.running(chrono::Utc::now(), STALE_AFTER).is_empty());
    }

    #[test]
    fn a_context_has_an_instance_id_even_without_a_roster_entry() {
        let tmp = TempDir::new("ctx-inst-quiet");
        let ctx = open(&tmp, &[], json!({}));
        assert_eq!(ctx.instance.len(), 8);
        assert!(!tmp.path().join("roster").exists());
    }

    // --- spec section 5, item 3: damaged config

    #[test]
    fn config_round_trips_and_a_corrupt_file_is_reported_not_replaced() {
        let tmp = TempDir::new("ctx-cfg");
        let mut ctx = open(&tmp, &[], json!({}));
        ctx.config.set("fontSize", json!(14)).unwrap();
        ctx.close().unwrap();

        let ctx = open(&tmp, &[], json!({}));
        assert_eq!(ctx.config.get_or("fontSize", 0), 14);
        let file = Path::new(&ctx.resolved.dirs.config).join("config.json");
        drop(ctx);
        fs::write(&file, "{not json").unwrap();

        let mut ctx = open(&tmp, &[], json!({}));
        assert!(ctx.config.problem().is_some());
        assert!(ctx
            .notes
            .iter()
            .any(|n| n.severity == Severity::Warning && n.text.starts_with("Settings:")));
        assert!(ctx.config.set("x", json!(1)).is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "{not json");
    }

    #[test]
    fn a_non_utf8_config_opens_with_a_warning_and_refuses_to_save_until_set_aside() {
        let tmp = TempDir::new("ctx-cfg-utf8");
        let ctx = open(&tmp, &[], json!({}));
        let file = Path::new(&ctx.resolved.dirs.config).join("config.json");
        drop(ctx);
        fs::write(&file, [b'{', 0xff, 0xfe, b'}']).unwrap();

        let mut ctx = open(&tmp, &[], json!({}));
        assert!(ctx
            .notes
            .iter()
            .any(|n| n.severity == Severity::Warning && n.text.contains("UTF-8")));
        assert!(matches!(
            ctx.config.set("x", json!(1)),
            Err(crate::ConfigError::Damaged(_))
        ));
        assert_eq!(fs::read(&file).unwrap(), [b'{', 0xff, 0xfe, b'}']);
        let aside = ctx.config.set_aside_corrupt().unwrap().unwrap();
        assert!(aside.ends_with("config.json.corrupt"));
        ctx.config.set("x", json!(1)).unwrap();
    }

    #[test]
    fn bad_mode_is_a_resolve_error() {
        let tmp = TempDir::new("ctx-badmode");
        let r = AppContext::open(manifest(json!({})), opts(&tmp, &[("CALC_MODE", "fake")]));
        assert!(matches!(
            r,
            Err(ContextError::Resolve(ResolveError::BadMode))
        ));
    }

    // --- Venue selection and spec section 5, item 2: token lookup

    #[test]
    fn with_no_token_auto_degrades_to_a_local_venue_and_says_so() {
        let tmp = TempDir::new("ctx-local");
        let ctx = open(&tmp, &[], json!({}));
        assert_eq!(ctx.venue.kind(), "local");
        assert!(ctx.venue.description().contains("not configured"));
        // Not a problem, so only info.
        assert_eq!(
            note_texts(&ctx),
            [(Severity::Info, "Venue: local (Venue not configured)")]
        );
    }

    #[test]
    fn venue_off_never_connects_even_with_a_token() {
        let tmp = TempDir::new("ctx-off");
        let ctx = open(
            &tmp,
            &[("VENUE_TOKEN", "t")],
            json!({"venue": {"mode": "off"}}),
        );
        assert_eq!(ctx.venue.kind(), "local");
        assert!(ctx.venue.description().contains("off"));
    }

    #[test]
    fn venue_mode_on_with_no_token_refuses_to_open() {
        let tmp = TempDir::new("ctx-on");
        let r = AppContext::open(manifest(json!({"venue": {"mode": "on"}})), quiet(&tmp, &[]));
        assert!(matches!(r, Err(ContextError::Venue(_))));
    }

    fn lookup(env: &[(&str, &str)], cfg: &str) -> TokenLookup {
        let env: Env = env
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        find_token(&env, cfg)
    }

    #[test]
    fn token_lookup_order_env_then_file_then_config_dir() {
        let tmp = TempDir::new("ctx-token");
        let cfg = tmp.path().join("cfg");
        fs::create_dir_all(&cfg).unwrap();
        let cfg_s = cfg.to_string_lossy().into_owned();
        assert_eq!(lookup(&[], &cfg_s), TokenLookup::NotFound);
        fs::write(cfg.join("venue-token"), "from-config\n").unwrap();
        assert_eq!(
            lookup(&[], &cfg_s),
            TokenLookup::Found("from-config".into())
        );
        let tf = tmp.path().join("tok");
        fs::write(&tf, " from-file \n").unwrap();
        let tf_s = tf.to_string_lossy().into_owned();
        assert_eq!(
            lookup(&[("VENUE_TOKEN_FILE", &tf_s)], &cfg_s),
            TokenLookup::Found("from-file".into())
        );
        assert_eq!(
            lookup(
                &[("VENUE_TOKEN_FILE", &tf_s), ("VENUE_TOKEN", "from-env")],
                &cfg_s
            ),
            TokenLookup::Found("from-env".into())
        );
        // empty means unset, for both variables
        assert_eq!(
            lookup(&[("VENUE_TOKEN_FILE", &tf_s), ("VENUE_TOKEN", "")], &cfg_s),
            TokenLookup::Found("from-file".into())
        );
        assert_eq!(
            lookup(&[("VENUE_TOKEN_FILE", "")], &cfg_s),
            TokenLookup::Found("from-config".into())
        );
    }

    #[test]
    fn a_token_file_that_is_set_but_missing_or_empty_does_not_fall_through() {
        let tmp = TempDir::new("ctx-token-nofall");
        let cfg = tmp.path().join("cfg");
        fs::create_dir_all(&cfg).unwrap();
        let cfg_s = cfg.to_string_lossy().into_owned();
        // A perfectly good token sits in <config>/venue-token the whole time.
        fs::write(cfg.join("venue-token"), "from-config\n").unwrap();

        let missing = tmp.path().join("nope").to_string_lossy().into_owned();
        match lookup(&[("VENUE_TOKEN_FILE", &missing)], &cfg_s) {
            TokenLookup::Problem(p) => {
                assert!(
                    p.contains("VENUE_TOKEN_FILE") && p.contains(&missing),
                    "{p}"
                );
                assert!(p.contains("the file does not exist"), "{p}");
            }
            other => panic!("expected a problem, got {other:?}"),
        }

        let empty = tmp.path().join("empty");
        fs::write(&empty, " \n").unwrap();
        let empty_s = empty.to_string_lossy().into_owned();
        match lookup(&[("VENUE_TOKEN_FILE", &empty_s)], &cfg_s) {
            TokenLookup::Problem(p) => assert!(p.contains("the file is empty"), "{p}"),
            other => panic!("expected a problem, got {other:?}"),
        }

        // A directory (or anything unreadable) is a problem as well; non-UTF-8 too.
        let dir_s = cfg_s.clone();
        assert!(matches!(
            lookup(&[("VENUE_TOKEN_FILE", &dir_s)], &cfg_s),
            TokenLookup::Problem(_)
        ));
        let binary = tmp.path().join("bin");
        fs::write(&binary, [0xff, 0xfe]).unwrap();
        assert!(matches!(
            lookup(&[("VENUE_TOKEN_FILE", &binary.to_string_lossy())], &cfg_s),
            TokenLookup::Problem(_)
        ));

        // VENUE_TOKEN still wins over a broken file.
        assert_eq!(
            lookup(
                &[("VENUE_TOKEN_FILE", &missing), ("VENUE_TOKEN", "t")],
                &cfg_s
            ),
            TokenLookup::Found("t".into())
        );
    }

    #[test]
    fn auto_with_a_missing_token_file_degrades_to_local_and_names_the_problem() {
        let tmp = TempDir::new("ctx-tf-auto");
        let missing = tmp.path().join("nope").to_string_lossy().into_owned();
        // The config dir holds a usable token that must NOT be picked up.
        let cfg = tmp.path().join("com.slashbuilder.demo.calc").join("config");
        fs::create_dir_all(&cfg).unwrap();
        fs::write(cfg.join("venue-token"), "from-config").unwrap();

        let ctx = open(&tmp, &[("VENUE_TOKEN_FILE", &missing)], json!({}));
        assert_eq!(ctx.venue.kind(), "local");
        let d = ctx.venue.description();
        assert!(
            d.contains("VENUE_TOKEN_FILE") && d.contains("does not exist"),
            "{d}"
        );
        assert!(d.contains(&missing), "{d}");
        // The degraded session is a warning, and the note carries the same words.
        assert_eq!(note_texts(&ctx), [(Severity::Warning, d.as_str())]);
    }

    #[test]
    fn on_with_an_empty_token_file_fails_to_open() {
        let tmp = TempDir::new("ctx-tf-on");
        let empty = tmp.path().join("empty");
        fs::write(&empty, "").unwrap();
        let empty_s = empty.to_string_lossy().into_owned();
        let r = AppContext::open(
            manifest(json!({"venue": {"mode": "on"}})),
            quiet(&tmp, &[("VENUE_TOKEN_FILE", &empty_s)]),
        );
        match r {
            Err(ContextError::Venue(VenueError::Unavailable(m))) => {
                assert!(
                    m.contains("VENUE_TOKEN_FILE") && m.contains("is empty"),
                    "{m}"
                )
            }
            other => panic!("expected a Venue error, got {:?}", other.err()),
        }
    }

    #[test]
    fn a_broken_token_file_is_not_looked_at_in_mock_or_off() {
        let tmp = TempDir::new("ctx-tf-skip");
        let missing = tmp.path().join("nope").to_string_lossy().into_owned();
        let ctx = open(
            &tmp,
            &[("VENUE_TOKEN_FILE", &missing), ("CALC_MODE", "mock")],
            json!({"venue": {"mode": "on"}}),
        );
        assert_eq!(ctx.venue.kind(), "fake");
        let ctx = open(
            &tmp,
            &[("VENUE_TOKEN_FILE", &missing)],
            json!({"venue": {"mode": "off"}}),
        );
        assert!(ctx.venue.description().contains("off"));
        assert_eq!(note_texts(&ctx)[0].0, Severity::Info);
    }

    #[test]
    fn a_token_cannot_connect_because_the_crate_has_no_remote_session() {
        let tmp = TempDir::new("ctx-noremote");
        let with_token = [("VENUE_TOKEN", "t")];
        let ctx = open(&tmp, &with_token, json!({}));
        assert_eq!(ctx.venue.kind(), "local");
        assert!(ctx.venue.description().contains("no remote Venue session"));
        assert_eq!(note_texts(&ctx)[0].0, Severity::Warning);

        let r = AppContext::open(
            manifest(json!({"venue": {"mode": "on"}})),
            quiet(&tmp, &with_token),
        );
        assert!(matches!(r, Err(ContextError::Venue(_))));
    }

    #[test]
    fn mock_mode_gives_the_fake_and_with_hold_runs_in_order() {
        let tmp = TempDir::new("ctx-mock");
        let fake = Arc::new(FakeVenue::new(1));
        let mut o = quiet(&tmp, &[("CALC_MODE", "mock")]);
        o.venue = Some(fake.clone());
        let ctx = AppContext::open(manifest(json!({})), o).unwrap();
        assert!(ctx.is_mock());
        let need = VenueNeed::new("j1", "container.run.v1");
        let r = ctx.venue.with_hold(&need, 300, |h| h.name.clone()).unwrap();
        assert_eq!(r, "j1");
        assert_eq!(fake.log(), ["hold j1", "start j1", "release j1"]);
    }

    #[test]
    fn mock_mode_without_an_override_picks_the_fake() {
        let tmp = TempDir::new("ctx-mock2");
        let ctx = open(
            &tmp,
            &[("CALC_MODE", "mock"), ("VENUE_TOKEN", "t")],
            json!({}),
        );
        assert_eq!(ctx.venue.kind(), "fake");
    }

    // --- spec section 5, item 8: fake capacity is a parameter

    #[test]
    fn fake_capacity_is_a_parameter_and_defaults_to_one() {
        let tmp = TempDir::new("ctx-cap");
        let need = |n: &str| VenueNeed::new(n, "container.run.v1");

        let ctx = open(&tmp, &[("CALC_MODE", "mock")], json!({}));
        let _a = ctx.venue.hold(&need("a"), 60).unwrap();
        assert!(
            ctx.venue.hold(&need("b"), 60).is_err(),
            "default capacity is 1"
        );

        let mut o = quiet(&tmp, &[("CALC_MODE", "mock")]);
        o.fake_capacity = 3;
        let ctx = AppContext::open(manifest(json!({})), o).unwrap();
        let held: Vec<_> = ["a", "b", "c"]
            .iter()
            .map(|n| ctx.venue.hold(&need(n), 60).unwrap())
            .collect();
        assert_eq!(held.len(), 3);
        assert_eq!(
            ctx.venue.hold(&need("d"), 60).unwrap_err().refusal_kind(),
            Some(crate::RefusalKind::DoesNotFit)
        );
    }

    #[test]
    fn an_environment_variable_does_not_set_the_fake_capacity() {
        let tmp = TempDir::new("ctx-cap-env");
        let ctx = open(
            &tmp,
            &[
                ("CALC_MODE", "mock"),
                ("CALC_FAKE_CAPACITY", "5"),
                ("APP_CONTEXT_FAKE_CAPACITY", "5"),
                ("VENUE_FAKE_CAPACITY", "5"),
            ],
            json!({}),
        );
        let need = |n: &str| VenueNeed::new(n, "container.run.v1");
        let _a = ctx.venue.hold(&need("a"), 60).unwrap();
        assert!(ctx.venue.hold(&need("b"), 60).is_err());
    }

    // --- spec section 5, item 4: idempotent close, isolated hooks

    #[test]
    fn close_hooks_run_last_first_and_on_drop() {
        let tmp = TempDir::new("ctx-hooks");
        let order = Arc::new(Mutex::new(Vec::new()));
        {
            let mut ctx = open(&tmp, &[], json!({}));
            for n in 1..=2 {
                let order = order.clone();
                ctx.on_close(move || order.lock().unwrap().push(n));
            }
        }
        assert_eq!(*order.lock().unwrap(), [2, 1]);
    }

    #[test]
    fn close_is_idempotent_the_second_call_does_nothing() {
        let tmp = TempDir::new("ctx-idem");
        let fake = Arc::new(FakeVenue::new(1));
        let mut o = opts(&tmp, &[]);
        o.venue = Some(fake.clone());
        let mut ctx = AppContext::open(manifest(json!({})), o).unwrap();
        let ran = Arc::new(Mutex::new(0));
        let r = ran.clone();
        ctx.on_close(move || *r.lock().unwrap() += 1);
        assert!(!ctx.is_closed());
        ctx.close().unwrap();
        assert!(ctx.is_closed());
        ctx.close().unwrap();
        drop(ctx); // and a third time, via Drop
        assert_eq!(*ran.lock().unwrap(), 1);
        assert_eq!(fake.log(), ["close"], "Venue closed exactly once");
    }

    #[test]
    fn every_hook_runs_when_one_fails_or_panics_and_the_errors_come_back_together() {
        let tmp = TempDir::new("ctx-isolate");
        let fake = Arc::new(FakeVenue::new(1));
        let mut o = quiet(&tmp, &[]);
        o.venue = Some(fake.clone());
        let mut ctx = AppContext::open(manifest(json!({})), o).unwrap();
        let ran = Arc::new(Mutex::new(Vec::new()));

        let r = ran.clone();
        ctx.on_close(move || r.lock().unwrap().push("first-registered"));
        let r = ran.clone();
        ctx.on_close_fallible(move || {
            r.lock().unwrap().push("returns-error");
            Err::<(), _>("disk on fire")
        });
        let r = ran.clone();
        ctx.on_close(move || {
            r.lock().unwrap().push("panics");
            panic!("hook exploded");
        });
        let r = ran.clone();
        ctx.on_close(move || r.lock().unwrap().push("last-registered"));

        let errs = ctx.close().unwrap_err();
        // All four ran, last registered first.
        assert_eq!(
            *ran.lock().unwrap(),
            [
                "last-registered",
                "panics",
                "returns-error",
                "first-registered"
            ]
        );
        // Both failures are raised together, in the order they happened.
        assert_eq!(errs.0.len(), 2, "{errs}");
        assert_eq!(errs.0[0].what, "hook");
        assert!(errs.0[0].message.contains("hook exploded"), "{errs}");
        assert!(errs.0[1].message.contains("disk on fire"), "{errs}");
        // Venue still closed, and a second close reports nothing.
        assert_eq!(fake.log(), ["close"]);
        assert!(ctx.close().is_ok());
    }

    #[test]
    fn venue_is_closed_last_after_every_hook_and_the_roster_withdrawal() {
        let tmp = TempDir::new("ctx-venue-last");
        let fake = Arc::new(FakeVenue::new(1));
        let mut o = opts(&tmp, &[]);
        o.venue = Some(fake.clone());
        let mut ctx = AppContext::open(manifest(json!({})), o).unwrap();
        let roster_file = ctx
            .roster
            .dir()
            .join(format!("com.slashbuilder.demo.calc@{}.json", ctx.instance));
        // Each hook records what it sees: the venue's log at that moment and whether the roster file is gone.
        let seen = Arc::new(Mutex::new(Vec::new()));
        for n in 0..2 {
            let (seen, fake, file) = (seen.clone(), fake.clone(), roster_file.clone());
            ctx.on_close(move || {
                seen.lock().unwrap().push((n, fake.log(), file.exists()));
            });
        }
        assert!(roster_file.exists());
        ctx.close().unwrap();
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        for (_, log, roster_present) in seen.iter() {
            assert!(
                log.is_empty(),
                "Venue was closed before a hook ran: {log:?}"
            );
            assert!(
                !roster_present,
                "the roster entry is withdrawn before hooks"
            );
        }
        assert_eq!(fake.log(), ["close"]);
    }

    #[test]
    fn a_venue_that_fails_to_close_is_reported_after_the_hooks_ran() {
        struct BadClose;
        impl VenueSession for BadClose {
            fn kind(&self) -> &'static str {
                "fake"
            }
            fn description(&self) -> String {
                "bad".into()
            }
            fn hold(&self, _: &VenueNeed, _: u32) -> Result<crate::VenueHold, VenueError> {
                Err(VenueError::Unavailable("no".into()))
            }
            fn start(&self, _: &crate::VenueHold) -> Result<(), VenueError> {
                Ok(())
            }
            fn renew(&self, _: &crate::VenueHold) -> Result<(), VenueError> {
                Ok(())
            }
            fn release(&self, _: crate::VenueHold) -> Result<(), VenueError> {
                Ok(())
            }
            fn nodes(&self) -> Result<Vec<serde_json::Value>, VenueError> {
                Ok(vec![])
            }
            fn holds(&self) -> Result<Vec<crate::VenueHold>, VenueError> {
                Ok(vec![])
            }
            fn close(&self) -> Result<(), VenueError> {
                Err(VenueError::Unavailable("socket stuck".into()))
            }
        }
        let tmp = TempDir::new("ctx-badclose");
        let mut o = quiet(&tmp, &[]);
        o.venue = Some(Arc::new(BadClose));
        let mut ctx = AppContext::open(manifest(json!({})), o).unwrap();
        let ran = Arc::new(Mutex::new(false));
        let r = ran.clone();
        ctx.on_close(move || *r.lock().unwrap() = true);
        let errs = ctx.close().unwrap_err();
        assert!(*ran.lock().unwrap());
        assert_eq!(errs.0.len(), 1);
        assert_eq!(errs.0[0].what, "venue");
    }

    #[test]
    fn run_returns_close_errors_and_closes_even_when_the_body_panics() {
        let tmp = TempDir::new("ctx-run-err");
        let r = AppContext::run(manifest(json!({})), quiet(&tmp, &[]), |ctx| {
            ctx.on_close_fallible(|| Err::<(), _>("nope"));
            7
        });
        assert!(matches!(r, Err(ContextError::Close(ref e)) if e.0.len() == 1));

        let o = opts(&tmp, &[]);
        let roster_dir = tmp.path().join("roster");
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = AppContext::run(manifest(json!({})), o, |ctx| {
                assert!(roster_dir
                    .join(format!("com.slashbuilder.demo.calc@{}.json", ctx.instance))
                    .exists());
                panic!("boom");
            });
        }));
        assert!(result.is_err());
        let left = fs::read_dir(&roster_dir).map(|d| d.count()).unwrap_or(0);
        assert_eq!(left, 0, "the roster file was withdrawn while unwinding");
    }

    #[test]
    fn run_gives_back_the_body_value_when_all_is_well() {
        let tmp = TempDir::new("ctx-run-ok");
        let v = AppContext::run(manifest(json!({})), quiet(&tmp, &[]), |ctx| {
            ctx.manifest.id.clone()
        })
        .unwrap();
        assert_eq!(v, "com.slashbuilder.demo.calc");
    }

    // --- spec section 5, item 9: notes carry a severity

    #[test]
    fn notes_carry_a_severity() {
        let tmp = TempDir::new("ctx-notes");
        let ctx = open(&tmp, &[("CALC_MODE", "mock")], json!({}));
        assert_eq!(
            note_texts(&ctx),
            [(Severity::Info, "Venue: fake (mock mode)")]
        );
        assert_eq!(Severity::Warning.as_str(), "warning");
        assert_eq!(Severity::Error.as_str(), "error");
        assert_eq!(Severity::Info.as_str(), "info");
    }
}
