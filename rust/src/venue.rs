//! The one thing an app sees of Venue: a session that hides whether Venue is real, absent or faked.
//!
//! The trait is **blocking**: this crate has no async runtime, and background renewal is a scoped thread.
//! Spec section 3.
//!
//! This crate has no remote Venue session: the sessions here are [`LocalVenue`] (bookkeeping inside the process)
//! and [`FakeVenue`] (an in-memory node for tests). The Dart core has the session that talks to a real daemon.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde_json::{json, Map, Value};

/// What an app asks Venue for: a named piece of work needing a capability (a ContractClass).
#[derive(Debug, Clone, PartialEq)]
pub struct VenueNeed {
    pub name: String,
    pub contract_class: String,
    pub parameters: Map<String, Value>,
}

impl VenueNeed {
    pub fn new(name: &str, contract_class: &str) -> VenueNeed {
        VenueNeed {
            name: name.to_string(),
            contract_class: contract_class.to_string(),
            parameters: Map::new(),
        }
    }

    /// The Placement document the daemon takes (JSON is accepted as YAML).
    pub fn to_placement(&self, consumer: &str) -> Value {
        json!({
            "apiVersion": "node.slashbuilder.com/v1alpha1",
            "kind": "Placement",
            "metadata": {"name": self.name},
            "spec": {
                "principal": {"name": consumer},
                "claims": [{
                    "name": "g",
                    "contractClaimSpec": {
                        "requests": [{
                            "name": "r",
                            "exactly": {"contractClassName": self.contract_class},
                            "parameters": self.parameters,
                        }]
                    }
                }]
            }
        })
    }
}

/// Why Venue said no (spec section 5, item 6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalKind {
    /// HTTP 409: the plan found no room (or the name is already held). Worth retrying later.
    DoesNotFit,
    /// HTTP 403: the consumer may not do this, including hitting its live-hold limit. Venue gives no
    /// machine-readable reason (a finding for the Venue project), so this is **not retryable**.
    Forbidden,
}

impl RefusalKind {
    /// The spec's spelling (`doesNotFit`, `forbidden`).
    pub fn as_str(self) -> &'static str {
        match self {
            RefusalKind::DoesNotFit => "doesNotFit",
            RefusalKind::Forbidden => "forbidden",
        }
    }

    /// `DoesNotFit` may clear on its own; `Forbidden` will not.
    pub fn is_retryable(self) -> bool {
        self == RefusalKind::DoesNotFit
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VenueError {
    /// Venue answered and said no. `kind` tells the caller whether trying again can help.
    Refused { kind: RefusalKind, message: String },
    /// Venue could not be reached, or answered with anything that is not a refusal (401, 5xx, nonsense).
    Unavailable(String),
}

impl VenueError {
    pub fn refused(kind: RefusalKind, message: impl Into<String>) -> VenueError {
        VenueError::Refused {
            kind,
            message: message.into(),
        }
    }

    /// The refusal kind, or `None` for [`VenueError::Unavailable`].
    pub fn refusal_kind(&self) -> Option<RefusalKind> {
        match self {
            VenueError::Refused { kind, .. } => Some(*kind),
            VenueError::Unavailable(_) => None,
        }
    }
}

impl fmt::Display for VenueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VenueError::Refused { kind, message } => {
                write!(f, "Venue refused ({}): {message}", kind.as_str())
            }
            VenueError::Unavailable(r) => write!(f, "Venue unavailable: {r}"),
        }
    }
}

impl std::error::Error for VenueError {}

/// What went wrong with a hold after it was granted. Shared by every clone of the hold.
#[derive(Debug, Default)]
struct HoldRecord {
    state: Mutex<RecordState>,
}

#[derive(Debug, Default)]
struct RecordState {
    /// The first [`MAX_RECORDED_FAILURES`] renewal failures.
    failures: Vec<VenueError>,
    failure_count: usize,
    release_error: Option<VenueError>,
}

/// More failures than this are counted but not kept (a renewal runs every third of the lease).
const MAX_RECORDED_FAILURES: usize = 32;

/// A reservation. There is deliberately no `released` flag: [`VenueSession::release`] consumes the
/// hold, so releasing twice cannot be written.
///
/// Clones share one record of what went wrong afterwards (failed renewals, a failed release), so a
/// body that keeps a clone can read it after `with_hold` returns.
#[derive(Debug, Clone)]
pub struct VenueHold {
    pub name: String,
    /// `local`, `fake` or `venue`.
    pub kind: &'static str,
    pub expires_at: Option<DateTime<Utc>>,
    record: Arc<HoldRecord>,
}

impl PartialEq for VenueHold {
    fn eq(&self, other: &VenueHold) -> bool {
        self.name == other.name && self.kind == other.kind && self.expires_at == other.expires_at
    }
}

impl Eq for VenueHold {}

impl VenueHold {
    pub fn new(name: &str, kind: &'static str, expires_at: Option<DateTime<Utc>>) -> VenueHold {
        VenueHold {
            name: name.to_string(),
            kind,
            expires_at,
            record: Arc::new(HoldRecord::default()),
        }
    }

    /// True once any background renewal has failed. The Kit cannot tell a blip from a lapse, so
    /// the first failure counts; [`renewal_failures`](Self::renewal_failures) has the detail.
    pub fn lease_lost(&self) -> bool {
        locked(&self.record.state).failure_count > 0
    }

    /// How many renewals have failed so far.
    pub fn renewal_failure_count(&self) -> usize {
        locked(&self.record.state).failure_count
    }

    /// The renewal failures kept so far (the first 32), oldest first.
    pub fn renewal_failures(&self) -> Vec<VenueError> {
        locked(&self.record.state).failures.clone()
    }

    /// Why the release at the end of `with_hold` failed, if it did. A failed release never turns a
    /// successful body into an error; this is where it shows up.
    pub fn release_error(&self) -> Option<VenueError> {
        locked(&self.record.state).release_error.clone()
    }

    /// Records a failed renewal; returns true if it was the first.
    fn record_renewal_failure(&self, e: VenueError) -> bool {
        let mut st = locked(&self.record.state);
        st.failure_count += 1;
        if st.failures.len() < MAX_RECORDED_FAILURES {
            st.failures.push(e);
        }
        st.failure_count == 1
    }
}

pub trait VenueSession: Send + Sync {
    /// `local`, `fake` or `venue`.
    fn kind(&self) -> &'static str;
    fn is_connected(&self) -> bool {
        self.kind() == "venue"
    }
    /// One plain sentence, e.g. "Venue: local (Venue not configured)".
    fn description(&self) -> String;

    fn hold(&self, need: &VenueNeed, lease_seconds: u32) -> Result<VenueHold, VenueError>;
    fn start(&self, hold: &VenueHold) -> Result<(), VenueError>;
    fn renew(&self, hold: &VenueHold) -> Result<(), VenueError>;
    fn release(&self, hold: VenueHold) -> Result<(), VenueError>;
    fn nodes(&self) -> Result<Vec<Value>, VenueError>;
    /// This consumer's own live holds, sorted by name (to find orphans after a crash). Other
    /// consumers' holds are never listed.
    fn holds(&self) -> Result<Vec<VenueHold>, VenueError>;
    /// Called once by [`AppContext::close`](crate::AppContext::close), after everything else. The
    /// default does nothing.
    fn close(&self) -> Result<(), VenueError> {
        Ok(())
    }
}

/// Releases the hold when dropped, so a panic in the body still gives it back.
struct ReleaseOnDrop<'a> {
    session: &'a dyn VenueSession,
    hold: Option<VenueHold>,
}

impl ReleaseOnDrop<'_> {
    /// Releases once. A failure is also recorded on the hold's shared record.
    fn release_now(&mut self) -> Result<(), VenueError> {
        match self.hold.take() {
            Some(h) => {
                let record = h.clone();
                let r = self.session.release(h);
                if let Err(e) = &r {
                    locked(&record.record.state).release_error = Some(e.clone());
                }
                r
            }
            None => Ok(()),
        }
    }
}

impl Drop for ReleaseOnDrop<'_> {
    fn drop(&mut self) {
        // Only reached with a hold still in place on an early return or unwind; the failure is on the record.
        let _ = self.release_now();
    }
}

/// Options for `with_hold_opts` on a `dyn VenueSession`.
#[derive(Default)]
pub struct HoldOptions<'a> {
    /// Called once, on the first failed background renewal, from the renewal thread. A panic in it
    /// is caught and ignored. The failure is also on the hold either way.
    pub on_lease_lost: Option<&'a (dyn Fn(&VenueError) + Sync)>,
}

/// What `with_hold_opts` hands back: the body's value and the hold,
/// whose record says whether renewals or the release failed.
#[derive(Debug)]
pub struct HoldOutcome<T> {
    pub value: T,
    pub hold: VenueHold,
}

impl dyn VenueSession + '_ {
    /// Hold, start, renew in the background while `body` runs, then release, even if `body` panics.
    /// This is the loop every app that uses Venue would otherwise write.
    ///
    /// Renewal failures are recorded on the hold the body receives and a failed release never
    /// replaces the body's value; to see either after the call, use
    /// `with_hold_opts` (or keep a clone of the hold).
    pub fn with_hold<T>(
        &self,
        need: &VenueNeed,
        lease_seconds: u32,
        body: impl FnOnce(&VenueHold) -> T,
    ) -> Result<T, VenueError> {
        self.with_hold_opts(need, lease_seconds, &HoldOptions::default(), body)
            .map(|o| o.value)
    }

    /// `with_hold` with an `on_lease_lost` callback, returning the hold with the result.
    pub fn with_hold_opts<T>(
        &self,
        need: &VenueNeed,
        lease_seconds: u32,
        opts: &HoldOptions<'_>,
        body: impl FnOnce(&VenueHold) -> T,
    ) -> Result<HoldOutcome<T>, VenueError> {
        let hold = self.hold(need, lease_seconds)?;
        let mut guard = ReleaseOnDrop {
            session: self,
            hold: Some(hold.clone()),
        };
        // If start fails, the guard gives the hold back as this returns; the start error is the one reported.
        self.start(&hold)?;
        let every = Duration::from_secs(u64::from((lease_seconds / 3).clamp(1, 3600)));

        let value = thread::scope(|scope| {
            let (stop, stopped) = mpsc::channel::<()>();
            let (session, hold_ref) = (self, &hold);
            let renewer = scope.spawn(move || {
                // Ends when told to stop, or when `stop` is dropped.
                while let Err(RecvTimeoutError::Timeout) = stopped.recv_timeout(every) {
                    if let Err(e) = session.renew(hold_ref) {
                        // Never swallowed: kept on the hold, and the callback hears about the first.
                        if hold_ref.record_renewal_failure(e.clone()) {
                            if let Some(cb) = opts.on_lease_lost {
                                let _ =
                                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                        cb(&e)
                                    }));
                            }
                        }
                    }
                }
            });
            // If `body` panics, `stop` drops, the renewer exits, and the scope can join it.
            let value = body(&hold);
            let _ = stop.send(());
            let _ = renewer.join();
            value
        });
        // A failing release is on the hold's record; it must not replace a good result.
        let _ = guard.release_now();
        Ok(HoldOutcome { value, hold })
    }
}

/// No Venue: the work still runs and the session says so. Holds are in-process only, so two apps
/// can both "hold" the same thing.
pub struct LocalVenue {
    why: String,
    held: Mutex<BTreeMap<String, Option<DateTime<Utc>>>>,
}

impl LocalVenue {
    pub fn new(why: &str) -> LocalVenue {
        LocalVenue {
            why: why.to_string(),
            held: Mutex::new(BTreeMap::new()),
        }
    }
}

fn locked<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // A poisoned lock only means another thread panicked; the data is a plain set/log, still usable.
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn expiry(lease_seconds: u32) -> Option<DateTime<Utc>> {
    Some(Utc::now() + chrono::Duration::seconds(i64::from(lease_seconds)))
}

impl VenueSession for LocalVenue {
    fn kind(&self) -> &'static str {
        "local"
    }
    fn description(&self) -> String {
        format!("Venue: local ({})", self.why)
    }
    fn hold(&self, need: &VenueNeed, lease_seconds: u32) -> Result<VenueHold, VenueError> {
        let mut held = locked(&self.held);
        if held.contains_key(&need.name) {
            return Err(VenueError::refused(
                RefusalKind::DoesNotFit,
                format!("{} is already held in this process", need.name),
            ));
        }
        let expires_at = expiry(lease_seconds);
        held.insert(need.name.clone(), expires_at);
        Ok(VenueHold::new(&need.name, "local", expires_at))
    }
    fn start(&self, _hold: &VenueHold) -> Result<(), VenueError> {
        Ok(())
    }
    fn renew(&self, _hold: &VenueHold) -> Result<(), VenueError> {
        Ok(())
    }
    fn release(&self, hold: VenueHold) -> Result<(), VenueError> {
        locked(&self.held).remove(&hold.name);
        Ok(())
    }
    fn nodes(&self) -> Result<Vec<Value>, VenueError> {
        Ok(Vec::new())
    }
    fn holds(&self) -> Result<Vec<VenueHold>, VenueError> {
        Ok(locked(&self.held)
            .iter()
            .map(|(name, exp)| VenueHold::new(name, "local", *exp))
            .collect())
    }
}

/// An in-memory Venue for mock mode and tests: one fake node with a fixed capacity, and a log of calls.
pub struct FakeVenue {
    capacity: usize,
    log: Mutex<Vec<String>>,
    held: Mutex<BTreeMap<String, Option<DateTime<Utc>>>>,
    renew_failure: Mutex<Option<VenueError>>,
    release_failure: Mutex<Option<VenueError>>,
}

impl FakeVenue {
    pub fn new(capacity: usize) -> FakeVenue {
        FakeVenue {
            capacity,
            log: Mutex::new(Vec::new()),
            held: Mutex::new(BTreeMap::new()),
            renew_failure: Mutex::new(None),
            release_failure: Mutex::new(None),
        }
    }

    /// Every call made so far, as `"hold NAME"`, `"start NAME"`, `"renew NAME"`, `"release NAME"`,
    /// and `"close"`.
    pub fn log(&self) -> Vec<String> {
        locked(&self.log).clone()
    }

    /// Makes every later `renew` fail with `e` (`None` makes them succeed again). For testing how an app
    /// reacts to a lost lease.
    pub fn fail_renewals_with(&self, e: Option<VenueError>) {
        *locked(&self.renew_failure) = e;
    }

    /// Makes every later `release` fail with `e` (the hold stays held); `None` restores success.
    pub fn fail_releases_with(&self, e: Option<VenueError>) {
        *locked(&self.release_failure) = e;
    }

    fn note(&self, verb: &str, name: &str) {
        locked(&self.log).push(format!("{verb} {name}"));
    }
}

impl VenueSession for FakeVenue {
    fn kind(&self) -> &'static str {
        "fake"
    }
    fn description(&self) -> String {
        "Venue: fake (mock mode)".to_string()
    }
    fn hold(&self, need: &VenueNeed, lease_seconds: u32) -> Result<VenueHold, VenueError> {
        self.note("hold", &need.name);
        let mut held = locked(&self.held);
        if held.len() >= self.capacity {
            return Err(VenueError::refused(
                RefusalKind::DoesNotFit,
                "the fake node is full",
            ));
        }
        let expires_at = expiry(lease_seconds);
        held.insert(need.name.clone(), expires_at);
        Ok(VenueHold::new(&need.name, "fake", expires_at))
    }
    fn start(&self, hold: &VenueHold) -> Result<(), VenueError> {
        self.note("start", &hold.name);
        Ok(())
    }
    fn renew(&self, hold: &VenueHold) -> Result<(), VenueError> {
        self.note("renew", &hold.name);
        match locked(&self.renew_failure).clone() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
    fn release(&self, hold: VenueHold) -> Result<(), VenueError> {
        self.note("release", &hold.name);
        if let Some(e) = locked(&self.release_failure).clone() {
            return Err(e);
        }
        locked(&self.held).remove(&hold.name);
        Ok(())
    }
    fn nodes(&self) -> Result<Vec<Value>, VenueError> {
        Ok(vec![json!({"name": "fake-node", "ready": true})])
    }
    fn holds(&self) -> Result<Vec<VenueHold>, VenueError> {
        Ok(locked(&self.held)
            .iter()
            .map(|(name, exp)| VenueHold::new(name, "fake", *exp))
            .collect())
    }
    fn close(&self) -> Result<(), VenueError> {
        locked(&self.log).push("close".to_string());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn need(name: &str) -> VenueNeed {
        VenueNeed::new(name, "container.run.v1")
    }

    fn lost() -> VenueError {
        VenueError::Unavailable("the line is down".into())
    }

    #[test]
    fn with_hold_orders_calls_and_returns_the_body_value() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        let v = s.with_hold(&need("a"), 300, |h| h.name.clone()).unwrap();
        assert_eq!(v, "a");
        assert_eq!(fake.log(), ["hold a", "start a", "release a"]);
    }

    #[test]
    fn with_hold_releases_when_the_body_returns_an_error() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        let r: Result<Result<(), &str>, VenueError> =
            s.with_hold(&need("a"), 300, |_| Err("body failed"));
        assert_eq!(r.unwrap(), Err("body failed"));
        assert_eq!(fake.log().last().map(String::as_str), Some("release a"));
    }

    #[test]
    fn with_hold_releases_when_the_body_panics() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = s.with_hold(&need("a"), 300, |_| panic!("boom"));
        }));
        assert!(r.is_err());
        assert_eq!(fake.log().last().map(String::as_str), Some("release a"));
        // and the capacity is free again
        assert!(s.hold(&need("b"), 300).is_ok());
    }

    #[test]
    fn a_refused_hold_never_runs_the_body_or_releases() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        let _held = s.hold(&need("a"), 300).unwrap();
        let mut ran = false;
        let r = s.with_hold(&need("b"), 300, |_| ran = true);
        assert_eq!(r.unwrap_err().refusal_kind(), Some(RefusalKind::DoesNotFit));
        assert!(!ran);
        assert_eq!(fake.log(), ["hold a", "hold b"]);
    }

    #[test]
    fn renews_in_the_background_while_the_body_runs() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        // lease 3 s means a renewal every second
        s.with_hold(&need("a"), 3, |_| {
            thread::sleep(Duration::from_millis(2500));
        })
        .unwrap();
        let renews = fake.log().iter().filter(|l| l.starts_with("renew")).count();
        assert!(renews >= 2, "expected renewals, log: {:?}", fake.log());
        assert_eq!(fake.log().last().map(String::as_str), Some("release a"));
    }

    // --- spec section 5, item 7: renewal failures are not swallowed

    #[test]
    fn a_failed_renewal_is_recorded_on_the_hold_and_fires_on_lease_lost_once() {
        let fake = FakeVenue::new(1);
        fake.fail_renewals_with(Some(lost()));
        let s: &dyn VenueSession = &fake;
        let calls = AtomicUsize::new(0);
        let heard = Mutex::new(Vec::new());
        let cb = |e: &VenueError| {
            calls.fetch_add(1, Ordering::SeqCst);
            heard.lock().unwrap().push(e.to_string());
        };
        let opts = HoldOptions {
            on_lease_lost: Some(&cb),
        };
        // lease 3 s: a renewal every second, so 2.5 s sees two failures
        let out = s
            .with_hold_opts(&need("a"), 3, &opts, |h| {
                thread::sleep(Duration::from_millis(2500));
                assert!(h.lease_lost(), "the body can see it while it runs");
                "body result"
            })
            .unwrap();
        assert_eq!(out.value, "body result");
        assert!(out.hold.lease_lost());
        assert!(out.hold.renewal_failure_count() >= 2);
        assert_eq!(out.hold.renewal_failures()[0], lost());
        // Fired exactly once, with the first failure, though more failures were recorded.
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(heard.lock().unwrap().len(), 1);
        assert!(heard.lock().unwrap()[0].contains("the line is down"));
        // Release still happened.
        assert_eq!(fake.log().last().map(String::as_str), Some("release a"));
        assert_eq!(out.hold.release_error(), None);
    }

    #[test]
    fn renewal_failures_are_recorded_without_a_callback_too() {
        let fake = FakeVenue::new(1);
        fake.fail_renewals_with(Some(lost()));
        let s: &dyn VenueSession = &fake;
        // plain with_hold: the body keeps a clone to read it afterwards
        let kept = s
            .with_hold(&need("a"), 3, |h| {
                thread::sleep(Duration::from_millis(1500));
                h.clone()
            })
            .unwrap();
        assert!(kept.lease_lost());
        assert!(kept.renewal_failure_count() >= 1);
    }

    #[test]
    fn a_healthy_hold_has_nothing_recorded_and_the_callback_never_fires() {
        let fake = FakeVenue::new(1);
        let s: &dyn VenueSession = &fake;
        let calls = AtomicUsize::new(0);
        let cb = |_: &VenueError| {
            calls.fetch_add(1, Ordering::SeqCst);
        };
        let out = s
            .with_hold_opts(
                &need("a"),
                3,
                &HoldOptions {
                    on_lease_lost: Some(&cb),
                },
                |_| thread::sleep(Duration::from_millis(1500)),
            )
            .unwrap();
        assert!(!out.hold.lease_lost());
        assert_eq!(out.hold.renewal_failure_count(), 0);
        assert!(out.hold.renewal_failures().is_empty());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_renewal_that_recovers_is_still_on_the_record() {
        let fake = FakeVenue::new(1);
        fake.fail_renewals_with(Some(lost()));
        let s: &dyn VenueSession = &fake;
        let out = s
            .with_hold_opts(&need("a"), 3, &HoldOptions::default(), |_| {
                thread::sleep(Duration::from_millis(1500));
                fake.fail_renewals_with(None);
                thread::sleep(Duration::from_millis(1500));
            })
            .unwrap();
        assert!(
            out.hold.renewal_failure_count() >= 1,
            "the blip is not erased"
        );
    }

    #[test]
    fn a_panicking_lease_lost_callback_does_not_stop_the_body_or_the_release() {
        let fake = FakeVenue::new(1);
        fake.fail_renewals_with(Some(lost()));
        let s: &dyn VenueSession = &fake;
        let cb = |_: &VenueError| panic!("callback blew up");
        let out = s
            .with_hold_opts(
                &need("a"),
                3,
                &HoldOptions {
                    on_lease_lost: Some(&cb),
                },
                |_| {
                    thread::sleep(Duration::from_millis(1500));
                    5
                },
            )
            .unwrap();
        assert_eq!(out.value, 5);
        assert_eq!(fake.log().last().map(String::as_str), Some("release a"));
    }

    // --- spec section 5, item 7: a failing release never replaces a good result

    #[test]
    fn a_failing_release_is_recorded_and_does_not_replace_the_body_result() {
        // Capacity 2: the failed release leaves "a" held, and the second call below needs room.
        let fake = FakeVenue::new(2);
        fake.fail_releases_with(Some(VenueError::Unavailable("release: HTTP 500".into())));
        let s: &dyn VenueSession = &fake;
        let out = s
            .with_hold_opts(&need("a"), 300, &HoldOptions::default(), |_| 42)
            .unwrap();
        assert_eq!(out.value, 42);
        assert_eq!(
            out.hold.release_error(),
            Some(VenueError::Unavailable("release: HTTP 500".into()))
        );
        assert!(!out.hold.lease_lost());
        // plain with_hold also returns the body value, not the release error
        assert_eq!(s.with_hold(&need("b"), 300, |_| "ok").unwrap(), "ok");
    }

    #[test]
    fn a_failing_release_does_not_replace_a_body_error_value_either() {
        let fake = FakeVenue::new(1);
        fake.fail_releases_with(Some(lost()));
        let s: &dyn VenueSession = &fake;
        let r: Result<Result<(), &str>, VenueError> =
            s.with_hold(&need("a"), 300, |_| Err("job failed"));
        assert_eq!(r.unwrap(), Err("job failed"));
    }

    #[test]
    fn a_failing_start_gives_the_hold_back_and_reports_the_start_error() {
        struct StartFails(FakeVenue);
        impl VenueSession for StartFails {
            fn kind(&self) -> &'static str {
                "fake"
            }
            fn description(&self) -> String {
                String::new()
            }
            fn hold(&self, n: &VenueNeed, l: u32) -> Result<VenueHold, VenueError> {
                self.0.hold(n, l)
            }
            fn start(&self, _: &VenueHold) -> Result<(), VenueError> {
                Err(VenueError::refused(
                    RefusalKind::Forbidden,
                    "no start for you",
                ))
            }
            fn renew(&self, h: &VenueHold) -> Result<(), VenueError> {
                self.0.renew(h)
            }
            fn release(&self, h: VenueHold) -> Result<(), VenueError> {
                self.0.release(h)
            }
            fn nodes(&self) -> Result<Vec<Value>, VenueError> {
                self.0.nodes()
            }
            fn holds(&self) -> Result<Vec<VenueHold>, VenueError> {
                self.0.holds()
            }
        }
        let inner = StartFails(FakeVenue::new(1));
        let s: &dyn VenueSession = &inner;
        let mut ran = false;
        let e = s.with_hold(&need("a"), 300, |_| ran = true).unwrap_err();
        assert_eq!(e.refusal_kind(), Some(RefusalKind::Forbidden));
        assert!(!ran);
        assert_eq!(inner.0.log(), ["hold a", "release a"]);
    }

    // --- spec section 5, item 6: typed answers

    #[test]
    fn refusal_kinds_have_the_spec_names_and_only_does_not_fit_is_retryable() {
        assert_eq!(RefusalKind::DoesNotFit.as_str(), "doesNotFit");
        assert_eq!(RefusalKind::Forbidden.as_str(), "forbidden");
        assert!(RefusalKind::DoesNotFit.is_retryable());
        assert!(!RefusalKind::Forbidden.is_retryable());
        assert_eq!(lost().refusal_kind(), None);
        let e = VenueError::refused(RefusalKind::Forbidden, "limit");
        assert_eq!(e.to_string(), "Venue refused (forbidden): limit");
    }

    // --- spec section 5, item 7: holds()

    #[test]
    fn fake_and_local_list_their_own_live_holds_sorted() {
        let fake = FakeVenue::new(3);
        let s: &dyn VenueSession = &fake;
        assert!(s.holds().unwrap().is_empty());
        let _c = s.hold(&need("c"), 60).unwrap();
        let b = s.hold(&need("b"), 60).unwrap();
        let _a = s.hold(&need("a"), 60).unwrap();
        let names = |s: &dyn VenueSession| -> Vec<String> {
            s.holds().unwrap().into_iter().map(|h| h.name).collect()
        };
        assert_eq!(names(s), ["a", "b", "c"]);
        assert!(s
            .holds()
            .unwrap()
            .iter()
            .all(|h| h.expires_at.is_some() && h.kind == "fake"));
        s.release(b).unwrap();
        assert_eq!(names(s), ["a", "c"]);

        let local = LocalVenue::new("t");
        let l: &dyn VenueSession = &local;
        let _x = l.hold(&need("x"), 60).unwrap();
        assert_eq!(names(l), ["x"]);
    }

    #[test]
    fn local_venue_refuses_a_second_hold_of_the_same_name_in_one_process() {
        let local = LocalVenue::new("test");
        let s: &dyn VenueSession = &local;
        let h = s.hold(&need("a"), 300).unwrap();
        assert_eq!(
            s.hold(&need("a"), 300).unwrap_err().refusal_kind(),
            Some(RefusalKind::DoesNotFit)
        );
        s.release(h).unwrap();
        assert!(s.hold(&need("a"), 300).is_ok());
        assert_eq!(s.description(), "Venue: local (test)");
    }

    #[test]
    fn placement_names_the_consumer_class_and_hold() {
        let p = need("job1").to_placement("calc");
        assert_eq!(p["metadata"]["name"], "job1");
        assert_eq!(p["spec"]["principal"]["name"], "calc");
        assert_eq!(
            p["spec"]["claims"][0]["contractClaimSpec"]["requests"][0]["exactly"]
                ["contractClassName"],
            "container.run.v1"
        );
    }
}
