#!/usr/bin/env bash
set -euo pipefail

# Processes OTel trace JSONL exported by the collector, extracts token usage
# from chat spans, and maintains a cumulative CO₂ estimate in a state file.

data_dir="${HOME}/.local/share/copilot-otel"
traces_file="${data_dir}/traces.jsonl"
state_file="${data_dir}/co2-state.json"
display_file="${data_dir}/co2-state.txt"

# CO₂ estimation constants
kwh_per_1k_tokens=0.003
co2_grams_per_kwh=390  # EU average 2024

function check_dependencies() {
    local _cmd
    for _cmd in jq bc; do
        if ! command -v "${_cmd}" &>/dev/null; then
            echo "Error: ${_cmd} is required but not installed" >&2
            exit 1
        fi
    done
}

function extract_new_tokens() {
    local _file="${1}"

    jq -s '
        [ .[].resourceSpans[]?.scopeSpans[]?.spans[]?
          | select(.name | test("^chat "))
          | .attributes[]?
          | select(.key == "gen_ai.usage.input_tokens" or .key == "gen_ai.usage.output_tokens")
          | (.value.intValue // .value.stringValue // "0")
          | tonumber
        ] | add // 0
    ' "${_file}" 2>/dev/null || echo 0
}

function load_state() {
    if [[ -f "${state_file}" ]]; then
        cumulative_tokens=$(jq -r '.cumulative_tokens // 0' "${state_file}")
        cumulative_co2=$(jq -r '.cumulative_co2_grams // 0' "${state_file}")
    else
        cumulative_tokens=0
        cumulative_co2=0
    fi
}

function save_state() {
    cat > "${state_file}" <<EOF
{
  "cumulative_tokens": ${cumulative_tokens},
  "cumulative_co2_grams": ${cumulative_co2},
  "last_updated": "$(date -Iseconds)"
}
EOF
}

function update_display() {
    local _display
    if (( $(echo "${cumulative_co2} >= 1000" | bc -l) )); then
        _display=$(echo "scale=1; ${cumulative_co2} / 1000" | bc)
        echo "${_display}kg CO₂" > "${display_file}"
    else
        _display=$(echo "scale=1; ${cumulative_co2}" | bc)
        echo "${_display}g CO₂" > "${display_file}"
    fi
}

function main() {
    check_dependencies
    mkdir -p "${data_dir}"

    if [[ ! -f "${traces_file}" ]] || [[ ! -s "${traces_file}" ]]; then
        exit 0
    fi

    # Copy and truncate — safe with O_APPEND writers
    local _tmp_file="${data_dir}/traces.processing.jsonl"
    cp "${traces_file}" "${_tmp_file}"
    truncate -s 0 "${traces_file}"

    local _new_tokens
    _new_tokens=$(extract_new_tokens "${_tmp_file}")
    rm -f "${_tmp_file}"

    if [[ "${_new_tokens}" == "0" ]]; then
        exit 0
    fi

    load_state

    local _new_co2
    _new_co2=$(echo "scale=4; ${_new_tokens} * ${kwh_per_1k_tokens} / 1000 * ${co2_grams_per_kwh}" | bc)

    cumulative_tokens=$(echo "${cumulative_tokens} + ${_new_tokens}" | bc)
    cumulative_co2=$(echo "scale=4; ${cumulative_co2} + ${_new_co2}" | bc)

    save_state
    update_display
}

main
