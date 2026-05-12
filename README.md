# copilot-co2-trees 🌳

Estimates cumulative CO₂ from VS Code Copilot usage and displays it in your
[Starship](https://starship.rs/) prompt.

```
VS Code Copilot → OTel Collector → JSONL → CO₂ script → Starship prompt
                  (systemd user)           (systemd timer)
```

## Prerequisites

- **jq** — JSON processing
- **bc** — arithmetic
- **otelcol-contrib** — OpenTelemetry Collector (see below)
- **Starship** — cross-shell prompt

## Installing the OpenTelemetry Collector

The collector receives OTLP telemetry from VS Code and writes it to a local
JSONL file. The `otelcol-contrib` distribution is required (it includes the file
exporter).

See the [official install guide](https://opentelemetry.io/docs/collector/install/binary/linux/)
for full details. On Debian/Ubuntu/WSL:

```bash
# Check https://github.com/open-telemetry/opentelemetry-collector-releases/releases
# for the latest version
wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.151.0/otelcol-contrib_0.151.0_linux_amd64.deb
sudo dpkg -i otelcol-contrib_0.151.0_linux_amd64.deb
```

The package installs a system-level service. This project extends that service
with an additional config fragment — no need to disable it.

Verify: `otelcol-contrib --version`

## Installation

```bash
./install.sh
```

This will:

1. Symlink the config fragment into `/etc/otelcol-contrib/` and update `OTELCOL_OPTIONS` to load it (requires sudo)
2. Create the traces directory at `/var/lib/otelcol-contrib/copilot-otel/`
3. Restart the collector to pick up the new config
4. Symlink the CO₂ script and timer into user locations
5. Enable and start the CO₂ timer
6. Print the Starship config snippet to add to `~/.config/starship.toml`

### What gets installed

**System-level (sudo):**

| Source (repo) | Target |
|---|---|
| `config/otelcol-contrib/copilot-co2.yaml` | `/etc/otelcol-contrib/copilot-co2.yaml` |

**User-level:**

| Source (repo) | Target |
|---|---|
| `bin/copilot-co2.sh` | `~/.local/bin/copilot-co2.sh` |
| `systemd/copilot-co2.service` | `~/.config/systemd/user/copilot-co2.service` |
| `systemd/copilot-co2.timer` | `~/.config/systemd/user/copilot-co2.timer` |

## VS Code Configuration

Enable OTel export in VS Code settings:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318"
}
```

## Starship Configuration

Add to `~/.config/starship.toml`:

```toml
[custom.co2]
command = "cat ~/.local/share/copilot-otel/co2-state.txt"
when = "test -f ~/.local/share/copilot-otel/co2-state.txt"
format = "🌳 [$output]($style) "
style = "green"
```

## CO₂ Estimation Model

The estimate is rough and intended for awareness, not precision.

- **Energy per token:** ~0.003 kWh per 1000 tokens (GPT-4 class inference)
- **Carbon intensity:** 390 g CO₂/kWh (EU average 2024)
- **Per 1000 tokens:** ~1.17 g CO₂

Token counts are extracted from `chat` spans in the OTel trace data
(`gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`).

## How It Works

The OTel Collector is the server — it creates port 4318 and waits for
connections. VS Code is the client that sends telemetry data to it. If VS Code
isn't running or has OTel disabled, nothing connects and the collector simply
idles. In the reverse scenario — VS Code has OTel enabled but the collector
isn't running — VS Code silently drops the telemetry with no errors.

## Checking Status

```bash
# Collector
sudo systemctl status otelcol-contrib

# CO₂ timer
systemctl --user status copilot-co2.timer

# Current state
cat ~/.local/share/copilot-otel/co2-state.json

# Raw traces
tail /var/lib/otelcol-contrib/copilot-otel/traces.jsonl
```

## Uninstall

```bash
# Stop and disable the CO₂ timer
systemctl --user stop copilot-co2.timer
systemctl --user disable copilot-co2.timer
systemctl --user daemon-reload

# Remove user symlinks
rm ~/.local/bin/copilot-co2.sh
rm ~/.config/systemd/user/copilot-co2.{service,timer}

# Remove collector config fragment and revert OTELCOL_OPTIONS
sudo rm /etc/otelcol-contrib/copilot-co2.yaml
sudo sed -i 's| --config=/etc/otelcol-contrib/copilot-co2.yaml||' /etc/otelcol-contrib/otelcol-contrib.conf
sudo systemctl restart otelcol-contrib

# Remove data
sudo rm -rf /var/lib/otelcol-contrib/copilot-otel
rm -rf ~/.local/share/copilot-otel
```
