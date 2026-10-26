//! Who is running, by presence file: `<roster>/<ID>@<INSTANCE>.json`, rewritten (write then rename)
//! every heartbeat. An entry is stale when its heartbeat is more than 15 seconds old.
//!
//! Spec section 5, item 5: every opened context draws its own random 8-hex-digit instance id, so two
//! copies of one app have two files and neither erases the other. App ids contain dots, never `@`, so
//! the instance is whatever follows the **last** `@` in the file name.

use std::collections::hash_map::RandomState;
use std::fs::{self, File};
use std::hash::{BuildHasher, Hasher};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};

pub const STALE_AFTER: Duration = Duration::from_secs(15);
pub const HEARTBEAT: Duration = Duration::from_secs(5);

/// A fresh instance id: 8 lowercase hex digits. Not cryptographic: it only has to make two copies of
/// one app on one machine unlikely to collide. It mixes the per-process random keys of the std hasher
/// with the clock and the process id, so no `rand` dependency is needed.
pub fn new_instance_id() -> String {
    let mut h = RandomState::new().build_hasher();
    h.write_u32(std::process::id());
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    h.write_u128(nanos);
    // The low 32 bits of the 64-bit hash.
    format!("{:08x}", h.finish() & 0xffff_ffff)
}

/// `^[0-9a-f]{8}$`
pub(crate) fn is_instance_id(s: &str) -> bool {
    s.len() == 8
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Splits `<ID>@<INSTANCE>.json` into `(ID, INSTANCE)`. The id contains dots, so only a final
/// `.json` is removed and the split is at the last `@`. A name that is not of that form (an older
/// `<ID>.json`, a bad instance) gives the whole stem as the id and no instance.
pub fn parse_file_name(name: &str) -> (&str, Option<&str>) {
    let stem = name.strip_suffix(".json").unwrap_or(name);
    match stem.rsplit_once('@') {
        Some((id, instance)) if !id.is_empty() && is_instance_id(instance) => (id, Some(instance)),
        _ => (stem, None),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RosterEntry {
    pub id: String,
    /// The 8-hex-digit instance id of the context that wrote this entry. `None` only for a
    /// presence file written before instance ids existed (an earlier version's `<ID>.json`), which is still
    /// read, so an older copy of an app that is running shows as live.
    pub instance: Option<String>,
    pub name: String,
    pub version: String,
    pub pid: u32,
    pub started_at: DateTime<Utc>,
    pub heartbeat_at: DateTime<Utc>,
}

fn iso(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Micros, true)
}

impl RosterEntry {
    /// Stale when the heartbeat is strictly older than `after`.
    pub fn is_stale(&self, now: DateTime<Utc>, after: Duration) -> bool {
        match chrono::Duration::from_std(after) {
            Ok(d) => now - self.heartbeat_at > d,
            Err(_) => false,
        }
    }

    /// `<ID>@<INSTANCE>.json` (`<ID>.json` for an entry with no instance).
    pub fn file_name(&self) -> String {
        match &self.instance {
            Some(i) => format!("{}@{i}.json", self.id),
            None => format!("{}.json", self.id),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "pid": self.pid,
            "startedAt": iso(self.started_at),
            "heartbeatAt": iso(self.heartbeat_at),
        });
        if let (Some(i), Some(obj)) = (&self.instance, v.as_object_mut()) {
            obj.insert("instance".to_string(), json!(i));
        }
        v
    }

    /// `None` for anything that is not a complete, well-typed presence document. A missing
    /// `instance` is allowed (an older file); one that is present but not a string is not.
    pub fn from_json(v: &Value) -> Option<RosterEntry> {
        let time = |key: &str| -> Option<DateTime<Utc>> {
            DateTime::parse_from_rfc3339(v.get(key)?.as_str()?)
                .ok()
                .map(|t| t.with_timezone(&Utc))
        };
        Some(RosterEntry {
            id: v.get("id")?.as_str()?.to_string(),
            instance: match v.get("instance") {
                None => None,
                Some(i) => Some(i.as_str()?.to_string()),
            },
            name: v.get("name")?.as_str()?.to_string(),
            version: v.get("version")?.as_str()?.to_string(),
            pid: u32::try_from(v.get("pid")?.as_u64()?).ok()?,
            started_at: time("startedAt")?,
            heartbeat_at: time("heartbeatAt")?,
        })
    }
}

/// What [`Roster::scan`] says about one file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryStatus {
    /// Readable, heartbeat within the stale limit.
    Live,
    /// Readable, heartbeat older than the limit: the app crashed or was killed.
    Stale,
    /// A `*.json` file that is not a complete presence document.
    Unreadable,
}

impl EntryStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            EntryStatus::Live => "live",
            EntryStatus::Stale => "stale",
            EntryStatus::Unreadable => "unreadable",
        }
    }
}

/// One `*.json` file in the roster directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanEntry {
    pub file: PathBuf,
    pub status: EntryStatus,
    /// The parsed document; `None` exactly when `status` is `Unreadable`.
    pub entry: Option<RosterEntry>,
    /// The app id: from the document when readable, otherwise from the file name, so a viewer can
    /// still say whose unreadable file it is.
    pub id: String,
    /// The instance: from the document when readable, otherwise from the file name. `None` when
    /// there is none (an older `<ID>.json`, or a name that is not `<ID>@<8 hex>.json`).
    pub instance: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Roster {
    dir: PathBuf,
}

/// Writes `entry` to `<dir>/<ID>@<INSTANCE>.json` via a temp file in the same directory, then a rename.
fn write_entry(dir: &Path, entry: &RosterEntry) -> io::Result<()> {
    let target = dir.join(entry.file_name());
    // The temp name ends in ".tmp", so a scan for "*.json" never sees a half-written file.
    let tmp = dir.join(format!("{}.tmp", entry.file_name()));
    let text = serde_json::to_string(&entry.to_json()).map_err(io::Error::from)?;
    {
        let mut f = File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
    }
    fs::rename(&tmp, &target)
}

impl Roster {
    pub fn new(dir: impl Into<PathBuf>) -> Roster {
        Roster { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Writes the presence file now and keeps its heartbeat going on a background thread until the
    /// returned [`Announcement`] is withdrawn or dropped. `instance` is the context's instance id
    /// (see [`new_instance_id`]); anything but 8 lowercase hex digits is `InvalidInput`.
    pub fn announce(
        &self,
        id: &str,
        instance: &str,
        name: &str,
        version: &str,
        every: Duration,
    ) -> io::Result<Announcement> {
        if !is_instance_id(instance) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("instance id must be 8 lowercase hex digits, got {instance:?}"),
            ));
        }
        fs::create_dir_all(&self.dir)?;
        let started_at = Utc::now();
        let mut entry = RosterEntry {
            id: id.to_string(),
            instance: Some(instance.to_string()),
            name: name.to_string(),
            version: version.to_string(),
            pid: std::process::id(),
            started_at,
            heartbeat_at: started_at,
        };
        write_entry(&self.dir, &entry)?;
        let file = self.dir.join(entry.file_name());

        let (stop, stopped) = mpsc::channel::<()>();
        let dir = self.dir.clone();
        let handle = thread::spawn(move || {
            // Ends when told to stop, or when the Announcement is dropped.
            while let Err(RecvTimeoutError::Timeout) = stopped.recv_timeout(every) {
                entry.heartbeat_at = Utc::now();
                // A failed beat is retried on the next tick; the entry just ages toward stale.
                let _ = write_entry(&dir, &entry);
            }
        });
        Ok(Announcement {
            file,
            instance: instance.to_string(),
            stop: Some(stop),
            handle: Some(handle),
        })
    }

    /// Every `*.json` file in the directory with its status, sorted by app id then instance. Nothing is deleted.
    /// A directory that does not exist is an empty roster.
    pub fn scan(&self, now: DateTime<Utc>, stale_after: Duration) -> Vec<ScanEntry> {
        let Ok(read) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut out: Vec<ScanEntry> = read
            .filter_map(Result::ok)
            .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .map(|file| {
                let name = file
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or_default();
                let (name_id, name_instance) = parse_file_name(name);
                let (name_id, name_instance) =
                    (name_id.to_string(), name_instance.map(str::to_string));
                let entry = fs::read(&file)
                    .ok()
                    .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                    .and_then(|v| RosterEntry::from_json(&v));
                let status = match &entry {
                    None => EntryStatus::Unreadable,
                    Some(e) if e.is_stale(now, stale_after) => EntryStatus::Stale,
                    Some(_) => EntryStatus::Live,
                };
                let (id, instance) = match &entry {
                    Some(e) => (e.id.clone(), e.instance.clone()),
                    None => (name_id, name_instance),
                };
                ScanEntry {
                    file,
                    status,
                    entry,
                    id,
                    instance,
                }
            })
            .collect();
        out.sort_by(|a, b| (&a.id, &a.instance).cmp(&(&b.id, &b.instance)));
        out
    }

    /// Every announced entry that is live, sorted by id then instance. Stale and unreadable files are
    /// hidden (not deleted); [`scan`](Self::scan) shows them.
    pub fn running(&self, now: DateTime<Utc>, stale_after: Duration) -> Vec<RosterEntry> {
        let mut out: Vec<RosterEntry> = self
            .scan(now, stale_after)
            .into_iter()
            .filter(|s| s.status == EntryStatus::Live)
            .filter_map(|s| s.entry)
            .collect();
        out.sort_by(|a, b| (&a.id, &a.instance).cmp(&(&b.id, &b.instance)));
        out
    }
}

/// A live presence file. Withdrawing (or dropping) stops the heartbeat and deletes **this**
/// context's file and no other.
#[derive(Debug)]
pub struct Announcement {
    file: PathBuf,
    instance: String,
    stop: Option<Sender<()>>,
    handle: Option<JoinHandle<()>>,
}

impl Announcement {
    pub fn instance(&self) -> &str {
        &self.instance
    }

    /// The presence file this announcement owns.
    pub fn file(&self) -> &Path {
        &self.file
    }

    /// Stops the heartbeat and removes the file. A file that is already gone is not an error.
    pub fn withdraw(mut self) -> io::Result<()> {
        self.shutdown()
    }

    fn shutdown(&mut self) -> io::Result<()> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        // Join first, so the heartbeat thread cannot rewrite the file after it is deleted.
        if let Some(h) = self.handle.take() {
            let _ = h.join();
            return match fs::remove_file(&self.file) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        Ok(())
    }
}

impl Drop for Announcement {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    const ID: &str = "com.slashbuilder.demo.calc";
    const A: &str = "0a1b2c3d";
    const B: &str = "ffeeddcc";

    fn roster(dir: &TempDir) -> Roster {
        Roster::new(dir.path().join("roster"))
    }

    fn announce(r: &Roster, instance: &str, every: Duration) -> Announcement {
        r.announce(ID, instance, "Calc", "0.1.0", every).unwrap()
    }

    fn entry(heartbeat_at: DateTime<Utc>) -> RosterEntry {
        RosterEntry {
            id: ID.into(),
            instance: Some(A.into()),
            name: "n".into(),
            version: "1.0.0".into(),
            pid: 1,
            started_at: heartbeat_at,
            heartbeat_at,
        }
    }

    #[test]
    fn announce_lists_and_withdraw_removes() {
        let dir = TempDir::new("roster-basic");
        let r = roster(&dir);
        let a = announce(&r, A, HEARTBEAT);
        let seen = r.running(Utc::now(), STALE_AFTER);
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].id, ID);
        assert_eq!(seen[0].instance.as_deref(), Some(A));
        assert_eq!(seen[0].pid, std::process::id());
        assert!(r.dir().join(format!("{ID}@{A}.json")).exists());
        a.withdraw().unwrap();
        assert!(r.running(Utc::now(), STALE_AFTER).is_empty());
        assert!(!r.dir().join(format!("{ID}@{A}.json")).exists());
    }

    #[test]
    fn the_file_carries_the_instance_field() {
        let dir = TempDir::new("roster-field");
        let r = roster(&dir);
        let a = announce(&r, A, HEARTBEAT);
        let text = fs::read_to_string(a.file()).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["instance"], A);
        assert_eq!(v["id"], ID);
        assert_eq!(a.instance(), A);
    }

    #[test]
    fn two_copies_of_one_app_do_not_erase_each_other() {
        let dir = TempDir::new("roster-two");
        let r = roster(&dir);
        let a = announce(&r, A, HEARTBEAT);
        let b = announce(&r, B, HEARTBEAT);
        let seen: Vec<Option<String>> = r
            .running(Utc::now(), STALE_AFTER)
            .into_iter()
            .map(|e| e.instance)
            .collect();
        assert_eq!(seen, [Some(A.to_string()), Some(B.to_string())]);
        // The first copy exits: the survivor's presence is still there, at once.
        a.withdraw().unwrap();
        let seen = r.running(Utc::now(), STALE_AFTER);
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].instance.as_deref(), Some(B));
        b.withdraw().unwrap();
        assert!(r.running(Utc::now(), STALE_AFTER).is_empty());
    }

    #[test]
    fn dropping_an_announcement_withdraws_only_its_own_file() {
        let dir = TempDir::new("roster-drop");
        let r = roster(&dir);
        let keep = announce(&r, B, HEARTBEAT);
        drop(announce(&r, A, HEARTBEAT));
        let seen = r.running(Utc::now(), STALE_AFTER);
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].instance.as_deref(), Some(B));
        keep.withdraw().unwrap();
    }

    #[test]
    fn heartbeat_advances_and_stale_entries_are_hidden_but_scan_shows_them() {
        let dir = TempDir::new("roster-beat");
        let r = roster(&dir);
        let a = announce(&r, A, Duration::from_millis(20));
        let first = r.running(Utc::now(), STALE_AFTER)[0].heartbeat_at;
        // Wait for a beat, not for a fixed time: a loaded machine can starve the beat thread for longer than any fixed sleep.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut later = first;
        while later <= first && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
            later = r.running(Utc::now(), STALE_AFTER)[0].heartbeat_at;
        }
        assert!(later > first, "heartbeat should have advanced");
        // A minute later with no beats, the entry is stale: hidden from running(), shown by scan().
        let future = Utc::now() + chrono::Duration::minutes(1);
        assert!(r.running(future, STALE_AFTER).is_empty());
        let scanned = r.scan(future, STALE_AFTER);
        assert_eq!(scanned.len(), 1);
        assert_eq!(scanned[0].status, EntryStatus::Stale);
        assert!(scanned[0].entry.is_some());
        assert!(a.file().exists());
        a.withdraw().unwrap();
    }

    #[test]
    fn stale_boundary_is_strictly_greater_than_fifteen_seconds() {
        let now = Utc::now();
        let mut e = entry(now - chrono::Duration::seconds(15));
        assert!(!e.is_stale(now, STALE_AFTER));
        e.heartbeat_at = now - chrono::Duration::milliseconds(15_001);
        assert!(e.is_stale(now, STALE_AFTER));
    }

    #[test]
    fn scan_reports_live_stale_and_unreadable_and_running_hides_the_last_two() {
        let dir = TempDir::new("roster-scan");
        let r = roster(&dir);
        fs::create_dir_all(r.dir()).unwrap();
        // unreadable: not JSON, incomplete, non-UTF-8, and an instance that is not a string.
        fs::write(r.dir().join("junk.json"), "{not json").unwrap();
        fs::write(r.dir().join(format!("x.y@{A}.json")), r#"{"id":"x.y"}"#).unwrap();
        fs::write(r.dir().join("bytes.json"), [0xff, 0xfe, 0x00]).unwrap();
        let mut odd = entry(Utc::now()).to_json();
        odd["instance"] = serde_json::json!(7);
        fs::write(r.dir().join(format!("odd@{A}.json")), odd.to_string()).unwrap();
        // a file from an earlier version (no instance field) is a complete document, so it is read, and live
        let mut old = entry(Utc::now());
        old.instance = None;
        fs::write(r.dir().join(old.file_name()), old.to_json().to_string()).unwrap();
        // not entries at all
        fs::write(r.dir().join("note.txt"), "hi").unwrap();
        fs::create_dir_all(r.dir().join("dir.json")).unwrap();
        // stale, written by hand
        let mut stale = entry(Utc::now() - chrono::Duration::minutes(5));
        stale.instance = Some(B.into());
        fs::write(r.dir().join(stale.file_name()), stale.to_json().to_string()).unwrap();
        let live = announce(&r, A, HEARTBEAT);

        let find = |scan: &[ScanEntry], name: &str| -> ScanEntry {
            scan.iter()
                .find(|s| s.file.file_name().is_some_and(|n| n == name))
                .unwrap_or_else(|| panic!("no {name} in {scan:?}"))
                .clone()
        };
        let scan = r.scan(Utc::now(), STALE_AFTER);
        assert_eq!(scan.len(), 7, "{scan:?}");
        assert_eq!(
            find(&scan, &format!("{ID}@{A}.json")).status,
            EntryStatus::Live
        );
        assert_eq!(
            find(&scan, &format!("{ID}@{B}.json")).status,
            EntryStatus::Stale
        );
        let legacy = find(&scan, &format!("{ID}.json"));
        assert_eq!(legacy.status, EntryStatus::Live);
        assert_eq!((legacy.id.as_str(), legacy.instance.clone()), (ID, None));
        for name in [
            "junk.json".to_string(),
            format!("x.y@{A}.json"),
            "bytes.json".to_string(),
            format!("odd@{A}.json"),
        ] {
            let s = find(&scan, &name);
            assert_eq!(s.status, EntryStatus::Unreadable, "{name}");
            assert!(s.entry.is_none());
        }
        // An unreadable file still says whose it is, when the name says so.
        let named = find(&scan, &format!("x.y@{A}.json"));
        assert_eq!(
            (named.id.as_str(), named.instance.as_deref()),
            ("x.y", Some(A))
        );
        let junk = find(&scan, "junk.json");
        assert_eq!((junk.id.as_str(), junk.instance.clone()), ("junk", None));

        let running = r.running(Utc::now(), STALE_AFTER);
        let who: Vec<Option<&str>> = running.iter().map(|e| e.instance.as_deref()).collect();
        assert_eq!(who, [None, Some(A)]);
        // Skipped, not deleted.
        assert!(r.dir().join("junk.json").exists());
        live.withdraw().unwrap();
    }

    #[test]
    fn scan_sorts_by_app_id_then_instance_not_by_file_name() {
        let dir = TempDir::new("roster-sort");
        let r = roster(&dir);
        // As file names "a.b.c@..." sorts before "a.b@..." ('.' < '@'), but by app id "a.b" comes first.
        let mut keep = Vec::new();
        for (id, inst) in [("a.b.c", A), ("a.b", B), ("a.b", A)] {
            keep.push(r.announce(id, inst, "n", "1.0.0", HEARTBEAT).unwrap());
        }
        let order: Vec<(String, Option<String>)> = r
            .scan(Utc::now(), STALE_AFTER)
            .into_iter()
            .map(|s| (s.id, s.instance))
            .collect();
        assert_eq!(
            order,
            [
                ("a.b".to_string(), Some(A.to_string())),
                ("a.b".to_string(), Some(B.to_string())),
                ("a.b.c".to_string(), Some(A.to_string())),
            ]
        );
    }

    #[test]
    fn scan_of_a_missing_directory_is_empty() {
        let dir = TempDir::new("roster-none");
        assert!(roster(&dir).scan(Utc::now(), STALE_AFTER).is_empty());
    }

    #[test]
    fn file_names_split_at_the_last_at_sign_and_ids_keep_their_dots() {
        assert_eq!(
            parse_file_name("com.slashbuilder.demo.calc@0a1b2c3d.json"),
            ("com.slashbuilder.demo.calc", Some("0a1b2c3d"))
        );
        assert_eq!(
            parse_file_name("com.slashbuilder.demo.render-queue@ffffffff.json"),
            ("com.slashbuilder.demo.render-queue", Some("ffffffff"))
        );
        // Anything that is not ID@8hex.json has no instance; the id is the whole stem.
        for (bad, id) in [
            (
                "com.slashbuilder.demo.calc.json",
                "com.slashbuilder.demo.calc",
            ),
            (
                "com.slashbuilder.demo.calc@0A1B2C3D.json",
                "com.slashbuilder.demo.calc@0A1B2C3D",
            ),
            (
                "com.slashbuilder.demo.calc@0a1b2c3.json",
                "com.slashbuilder.demo.calc@0a1b2c3",
            ),
            (
                "com.slashbuilder.demo.calc@0a1b2c3d4.json",
                "com.slashbuilder.demo.calc@0a1b2c3d4",
            ),
            ("@0a1b2c3d.json", "@0a1b2c3d"),
            (
                "com.slashbuilder.demo.calc@.json",
                "com.slashbuilder.demo.calc@",
            ),
        ] {
            assert_eq!(parse_file_name(bad), (id, None), "{bad}");
        }
    }

    #[test]
    fn instance_ids_are_eight_lowercase_hex_digits_and_differ() {
        let ids: Vec<String> = (0..64).map(|_| new_instance_id()).collect();
        for id in &ids {
            assert!(is_instance_id(id), "{id}");
        }
        let distinct: std::collections::HashSet<&String> = ids.iter().collect();
        assert!(
            distinct.len() > 60,
            "64 draws gave {} distinct",
            distinct.len()
        );
    }

    #[test]
    fn announce_rejects_a_bad_instance_id() {
        let dir = TempDir::new("roster-badinst");
        let r = roster(&dir);
        for bad in ["", "xyz", "0A1B2C3D", "../../etc", "0a1b2c3d4"] {
            let e = r.announce(ID, bad, "Calc", "0.1.0", HEARTBEAT).unwrap_err();
            assert_eq!(e.kind(), io::ErrorKind::InvalidInput, "{bad}");
        }
    }

    #[test]
    fn entry_json_round_trips() {
        let now = Utc::now();
        let e = entry(now);
        let back = RosterEntry::from_json(&e.to_json()).unwrap();
        // ISO output is microsecond precision.
        assert_eq!(back.id, e.id);
        assert_eq!(back.instance, e.instance);
        assert!(
            (back.heartbeat_at - e.heartbeat_at)
                .num_microseconds()
                .unwrap()
                .abs()
                < 1
        );
    }
}
