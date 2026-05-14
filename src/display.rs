use chrono::{DateTime, FixedOffset};

/// Tree absorption: ~22 kg CO₂/year for a mature broadleaf tree → ~60 g/day.
const TREE_ABSORPTION_GRAMS_PER_DAY: f64 = 22_000.0 / 365.0;

/// Format CO₂ grams into a human-readable unit (mg, g, or kg).
fn format_co2(grams: f64) -> String {
    if grams >= 1000.0 {
        format!("{:.1}kg", grams / 1000.0)
    } else if grams >= 1.0 {
        format!("{:.1}g", grams)
    } else {
        format!("{:.1}mg", grams * 1000.0)
    }
}

/// Calculate number of trees needed to offset the daily average CO₂ rate.
fn trees_needed(
    co2_grams: f64,
    started_at: DateTime<FixedOffset>,
    now: DateTime<FixedOffset>,
) -> u64 {
    let days_elapsed = (now - started_at).num_days().max(1) as f64;
    let daily_avg = co2_grams / days_elapsed;
    let trees = (daily_avg / TREE_ABSORPTION_GRAMS_PER_DAY).ceil() as u64;
    trees.max(1)
}

/// Build the display string for the current CO₂ state.
///
/// Pure function: takes all inputs, returns the formatted string.
/// Example output: `♨ 819.0mg CO₂ · 🌳 1 tree`
pub fn format_display(
    co2_grams: f64,
    started_at: DateTime<FixedOffset>,
    now: DateTime<FixedOffset>,
) -> String {
    let co2_display = format_co2(co2_grams);
    let trees = trees_needed(co2_grams, started_at, now);
    let tree_label = if trees == 1 { "tree" } else { "trees" };
    format!("♨ {co2_display} CO₂ · 🌳 {trees} {tree_label}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::DateTime;

    fn ts(s: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(s).unwrap()
    }

    #[test]
    fn sub_gram_shows_milligrams() {
        let output = format_display(
            0.819,
            ts("2026-05-14T00:00:00+02:00"),
            ts("2026-05-14T01:00:00+02:00"),
        );
        assert!(output.contains("mg"), "expected mg in: {output}");
        assert!(output.contains("CO₂"), "expected CO₂ in: {output}");
        assert!(output.contains('♨'), "expected ♨ in: {output}");
        assert!(output.contains('🌳'), "expected 🌳 in: {output}");
        assert!(output.contains("tree"), "expected tree in: {output}");
    }

    #[test]
    fn grams_range_shows_grams() {
        let output = format_display(
            5.819,
            ts("2026-05-12T00:00:00+02:00"),
            ts("2026-05-14T00:00:00+02:00"),
        );
        assert!(output.contains("g CO₂"), "expected 'g CO₂' in: {output}");
        assert!(!output.contains("mg"), "should not contain mg in: {output}");
        assert!(!output.contains("kg"), "should not contain kg in: {output}");
    }

    #[test]
    fn kilograms_range_shows_kg() {
        let output = format_display(
            1500.0,
            ts("2026-04-12T00:00:00+02:00"),
            ts("2026-05-14T00:00:00+02:00"),
        );
        assert!(output.contains("kg CO₂"), "expected 'kg CO₂' in: {output}");
    }

    #[test]
    fn singular_tree_when_one_needed() {
        let output = format_display(
            0.819,
            ts("2026-05-14T00:00:00+02:00"),
            ts("2026-05-14T01:00:00+02:00"),
        );
        assert!(output.contains("1 tree"), "expected '1 tree' in: {output}");
        assert!(
            !output.contains("trees"),
            "should not contain 'trees' in: {output}"
        );
    }

    #[test]
    fn plural_trees_when_multiple_needed() {
        // 5000g over 32 days → ~156g/day → ~3 trees (156/60 = 2.6 → ceil = 3)
        let output = format_display(
            5000.0,
            ts("2026-04-12T00:00:00+02:00"),
            ts("2026-05-14T00:00:00+02:00"),
        );
        assert!(output.contains("trees"), "expected 'trees' in: {output}");
    }

    #[test]
    fn days_elapsed_minimum_is_one() {
        // started_at == now → should treat as 1 day, not divide by zero
        let output = format_display(
            100.0,
            ts("2026-05-14T10:00:00+02:00"),
            ts("2026-05-14T10:00:00+02:00"),
        );
        assert!(output.contains("CO₂"), "expected valid output: {output}");
    }
}
