#!/usr/bin/env bash
set -euo pipefail

# Installs copilot-co2-trees by:
# - Building the Rust binary (requires cargo)
# - Adding the collector config fragment alongside the main config
# - Updating the collector service to load the additional config
# - Installing the binary and systemd units into user locations

repo_dir="$(cd "$(dirname "${0}")" && pwd)"
otelcol_conf="/etc/otelcol-contrib/otelcol-contrib.conf"
otelcol_config_dir="/etc/otelcol-contrib"
traces_dir="/var/lib/otelcol-contrib/copilot-otel"

function check_dependencies() {
    local _cmd
    for _cmd in cargo otelcol-contrib; do
        if ! command -v "${_cmd}" &>/dev/null; then
            echo "Error: ${_cmd} is required but not found in PATH" >&2
            echo "See README.md for installation instructions." >&2
            exit 1
        fi
    done
}

function build_binary() {
    echo "Building copilot-co2-trees..."
    cargo build --release --manifest-path "${repo_dir}/Cargo.toml"
    echo "  Build complete"
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

    sudo cp "${repo_dir}/config/otelcol-contrib/copilot-co2.yaml" \
        "${otelcol_config_dir}/copilot-co2.yaml"
    sudo chown root:root "${otelcol_config_dir}/copilot-co2.yaml"
    echo "  Copied to ${otelcol_config_dir}/copilot-co2.yaml"

    # Add our config to OTELCOL_OPTIONS if not already present
    if ! grep -q "copilot-co2.yaml" "${otelcol_conf}" 2>/dev/null; then
        sudo sed -i 's|"$| --config=/etc/otelcol-contrib/copilot-co2.yaml"|' \
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

    local _bin_dir="${HOME}/.local/bin"
    local _dst="${_bin_dir}/copilot-co2-trees"
    mkdir -p "${_bin_dir}"
    cp "${repo_dir}/target/release/copilot-co2-trees" "${_dst}"
    chmod +x "${_dst}"
    echo "  ${_dst} (copied)"

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

function configure_starship() {
    local _config="${HOME}/.config/starship.toml"
    local _snippet="${repo_dir}/starship/co2-module.toml"

    if ! command -v starship &>/dev/null; then
        echo "Starship not detected. To show CO₂ in your prompt,"
        echo "add the following to your Starship config:"
        echo ""
        sed 's/^/  /' "${_snippet}"
        echo ""
        show_starship_format_hint
        return
    fi

    if [[ -f "${_config}" ]] && grep -q '\[custom\.co2\]' "${_config}" 2>/dev/null; then
        echo "  Starship [custom.co2] section already present"
        show_starship_format_hint
        return
    fi

    echo ""
    read -rp "Starship detected. Add [custom.co2] section to ${_config}? [Y/n] " _answer
    _answer="${_answer:-Y}"

    if [[ "${_answer}" =~ ^[Yy]$ ]]; then
        echo "" >> "${_config}"
        cat "${_snippet}" >> "${_config}"
        echo "  Added [custom.co2] section to ${_config}"
    else
        echo "  Skipped. To add manually, paste at the end of ${_config}:"
        echo ""
        sed 's/^/  /' "${_snippet}"
    fi

    echo ""
    show_starship_format_hint
}

function show_starship_format_hint() {
    echo "  If your starship.toml has a custom 'format' string, you also"
    echo '  need to add ${custom.co2}\ to it — otherwise the module will'
    echo "  not appear. Place it where you want it in the prompt layout,"
    echo '  for example just before $line_break or the bar-closing segment.'
}

function main() {
    echo "copilot-co2-trees installer"
    echo "==========================="
    echo ""

    check_dependencies
    build_binary
    install_collector_config
    install_user_components
    enable_services
    configure_starship

    echo "Done. Ensure VS Code has OTel enabled:"
    echo '  "github.copilot.chat.otel.enabled": true'
    echo '  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318"'
}

main
