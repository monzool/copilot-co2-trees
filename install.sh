#!/usr/bin/env bash
set -euo pipefail

# Installs copilot-co2-trees by symlinking repo files into system locations
# and enabling systemd user services.

repo_dir="$(cd "$(dirname "${0}")" && pwd)"

function check_dependencies() {
    local _cmd
    for _cmd in jq bc otelcol-contrib; do
        if ! command -v "${_cmd}" &>/dev/null; then
            echo "Error: ${_cmd} is required but not found in PATH" >&2
            echo "See README.md for installation instructions." >&2
            exit 1
        fi
    done
}

function create_symlink() {
    local _src="${1}"
    local _dst="${2}"

    mkdir -p "$(dirname "${_dst}")"

    if [[ -L "${_dst}" ]]; then
        rm "${_dst}"
    elif [[ -e "${_dst}" ]]; then
        echo "Warning: ${_dst} exists and is not a symlink, skipping" >&2
        return 1
    fi

    ln -s "${_src}" "${_dst}"
    echo "  ${_dst} → ${_src}"
}

function install_links() {
    echo "Creating symlinks..."

    create_symlink "${repo_dir}/bin/copilot-co2.sh" \
        "${HOME}/.local/bin/copilot-co2.sh"

    create_symlink "${repo_dir}/config/otelcol/config.yaml" \
        "${HOME}/.config/otelcol/config.yaml"

    create_symlink "${repo_dir}/systemd/otelcol.service" \
        "${HOME}/.config/systemd/user/otelcol.service"

    create_symlink "${repo_dir}/systemd/copilot-co2.service" \
        "${HOME}/.config/systemd/user/copilot-co2.service"

    create_symlink "${repo_dir}/systemd/copilot-co2.timer" \
        "${HOME}/.config/systemd/user/copilot-co2.timer"
}

function enable_services() {
    echo "Reloading systemd user daemon..."
    systemctl --user daemon-reload

    echo "Enabling services..."
    systemctl --user enable otelcol.service
    systemctl --user enable copilot-co2.timer

    echo "Starting services..."
    systemctl --user start otelcol.service
    systemctl --user start copilot-co2.timer
}

function show_starship_hint() {
    echo ""
    echo "Add the following to your ~/.config/starship.toml:"
    echo ""
    cat "${repo_dir}/starship/co2-module.toml"
    echo ""
}

function main() {
    echo "copilot-co2-trees installer"
    echo "==========================="
    echo ""

    check_dependencies
    install_links
    enable_services
    show_starship_hint

    echo "Done. Ensure VS Code has OTel enabled:"
    echo '  "github.copilot.chat.otel.enabled": true'
    echo '  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318"'
}

main
