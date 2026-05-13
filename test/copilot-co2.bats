#!/usr/bin/env bats

# Tests for bin/copilot-co2.sh
# Fixtures provide synthetic OTLP JSONL data with known token counts.

setup() {
    export COPILOT_CO2_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    export COPILOT_CO2_TRACES_FILE="${BATS_TEST_TMPDIR}/traces.jsonl"
    mkdir -p "${COPILOT_CO2_STATE_DIR}"

    script_dir="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    script="${script_dir}/bin/copilot-co2.sh"
    fixtures="${BATS_TEST_DIRNAME}/fixtures"
}

# ── Missing / empty traces file ─────────────────────────────────────

@test "exits cleanly when traces file does not exist" {
    rm -f "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]
    [[ ! -f "${COPILOT_CO2_STATE_DIR}/co2-state.json" ]]
}

@test "exits cleanly when traces file is empty" {
    touch "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]
}

# ── Token extraction ────────────────────────────────────────────────

@test "extracts tokens from a single chat span" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    # single-chat.jsonl: 500 input + 200 output = 700 tokens
    local _tokens
    _tokens=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")
    [[ "${_tokens}" -eq 700 ]]
}

@test "extracts tokens from multiple chat spans across lines" {
    cp "${fixtures}/two-chats.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    # two-chats.jsonl: (500+200) + (1000+300) = 2000 tokens
    local _tokens
    _tokens=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")
    [[ "${_tokens}" -eq 2000 ]]
}

@test "only counts chat spans, not invoke_agent spans" {
    cp "${fixtures}/chat-and-agent.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    # chat-and-agent.jsonl: chat has 500+200=700, invoke_agent has 500+200 (ignored)
    local _tokens
    _tokens=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")
    [[ "${_tokens}" -eq 700 ]]
}

@test "ignores spans from non-copilot services" {
    cp "${fixtures}/non-copilot.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    # non-copilot.jsonl: service is "some-other-service", should be ignored
    [[ ! -f "${COPILOT_CO2_STATE_DIR}/co2-state.txt" ]]
}

# ── CO₂ calculation ─────────────────────────────────────────────────

@test "calculates correct CO₂ for known token count" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    # 700 tokens × 0.003 kWh/1000 × 390 g/kWh = 0.819 g
    local _co2
    _co2=$(jq -r '.cumulative_co2_grams' "${COPILOT_CO2_STATE_DIR}/co2-state.json")
    # Allow for bc rounding: check it's between 0.8 and 0.9
    (( $(echo "${_co2} > 0.8" | bc -l) ))
    (( $(echo "${_co2} < 0.9" | bc -l) ))
}

# ── Incremental processing (offset) ────────────────────────────────

@test "processes new data incrementally using offset" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _tokens_after_first
    _tokens_after_first=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    # Append another line
    cat "${fixtures}/single-chat.jsonl" >> "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _tokens_after_second
    _tokens_after_second=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    # Should be double the first run
    [[ "${_tokens_after_second}" -eq $(( _tokens_after_first * 2 )) ]]
}

@test "skips processing when no new data since last run" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _offset_first
    _offset_first=$(jq -r '.last_offset' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    # Run again without new data
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _offset_second
    _offset_second=$(jq -r '.last_offset' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    [[ "${_offset_first}" -eq "${_offset_second}" ]]
}

# ── File rotation ───────────────────────────────────────────────────

@test "resets offset when file shrinks (rotation)" {
    # First run with two lines
    cp "${fixtures}/two-chats.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _tokens_before
    _tokens_before=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    # Simulate rotation: replace with smaller file
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _tokens_after
    _tokens_after=$(jq -r '.cumulative_tokens' "${COPILOT_CO2_STATE_DIR}/co2-state.json")

    # Should have accumulated: 2000 + 700 = 2700
    [[ "${_tokens_after}" -eq $(( _tokens_before + 700 )) ]]
}

# ── Display formatting ──────────────────────────────────────────────

@test "display shows milligrams for sub-gram values" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _display
    _display=$(cat "${COPILOT_CO2_STATE_DIR}/co2-state.txt")
    # 700 tokens → ~0.819g → should show as mg
    [[ "${_display}" == *"mg"* ]]
    [[ "${_display}" == *"CO₂"* ]]
    [[ "${_display}" == *"♨"* ]]
    [[ "${_display}" == *"🌳"* ]]
    [[ "${_display}" == *"tree"* ]]
}

@test "display shows grams for values >= 1g" {
    # Write pre-existing state with 5g CO₂
    cat > "${COPILOT_CO2_STATE_DIR}/co2-state.json" <<'EOF'
{
  "cumulative_tokens": 5000,
  "cumulative_co2_grams": 5.0,
  "last_offset": 0,
  "started_at": "2026-05-12T00:00:00+02:00",
  "last_updated": "2026-05-12T00:00:00+02:00"
}
EOF
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _display
    _display=$(cat "${COPILOT_CO2_STATE_DIR}/co2-state.txt")
    [[ "${_display}" == *"g CO₂"* ]]
    [[ "${_display}" != *"mg"* ]]
    [[ "${_display}" != *"kg"* ]]
}

@test "display shows kilograms for values >= 1000g" {
    cat > "${COPILOT_CO2_STATE_DIR}/co2-state.json" <<'EOF'
{
  "cumulative_tokens": 1000000,
  "cumulative_co2_grams": 1500.0,
  "last_offset": 0,
  "started_at": "2026-04-12T00:00:00+02:00",
  "last_updated": "2026-05-12T00:00:00+02:00"
}
EOF
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _display
    _display=$(cat "${COPILOT_CO2_STATE_DIR}/co2-state.txt")
    [[ "${_display}" == *"kg CO₂"* ]]
}

# ── Tree calculation ────────────────────────────────────────────────

@test "shows singular tree when only 1 needed" {
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _display
    _display=$(cat "${COPILOT_CO2_STATE_DIR}/co2-state.txt")
    [[ "${_display}" == *"1 tree"* ]]
    [[ "${_display}" != *"trees"* ]]
}

@test "shows plural trees when multiple needed" {
    # 30 days of 1500g → 50g/day → ~1 tree. Push higher.
    cat > "${COPILOT_CO2_STATE_DIR}/co2-state.json" <<'EOF'
{
  "cumulative_tokens": 5000000,
  "cumulative_co2_grams": 5000.0,
  "last_offset": 0,
  "started_at": "2026-04-12T00:00:00+02:00",
  "last_updated": "2026-05-12T00:00:00+02:00"
}
EOF
    cp "${fixtures}/single-chat.jsonl" "${COPILOT_CO2_TRACES_FILE}"
    run "${script}"
    [[ "${status}" -eq 0 ]]

    local _display
    _display=$(cat "${COPILOT_CO2_STATE_DIR}/co2-state.txt")
    [[ "${_display}" == *"trees"* ]]
}
