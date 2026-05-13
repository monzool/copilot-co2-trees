#!/usr/bin/env bash
set -euo pipefail

# Processes OTel trace JSONL exported by the collector, extracts token usage
# from Copilot chat spans, and maintains a cumulative CO₂ estimate.
# Reads the traces file without modifying it (offset-based).

traces_file="${COPILOT_CO2_TRACES_FILE:-/var/lib/otelcol-contrib/copilot-otel/traces.jsonl}"
state_dir="${COPILOT_CO2_STATE_DIR:-${HOME}/.local/share/copilot-otel}"
state_file="${state_dir}/co2-state.json"
display_file="${state_dir}/co2-state.txt"

# CO₂ estimation constants
kwh_per_1k_tokens=0.003
co2_grams_per_kwh=390  # EU average 2024

# Tree absorption: ~22 kg CO₂/year for a mature broadleaf tree
tree_absorption_grams_per_day=$(( 22000 / 365 ))  # ~60 g/day

function check_dependencies() {
    local _cmd
    for _cmd in jq bc; do
        if ! command -v "${_cmd}" &>/dev/null; then
            echo "Error: ${_cmd} is required but not installed" >&2
            exit 1
        fi
    done
}

function extract_tokens() {
    local _file="${1}"
    local _offset="${2}"

    local _sum=0
    local _n
    while IFS= read -r _n; do
        (( _sum += _n ))
    done < <(
        tail -c +"$(( _offset + 1 ))" "${_file}" 2>/dev/null | \
        jq -r '
            [ .resourceSpans[]?
              | select(.resource.attributes[]?
                  | select(.key == "service.name")
                  | .value.stringValue?
                  | test("copilot"))
              | .scopeSpans[]?.spans[]?
              | select(.name? | test("^chat "))
              | .attributes[]?
              | select(.key == "gen_ai.usage.input_tokens"
                    or .key == "gen_ai.usage.output_tokens")
              | (.value.intValue // .value.stringValue // "0")
              | tonumber
            ] | add // 0
        ' 2>/dev/null
    )
    echo "${_sum}"
}

function load_state() {
    if [[ -f "${state_file}" ]]; then
        cumulative_tokens=$(jq -r '.cumulative_tokens // 0' "${state_file}")
        cumulative_co2=$(jq -r '.cumulative_co2_grams // 0' "${state_file}")
        last_offset=$(jq -r '.last_offset // 0' "${state_file}")
        started_at=$(jq -r '.started_at // ""' "${state_file}")
    else
        cumulative_tokens=0
        cumulative_co2=0
        last_offset=0
        started_at=""
    fi

    if [[ -z "${started_at}" ]]; then
        started_at=$(date -Iseconds)
    fi
}

function save_state() {
    cat > "${state_file}" <<EOF
{
  "cumulative_tokens": ${cumulative_tokens},
  "cumulative_co2_grams": ${cumulative_co2},
  "last_offset": ${last_offset},
  "started_at": "${started_at}",
  "last_updated": "$(date -Iseconds)"
}
EOF
}

function update_display() {
    local _grams="${cumulative_co2}"
    local _int_grams
    local _co2_display

    _int_grams=${_grams%%.*}
    _int_grams=${_int_grams:-0}

    if (( _int_grams >= 1000 )); then
        _co2_display=$(echo "scale=1; ${_grams} / 1000" | bc)
        _co2_display="${_co2_display}kg"
    elif (( _int_grams >= 1 )); then
        _co2_display=$(echo "scale=1; ${_grams}" | bc)
        _co2_display="${_co2_display}g"
    else
        _co2_display=$(echo "scale=1; ${_grams} * 1000" | bc)
        _co2_display="${_co2_display}mg"
    fi

    # Calculate trees needed to match daily average emission rate
    local _now
    local _start_epoch
    local _now_epoch
    local _days_elapsed
    local _trees

    _now=$(date -Iseconds)
    _start_epoch=$(date -d "${started_at}" +%s)
    _now_epoch=$(date -d "${_now}" +%s)
    _days_elapsed=$(( (_now_epoch - _start_epoch) / 86400 ))

    if (( _days_elapsed < 1 )); then
        _days_elapsed=1
    fi

    local _daily_avg_grams
    _daily_avg_grams=$(echo "scale=2; ${_grams} / ${_days_elapsed}" | bc)

    _trees=$(echo "scale=0; (${_daily_avg_grams} + ${tree_absorption_grams_per_day} - 1) / ${tree_absorption_grams_per_day}" | bc)

    if (( _trees < 1 )); then
        _trees=1
    fi

    local _tree_label="trees"
    if (( _trees == 1 )); then
        _tree_label="tree"
    fi

    echo "♨ ${_co2_display} CO₂ · 🌳 ${_trees} ${_tree_label}" > "${display_file}"
}

function main() {
    check_dependencies
    mkdir -p "${state_dir}"

    if [[ ! -f "${traces_file}" ]]; then
        exit 0
    fi

    load_state

    local _file_size
    _file_size=$(wc -c < "${traces_file}" 2>/dev/null || echo 0)

    # File shrunk → rotation happened, reset offset
    if (( _file_size < last_offset )); then
        last_offset=0
    fi

    # Nothing new to process
    if (( _file_size == last_offset )); then
        exit 0
    fi

    local _new_tokens
    _new_tokens=$(extract_tokens "${traces_file}" "${last_offset}")

    last_offset=${_file_size}

    if [[ "${_new_tokens}" == "0" ]] || [[ -z "${_new_tokens}" ]]; then
        save_state
        exit 0
    fi

    local _new_co2
    _new_co2=$(echo "scale=4; ${_new_tokens} * ${kwh_per_1k_tokens} / 1000 * ${co2_grams_per_kwh}" | bc)

    cumulative_tokens=$(( cumulative_tokens + _new_tokens ))
    cumulative_co2=$(echo "scale=4; ${cumulative_co2} + ${_new_co2}" | bc)

    save_state
    update_display
}

main
