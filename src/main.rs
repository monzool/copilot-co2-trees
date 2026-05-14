mod co2;
mod display;
mod state;
mod tokens;

use chrono::Local;
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::process;

fn main() {
    if let Err(e) = run() {
        eprintln!("Error: {e}");
        process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let traces_file = env::var("COPILOT_CO2_TRACES_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/lib/otelcol-contrib/copilot-otel/traces.jsonl"));

    let state_dir = env::var("COPILOT_CO2_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = env::var("HOME").unwrap_or_else(|_| ".".to_string());
            PathBuf::from(home).join(".local/share/copilot-otel")
        });

    let state_file = state_dir.join("co2-state.json");
    let display_file = state_dir.join("co2-state.txt");

    // Exit cleanly if traces file doesn't exist
    if !traces_file.exists() {
        return Ok(());
    }

    fs::create_dir_all(&state_dir)?;

    let now = Local::now().fixed_offset();

    let mut state = state::load_state(&state_file)?.unwrap_or_else(|| state::Co2State::new(now));

    let file_size = fs::metadata(&traces_file)?.len();

    // File shrunk → rotation happened, reset offset
    if file_size < state.last_offset {
        state.last_offset = 0;
    }

    // Nothing new to process — still refresh display (tree count evolves over time)
    if file_size == state.last_offset {
        if state.cumulative_tokens > 0 {
            write_display(
                &display_file,
                state.cumulative_co2_grams,
                state.started_at,
                now,
            )?;
        }
        return Ok(());
    }

    // Read new data from offset
    let mut file = fs::File::open(&traces_file)?;
    file.seek(SeekFrom::Start(state.last_offset))?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)?;

    let new_tokens = tokens::extract_tokens(&data);
    state.last_offset = file_size;

    if new_tokens == 0 {
        state.last_updated = now;
        state::save_state(&state_file, &state)?;
        if state.cumulative_tokens > 0 {
            write_display(
                &display_file,
                state.cumulative_co2_grams,
                state.started_at,
                now,
            )?;
        }
        return Ok(());
    }

    let new_co2 = co2::calculate_co2(new_tokens);
    state.cumulative_tokens += new_tokens;
    state.cumulative_co2_grams += new_co2;
    state.last_updated = now;

    state::save_state(&state_file, &state)?;
    write_display(
        &display_file,
        state.cumulative_co2_grams,
        state.started_at,
        now,
    )?;

    Ok(())
}

fn write_display(
    path: &PathBuf,
    co2_grams: f64,
    started_at: chrono::DateTime<chrono::FixedOffset>,
    now: chrono::DateTime<chrono::FixedOffset>,
) -> io::Result<()> {
    let output = display::format_display(co2_grams, started_at, now);
    fs::write(path, &output)?;
    if io::stdout().is_terminal() {
        println!("{output}");
    }
    Ok(())
}
