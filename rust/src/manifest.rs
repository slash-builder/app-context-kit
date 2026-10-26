//! The app manifest (`app.json`): parse and validate, reporting the first failure only.
//!
//! Spec section 1. Validation order is fixed: the first failing rule decides the error code.

use std::fmt;

use serde_json::Value;

/// Why a manifest was rejected. [`ManifestError::code`] gives the spec's stable code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManifestError {
    /// The source text is not valid JSON (only from [`Manifest::parse`]; spec rule 0a).
    NotJson,
    NotObject,
    BadId,
    BadName,
    BadVersion,
    BadKits,
    DuplicateKit,
    BadPrefix,
    BadVenue,
}

impl ManifestError {
    /// The code string used by the spec and the fixtures.
    pub fn code(self) -> &'static str {
        match self {
            ManifestError::NotJson => "not-json",
            ManifestError::NotObject => "not-object",
            ManifestError::BadId => "bad-id",
            ManifestError::BadName => "bad-name",
            ManifestError::BadVersion => "bad-version",
            ManifestError::BadKits => "bad-kits",
            ManifestError::DuplicateKit => "duplicate-kit",
            ManifestError::BadPrefix => "bad-prefix",
            ManifestError::BadVenue => "bad-venue",
        }
    }
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid manifest: {}", self.code())
    }
}

impl std::error::Error for ManifestError {}

/// `venue.mode` in the manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VenueMode {
    Auto,
    On,
    Off,
}

impl VenueMode {
    pub fn as_str(self) -> &'static str {
        match self {
            VenueMode::Auto => "auto",
            VenueMode::On => "on",
            VenueMode::Off => "off",
        }
    }

    fn parse(s: &str) -> Option<VenueMode> {
        match s {
            "auto" => Some(VenueMode::Auto),
            "on" => Some(VenueMode::On),
            "off" => Some(VenueMode::Off),
            _ => None,
        }
    }
}

/// A validated manifest with the spec's defaults already applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub kits: Vec<String>,
    pub env_prefix: Option<String>,
    pub venue_mode: VenueMode,
    pub venue_consumer: String,
}

impl Manifest {
    /// Parses manifest text and validates it.
    pub fn parse(text: &str) -> Result<Manifest, ManifestError> {
        let value: Value = serde_json::from_str(text).map_err(|_| ManifestError::NotJson)?;
        Manifest::from_value(&value)
    }

    /// Validates an already-parsed JSON value.
    pub fn from_value(value: &Value) -> Result<Manifest, ManifestError> {
        let obj = value.as_object().ok_or(ManifestError::NotObject)?;

        let id = obj
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| is_reverse_dns(s))
            .ok_or(ManifestError::BadId)?;

        let name = obj
            .get("name")
            .and_then(Value::as_str)
            .filter(|s| !is_blank(s))
            .ok_or(ManifestError::BadName)?;

        let version = obj
            .get("version")
            .and_then(Value::as_str)
            .filter(|s| is_semver_triple(s))
            .ok_or(ManifestError::BadVersion)?;

        let kits = match obj.get("kits") {
            None => Vec::new(),
            Some(v) => parse_kits(v)?,
        };
        // Rule 5 runs after the whole list passed rule 4, so a bad name later in the
        // list beats an earlier duplicate. The spec's rule order leaves this open; the Rust crate chose this.
        for (i, kit) in kits.iter().enumerate() {
            if kits[..i].contains(kit) {
                return Err(ManifestError::DuplicateKit);
            }
        }

        let env_prefix = match obj.get("envPrefix") {
            None => None,
            Some(v) => Some(
                v.as_str()
                    .filter(|s| is_env_prefix(s))
                    .ok_or(ManifestError::BadPrefix)?
                    .to_string(),
            ),
        };

        let last_segment = id.rsplit('.').next().unwrap_or(id).to_string();
        let (venue_mode, venue_consumer) = match obj.get("venue") {
            None => (VenueMode::Auto, last_segment),
            Some(v) => parse_venue(v, last_segment)?,
        };

        Ok(Manifest {
            id: id.to_string(),
            name: name.to_string(),
            version: version.to_string(),
            kits,
            env_prefix,
            venue_mode,
            venue_consumer,
        })
    }

    /// The last dot-separated segment of the id (always present after validation).
    pub fn id_last_segment(&self) -> &str {
        self.id.rsplit('.').next().unwrap_or(&self.id)
    }
}

fn parse_kits(v: &Value) -> Result<Vec<String>, ManifestError> {
    let list = v.as_array().ok_or(ManifestError::BadKits)?;
    let mut kits = Vec::with_capacity(list.len());
    for item in list {
        let s = item
            .as_str()
            .filter(|s| is_kebab_name(s))
            .ok_or(ManifestError::BadKits)?;
        kits.push(s.to_string());
    }
    Ok(kits)
}

fn parse_venue(v: &Value, default_consumer: String) -> Result<(VenueMode, String), ManifestError> {
    let obj = v.as_object().ok_or(ManifestError::BadVenue)?;
    let mode = match obj.get("mode") {
        None => VenueMode::Auto,
        Some(m) => m
            .as_str()
            .and_then(VenueMode::parse)
            .ok_or(ManifestError::BadVenue)?,
    };
    let consumer = match obj.get("consumer") {
        None => default_consumer,
        Some(c) => c
            .as_str()
            .filter(|s| is_kebab_name(s))
            .ok_or(ManifestError::BadVenue)?
            .to_string(),
    };
    Ok((mode, consumer))
}

/// Spec rule 2: empty after removing ASCII whitespace (space, tab, CR, LF) only. `str::trim`
/// would also strip Unicode spaces such as U+00A0, which the spec counts as content, and
/// U+FEFF (not White_Space in Rust) counts as content too.
fn is_blank(s: &str) -> bool {
    s.chars().all(|c| matches!(c, ' ' | '\t' | '\r' | '\n'))
}

/// `^[a-z][a-z0-9-]*$`
fn is_kebab_name(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$`
pub(crate) fn is_reverse_dns(s: &str) -> bool {
    let mut segments = 0;
    for seg in s.split('.') {
        if !is_kebab_name(seg) {
            return false;
        }
        segments += 1;
    }
    segments >= 2
}

/// `^\d+\.\d+\.\d+$` with ASCII digits only.
fn is_semver_triple(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

/// `^[A-Z][A-Z0-9_]*$`
fn is_env_prefix(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_uppercase())
        && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn with_name(name: Value) -> Result<Manifest, ManifestError> {
        Manifest::from_value(
            &json!({"id": "com.slashbuilder.demo.calc", "name": name, "version": "0.1.0"}),
        )
    }

    #[test]
    fn a_name_is_blank_only_if_it_is_empty_after_removing_ascii_whitespace() {
        for blank in ["", " ", "\t", "\r\n", " \t\r\n "] {
            assert_eq!(
                with_name(json!(blank)),
                Err(ManifestError::BadName),
                "{blank:?}"
            );
        }
        // Everything else is content: U+FEFF, U+00A0, U+2003, vertical tab, form feed, NEL.
        for content in [
            "\u{feff}", "\u{a0}", "\u{2003}", "\u{b}", "\u{c}", "\u{85}", " a ",
        ] {
            assert!(with_name(json!(content)).is_ok(), "{content:?}");
        }
    }

    #[test]
    fn non_string_names_are_bad() {
        for v in [
            json!(null),
            json!(5),
            json!(["x"]),
            json!({"a": 1}),
            json!(true),
        ] {
            assert_eq!(with_name(v), Err(ManifestError::BadName));
        }
    }

    #[test]
    fn parse_distinguishes_not_json_from_not_object() {
        assert_eq!(Manifest::parse("{not json").unwrap_err().code(), "not-json");
        assert_eq!(Manifest::parse("").unwrap_err().code(), "not-json");
        assert_eq!(Manifest::parse("[1, 2]").unwrap_err().code(), "not-object");
        assert_eq!(Manifest::parse("null").unwrap_err().code(), "not-object");
        assert_eq!(Manifest::parse("\"s\"").unwrap_err().code(), "not-object");
        assert!(Manifest::parse(
            r#"{"id":"com.slashbuilder.demo.calc","name":"n","version":"1.2.3"}"#
        )
        .is_ok());
    }

    #[test]
    fn patterns_match_the_whole_string() {
        for (id, version) in [
            ("com.slashbuilder.demo.calc\n", "0.1.0"),
            ("com.slashbuilder.demo.calc", "0.1.0\n"),
        ] {
            let r = Manifest::from_value(&json!({"id": id, "name": "n", "version": version}));
            assert!(r.is_err(), "{id:?} {version:?}");
        }
        let m = |extra: Value| {
            let mut base =
                json!({"id": "com.slashbuilder.demo.calc", "name": "n", "version": "0.1.0"});
            base.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            Manifest::from_value(&base)
        };
        assert_eq!(m(json!({"kits": ["venue\n"]})), Err(ManifestError::BadKits));
        assert_eq!(
            m(json!({"envPrefix": "CALC\n"})),
            Err(ManifestError::BadPrefix)
        );
        assert_eq!(
            m(json!({"venue": {"consumer": "calc\n"}})),
            Err(ManifestError::BadVenue)
        );
    }

    #[test]
    fn a_bad_kit_anywhere_in_the_list_beats_a_duplicate_before_it() {
        let m = |kits: Value| {
            Manifest::from_value(
                &json!({"id": "com.slashbuilder.demo.calc", "name": "n", "version": "0.1.0", "kits": kits}),
            )
        };
        assert_eq!(
            m(json!(["venue", "venue", "Bad"])),
            Err(ManifestError::BadKits)
        );
        assert_eq!(
            m(json!(["venue", "venue"])),
            Err(ManifestError::DuplicateKit)
        );
    }
}
