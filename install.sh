#!/usr/bin/env bash
set -euo pipefail

# Installs copilot-co2-trees by:
# - Adding the collector config fragment alongside the main config
# - Updating the collector service to load the additional config
# - Symlinking the CO₂ script and timer into user locations

repo_dir="$(cd "$(dirname "${0}")" && pwd)"
otelcol_conf="/etc/otelcol-contrib/otelcol-contrib.conf"
otelcol_config_dir="/etc/otelcol-contrib"
traces_dir="/var/lib/otelcol-contrib/copilot-otel"

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

function install_collector_config() {
    echo "Installing collector config fragment..."

    sudo ln -sf "${repo_dir}/config/otelcol-contrib/copilot-co2.yaml" \
        "${otelcol_config_dir}/copilot-co2.yaml"
    echo "  ${otelcol_config_dir}/copilot-co2.yaml → repo"

    # Add our config to OTELCOL_OPTIONS if not already present
    if ! grep -q "copilot-co2.yaml" "${otelcol_conf}" 2>/dev/null; then
        sudo sed -i 's|^OTELCOL_OPTIONS=.*|& --config=/etc/otelcol-contrib/copilot-co2.yaml|' \
            "${otelcol_conf}"
        echo "  Updated ${otelcol_conf}"
    else
        echo "  ${otelcol_conf} already configured"
    fi

    # Create traces directory under the collector's data dir
    sudo mkdir -p "${traces_dir}"
    sudo chown otelcol-contrib:otelcol-contrib "${traces_dir}"

    # Allow current user to read collector output
    sudo usermod -aG otelcol-contrib "$(whoami)"
    echo "  Added $(whoami) to otelcol-contrib group"
    echo "  Note: Log out and back in for group membership to take effect"
}

function install_user_components() {
    echo "Installing user components..."

    create_symlink "${repo_dir}/bin/copilot-co2.sh" \
        "${HOME}/.local/bin/copilot-co2.sh"

    create_symlink "${repo_dir}/systemd/copilot-co2.service" \
        "${HOME}/.config/systemd/user/copilot-co2.service"

    create_symlink "${repo_dir}/systemd/copilot-co2.timer" \
        "${HOME}/.config/systemd/user/copilot-co2.timer"
}

function enable_services() {
    echo "Restarting collector..."
    sudo systemctl restart otelcol-contrib

    echo "Enabling CO₂ timer..."
    systemctl --user daemon-reload
    systemctl --user enable copilot-co2.timer
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
    install_collector_config
    install_user_components
    enable_services
    show_starship_hint

    echo "Done. Ensure VS Code has OTel enabled:"
    echo '  "github.copilot.chat.otel.enabled": true'
    echo '  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318"'
}

main
