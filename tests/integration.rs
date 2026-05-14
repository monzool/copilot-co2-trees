//! Integration tests mirroring the original bats test suite.
//! Each test runs the compiled binary as a subprocess with temp dirs.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_copilot-co2-trees"))
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("test/fixtures")
}

struct TestEnv {
    _dir: tempfile::TempDir,
    state_dir: PathBuf,
    traces_file: PathBuf,
}

impl TestEnv {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = dir.path().join("state");
        let traces_file = dir.path().join("traces.jsonl");
        fs::create_dir_all(&state_dir).unwrap();
        Self {
            _dir: dir,
            state_dir,
            traces_file,
        }
    }

    fn run(&self) -> std::process::Output {
        Command::new(binary())
            .env("COPILOT_CO2_STATE_DIR", &self.state_dir)
            .env("COPILOT_CO2_TRACES_FILE", &self.traces_file)
            .output()
            .expect("failed to run binary")
    }

    fn copy_fixture(&self, name: &str) {
        fs::copy(fixtures_dir().join(name), &self.traces_file).unwrap();
    }

    fn state_json(&self) -> serde_json::Value {
        let contents = fs::read_to_string(self.state_dir.join("co2-state.json")).unwrap();
        serde_json::from_str(&contents).unwrap()
    }

    fn display_text(&self) -> String {
        fs::read_to_string(self.state_dir.join("co2-state.txt")).unwrap()
    }

    fn write_state(&self, json: &str) {
        fs::write(self.state_dir.join("co2-state.json"), json).unwrap();
    }

    fn state_file_exists(&self) -> bool {
        self.state_dir.join("co2-state.json").exists()
    }

    fn display_file_exists(&self) -> bool {
        self.state_dir.join("co2-state.txt").exists()
    }
}

// ── Missing / empty traces file ─────────────────────────────────────

#[test]
fn exits_cleanly_when_traces_file_does_not_exist() {
    let env = TestEnv::new();
    let output = env.run();
    assert!(output.status.success());
    assert!(!env.state_file_exists());
}

#[test]
fn exits_cleanly_when_traces_file_is_empty() {
    let env = TestEnv::new();
    fs::write(&env.traces_file, "").unwrap();
    let output = env.run();
    assert!(output.status.success());
}

// ── Token extraction ────────────────────────────────────────────────

#[test]
fn extracts_tokens_from_a_single_chat_span() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let state = env.state_json();
    assert_eq!(state["cumulative_tokens"], 700);
}

#[test]
fn extracts_tokens_from_multiple_chat_spans_across_lines() {
    let env = TestEnv::new();
    env.copy_fixture("two-chats.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let state = env.state_json();
    assert_eq!(state["cumulative_tokens"], 2000);
}

#[test]
fn only_counts_chat_spans_not_invoke_agent() {
    let env = TestEnv::new();
    env.copy_fixture("chat-and-agent.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let state = env.state_json();
    assert_eq!(state["cumulative_tokens"], 700);
}

#[test]
fn ignores_spans_from_non_copilot_services() {
    let env = TestEnv::new();
    env.copy_fixture("non-copilot.jsonl");
    let output = env.run();
    assert!(output.status.success());

    assert!(!env.display_file_exists());
}

// ── CO₂ calculation ─────────────────────────────────────────────────

#[test]
fn calculates_correct_co2_for_known_token_count() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let state = env.state_json();
    let co2 = state["cumulative_co2_grams"].as_f64().unwrap();
    assert!(co2 > 0.8 && co2 < 0.9, "expected ~0.819, got {co2}");
}

// ── Incremental processing (offset) ────────────────────────────────

#[test]
fn processes_new_data_incrementally_using_offset() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");

    let output = env.run();
    assert!(output.status.success());
    let tokens_first = env.state_json()["cumulative_tokens"].as_u64().unwrap();

    // Append another copy
    let extra = fs::read(fixtures_dir().join("single-chat.jsonl")).unwrap();
    let mut contents = fs::read(&env.traces_file).unwrap();
    contents.extend_from_slice(&extra);
    fs::write(&env.traces_file, contents).unwrap();

    let output = env.run();
    assert!(output.status.success());
    let tokens_second = env.state_json()["cumulative_tokens"].as_u64().unwrap();

    assert_eq!(tokens_second, tokens_first * 2);
}

#[test]
fn skips_processing_when_no_new_data() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");

    let output = env.run();
    assert!(output.status.success());
    let offset_first = env.state_json()["last_offset"].as_u64().unwrap();

    let output = env.run();
    assert!(output.status.success());
    let offset_second = env.state_json()["last_offset"].as_u64().unwrap();

    assert_eq!(offset_first, offset_second);
}

// ── File rotation ───────────────────────────────────────────────────

#[test]
fn resets_offset_when_file_shrinks() {
    let env = TestEnv::new();

    // First run with two-chats (2000 tokens)
    env.copy_fixture("two-chats.jsonl");
    let output = env.run();
    assert!(output.status.success());
    let tokens_before = env.state_json()["cumulative_tokens"].as_u64().unwrap();
    assert_eq!(tokens_before, 2000);

    // Simulate rotation: replace with smaller file
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());
    let tokens_after = env.state_json()["cumulative_tokens"].as_u64().unwrap();

    assert_eq!(tokens_after, 2700); // 2000 + 700
}

// ── Display formatting ──────────────────────────────────────────────

#[test]
fn display_shows_milligrams_for_sub_gram_values() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let display = env.display_text();
    assert!(display.contains("mg"), "expected mg in: {display}");
    assert!(display.contains("CO₂"), "expected CO₂ in: {display}");
    assert!(display.contains('♨'), "expected ♨ in: {display}");
    assert!(display.contains('🌳'), "expected 🌳 in: {display}");
    assert!(display.contains("tree"), "expected tree in: {display}");
}

#[test]
fn display_shows_grams_for_values_above_1g() {
    let env = TestEnv::new();
    env.write_state(
        r#"{
          "cumulative_tokens": 5000,
          "cumulative_co2_grams": 5.0,
          "last_offset": 0,
          "started_at": "2026-05-12T00:00:00+02:00",
          "last_updated": "2026-05-12T00:00:00+02:00"
        }"#,
    );
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let display = env.display_text();
    assert!(display.contains("g CO₂"), "expected 'g CO₂' in: {display}");
    assert!(
        !display.contains("mg"),
        "should not contain mg in: {display}"
    );
    assert!(
        !display.contains("kg"),
        "should not contain kg in: {display}"
    );
}

#[test]
fn display_shows_kilograms_for_values_above_1000g() {
    let env = TestEnv::new();
    env.write_state(
        r#"{
          "cumulative_tokens": 1000000,
          "cumulative_co2_grams": 1500.0,
          "last_offset": 0,
          "started_at": "2026-04-12T00:00:00+02:00",
          "last_updated": "2026-05-12T00:00:00+02:00"
        }"#,
    );
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let display = env.display_text();
    assert!(
        display.contains("kg CO₂"),
        "expected 'kg CO₂' in: {display}"
    );
}

// ── Tree calculation ────────────────────────────────────────────────

#[test]
fn shows_singular_tree_when_only_1_needed() {
    let env = TestEnv::new();
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let display = env.display_text();
    assert!(
        display.contains("1 tree"),
        "expected '1 tree' in: {display}"
    );
    assert!(
        !display.contains("trees"),
        "should not contain 'trees' in: {display}"
    );
}

#[test]
fn shows_plural_trees_when_multiple_needed() {
    let env = TestEnv::new();
    env.write_state(
        r#"{
          "cumulative_tokens": 5000000,
          "cumulative_co2_grams": 5000.0,
          "last_offset": 0,
          "started_at": "2026-04-12T00:00:00+02:00",
          "last_updated": "2026-05-12T00:00:00+02:00"
        }"#,
    );
    env.copy_fixture("single-chat.jsonl");
    let output = env.run();
    assert!(output.status.success());

    let display = env.display_text();
    assert!(display.contains("trees"), "expected 'trees' in: {display}");
}
