//! Small platform-neutral helpers shared by the client and the agent.
//!
//! Timestamps are RFC 3339 in UTC (the protocol uses strings, not epochs) and
//! JSON canonicalisation is used for request fingerprints, not for signing.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// Seconds since the Unix epoch (saturating at 0 for clocks before 1970).
pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Current time as an RFC 3339 UTC string with second resolution.
pub fn rfc3339_now() -> String {
    rfc3339_from_unix(unix_now())
}

/// Format seconds since the epoch as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn rfc3339_from_unix(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (year, month, day) = civil_from_days(days);
    let (hour, minute, second) = (rem / 3_600, (rem % 3_600) / 60, rem % 60);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Parse the RFC 3339 subset this project emits: `YYYY-MM-DDTHH:MM:SSZ`.
///
/// Fractional seconds and offsets are rejected; persisted job metadata only
/// ever contains the canonical form.
pub fn parse_rfc3339(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z' {
        return None;
    }
    let num = |a: usize, b: usize| -> Option<u64> { value.get(a..b)?.parse().ok() };
    let year = num(0, 4)? as i64;
    let month = num(5, 7)? as i64;
    let day = num(8, 10)? as i64;
    let hour = num(11, 13)?;
    let minute = num(14, 16)?;
    let second = num(17, 19)?;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some((days as u64) * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// Algorithm from Howard Hinnant's `chrono`-compatible civil calendar code.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Recursively sort JSON object keys so two semantically equal requests
/// serialise identically. Arrays keep their order (it is meaningful).
pub fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut out = serde_json::Map::with_capacity(map.len());
            for key in keys {
                out.insert(key.clone(), canonical_json(&map[key]));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical_json).collect()),
        other => other.clone(),
    }
}

/// Canonical JSON string (see [`canonical_json`]).
pub fn canonical_json_string(value: &Value) -> String {
    serde_json::to_string(&canonical_json(value)).unwrap_or_else(|_| String::from("null"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_and_known_dates() {
        assert_eq!(rfc3339_from_unix(0), "1970-01-01T00:00:00Z");
        // 2026-11-12T19:42:50Z
        assert_eq!(rfc3339_from_unix(1_763_034_170), "2025-11-13T11:42:50Z");
        assert_eq!(rfc3339_from_unix(1_700_000_000), "2023-11-14T22:13:20Z");
        assert_eq!(parse_rfc3339("2023-11-14T22:13:20Z"), Some(1_700_000_000));
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn rfc3339_round_trip() {
        for secs in [1_763_034_170_u64, 1_700_000_000, 946_684_800, 4_102_444_800] {
            let text = rfc3339_from_unix(secs);
            assert_eq!(parse_rfc3339(&text), Some(secs), "round trip for {text}");
        }
    }

    #[test]
    fn rejects_non_canonical_timestamps() {
        assert_eq!(parse_rfc3339("2023-11-14T22:13:20.123Z"), None);
        assert_eq!(parse_rfc3339("2023-11-14T22:13:20+01:00"), None);
        assert_eq!(parse_rfc3339("not-a-time"), None);
        assert_eq!(parse_rfc3339("2023-13-14T22:13:20Z"), None);
    }

    #[test]
    fn canonical_json_sorts_keys_recursively() {
        let a: Value = serde_json::from_str(r#"{"b":1,"a":{"d":2,"c":3}}"#).unwrap();
        let b: Value = serde_json::from_str(r#"{"a":{"c":3,"d":2},"b":1}"#).unwrap();
        assert_eq!(canonical_json_string(&a), canonical_json_string(&b));
        assert_eq!(canonical_json_string(&a), r#"{"a":{"c":3,"d":2},"b":1}"#);
        let c: Value = serde_json::from_str(r#"{"a":[2,1]}"#).unwrap();
        let d: Value = serde_json::from_str(r#"{"a":[1,2]}"#).unwrap();
        assert_ne!(canonical_json_string(&c), canonical_json_string(&d));
    }
}
