use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Co2State {
    pub cumulative_tokens: u64,
    pub cumulative_co2_grams: f64,
    pub last_offset: u64,
    pub started_at: DateTime<FixedOffset>,
    pub last_updated: DateTime<FixedOffset>,
}

impl Co2State {
    pub fn new(now: DateTime<FixedOffset>) -> Self {
        Self {
            cumulative_tokens: 0,
            cumulative_co2_grams: 0.0,
            last_offset: 0,
            started_at: now,
            last_updated: now,
        }
    }
}

pub fn load_state(path: &Path) -> io::Result<Option<Co2State>> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            let state: Co2State = serde_json::from_str(&contents)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            Ok(Some(state))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn save_state(path: &Path, state: &Co2State) -> io::Result<()> {
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    fs::write(path, json)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_state() -> Co2State {
        Co2State {
            cumulative_tokens: 5000,
            cumulative_co2_grams: 5.0,
            last_offset: 1024,
            started_at: DateTime::parse_from_rfc3339("2026-05-12T00:00:00+02:00").unwrap(),
            last_updated: DateTime::parse_from_rfc3339("2026-05-12T12:00:00+02:00").unwrap(),
        }
    }

    #[test]
    fn load_missing_file_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let result = load_state(&path).unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn round_trip_save_then_load() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("co2-state.json");
        let original = sample_state();
        save_state(&path, &original).unwrap();
        let loaded = load_state(&path).unwrap().expect("state should exist");
        assert_eq!(loaded, original);
    }

    #[test]
    fn deserialize_from_bash_format() {
        // JSON matching what the bash script writes
        let json = r#"{
          "cumulative_tokens": 5000,
          "cumulative_co2_grams": 5.0,
          "last_offset": 0,
          "started_at": "2026-05-12T00:00:00+02:00",
          "last_updated": "2026-05-12T00:00:00+02:00"
        }"#;
        let state: Co2State = serde_json::from_str(json).unwrap();
        assert_eq!(state.cumulative_tokens, 5000);
        assert!((state.cumulative_co2_grams - 5.0).abs() < f64::EPSILON);
        assert_eq!(state.last_offset, 0);
        assert_eq!(
            state.started_at,
            DateTime::parse_from_rfc3339("2026-05-12T00:00:00+02:00").unwrap()
        );
    }

    #[test]
    fn new_state_has_zero_values() {
        let now = DateTime::parse_from_rfc3339("2026-05-14T10:00:00+02:00").unwrap();
        let state = Co2State::new(now);
        assert_eq!(state.cumulative_tokens, 0);
        assert!((state.cumulative_co2_grams - 0.0).abs() < f64::EPSILON);
        assert_eq!(state.last_offset, 0);
        assert_eq!(state.started_at, now);
        assert_eq!(state.last_updated, now);
    }
}
