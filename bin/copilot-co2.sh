#!/usr/bin/env bash
set -euo pipefail

# Processes OTel trace JSONL exported by the collector, extracts token usage
# from Copilot chat spans, and maintains a cumulative CO₂ estimate.
# Reads the traces file without modifying it (offset-based).

traces_file="/var/lib/otelcol-contrib/copilot-otel/traces.jsonl"
state_dir="${HOME}/.local/share/copilot-otel"
state_file="${state_dir}/co2-state.json"
display_file="${state_dir}/co2-state.txt"

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
    else
        cumulative_tokens=0
        cumulative_co2=0
        last_offset=0
    fi
}

function save_state() {
    cat > "${state_file}" <<EOF
{
  "cumulative_tokens": ${cumulative_tokens},
  "cumulative_co2_grams": ${cumulative_co2},
  "last_offset": ${last_offset},
  "last_updated": "$(date -Iseconds)"
}
EOF
}

function update_display() {
    local _grams="${cumulative_co2}"
    local _int_grams
    local _display

    _int_grams=${_grams%%.*}
    _int_grams=${_int_grams:-0}

    if (( _int_grams >= 1000 )); then
        _display=$(echo "scale=1; ${_grams} / 1000" | bc)
        echo "${_display}kg CO₂" > "${display_file}"
    elif (( _int_grams >= 1 )); then
        _display=$(echo "scale=1; ${_grams}" | bc)
        echo "${_display}g CO₂" > "${display_file}"
    else
        _display=$(echo "scale=1; ${_grams} * 1000" | bc)
        echo "${_display}mg CO₂" > "${display_file}"
    fi
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
