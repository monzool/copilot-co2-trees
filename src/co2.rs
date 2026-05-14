const KWH_PER_1K_TOKENS: f64 = 0.003;
const CO2_GRAMS_PER_KWH: f64 = 390.0; // EU average 2024

/// Calculate CO₂ grams produced by a given number of tokens.
pub fn calculate_co2(tokens: u64) -> f64 {
    tokens as f64 * KWH_PER_1K_TOKENS / 1000.0 * CO2_GRAMS_PER_KWH
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn co2_for_700_tokens() {
        // 700 × 0.003 / 1000 × 390 = 0.819
        let co2 = calculate_co2(700);
        assert!(co2 > 0.8 && co2 < 0.9, "expected ~0.819, got {co2}");
    }

    #[test]
    fn co2_for_zero_tokens() {
        assert!((calculate_co2(0) - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn co2_for_2000_tokens() {
        // 2000 × 0.003 / 1000 × 390 = 2.34
        let co2 = calculate_co2(2000);
        assert!((co2 - 2.34).abs() < 0.001, "expected 2.34, got {co2}");
    }
}
