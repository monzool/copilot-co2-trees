use serde::Deserialize;

#[derive(Deserialize)]
struct OtlpExport {
    #[serde(rename = "resourceSpans", default)]
    resource_spans: Vec<ResourceSpan>,
}

#[derive(Deserialize)]
struct ResourceSpan {
    #[serde(default)]
    resource: Resource,
    #[serde(rename = "scopeSpans", default)]
    scope_spans: Vec<ScopeSpan>,
}

#[derive(Deserialize, Default)]
struct Resource {
    #[serde(default)]
    attributes: Vec<Attribute>,
}

#[derive(Deserialize)]
struct ScopeSpan {
    #[serde(default)]
    spans: Vec<Span>,
}

#[derive(Deserialize)]
struct Span {
    #[serde(default)]
    name: String,
    #[serde(default)]
    attributes: Vec<Attribute>,
}

#[derive(Deserialize)]
struct Attribute {
    key: String,
    #[serde(default)]
    value: AttributeValue,
}

#[derive(Deserialize, Default)]
struct AttributeValue {
    #[serde(rename = "stringValue")]
    string_value: Option<String>,
    #[serde(rename = "intValue")]
    int_value: Option<String>,
}

fn is_copilot_resource(resource: &Resource) -> bool {
    resource.attributes.iter().any(|attr| {
        attr.key == "service.name"
            && attr
                .value
                .string_value
                .as_deref()
                .is_some_and(|v| v.contains("copilot"))
    })
}

fn is_chat_span(span: &Span) -> bool {
    span.name.starts_with("chat ")
}

fn token_value(attr: &Attribute) -> u64 {
    attr.value
        .int_value
        .as_deref()
        .or(attr.value.string_value.as_deref())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0)
}

/// Extract total token count from OTLP JSONL data.
///
/// Filters for Copilot service spans named "chat *" and sums
/// `gen_ai.usage.input_tokens` + `gen_ai.usage.output_tokens`.
pub fn extract_tokens(data: &[u8]) -> u64 {
    let mut total = 0u64;

    for line in data.split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }

        let export: OtlpExport = match serde_json::from_slice(line) {
            Ok(e) => e,
            Err(_) => continue,
        };

        for rs in &export.resource_spans {
            if !is_copilot_resource(&rs.resource) {
                continue;
            }
            for ss in &rs.scope_spans {
                for span in &ss.spans {
                    if !is_chat_span(span) {
                        continue;
                    }
                    for attr in &span.attributes {
                        if attr.key == "gen_ai.usage.input_tokens"
                            || attr.key == "gen_ai.usage.output_tokens"
                        {
                            total += token_value(attr);
                        }
                    }
                }
            }
        }
    }

    total
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn fixture(name: &str) -> Vec<u8> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("test/fixtures")
            .join(name);
        std::fs::read(path).unwrap()
    }

    #[test]
    fn single_chat_yields_700_tokens() {
        // single-chat.jsonl: 500 input + 200 output = 700
        assert_eq!(extract_tokens(&fixture("single-chat.jsonl")), 700);
    }

    #[test]
    fn two_chats_yields_2000_tokens() {
        // two-chats.jsonl: (500+200) + (1000+300) = 2000
        assert_eq!(extract_tokens(&fixture("two-chats.jsonl")), 2000);
    }

    #[test]
    fn agent_spans_are_ignored() {
        // chat-and-agent.jsonl: chat has 500+200=700, invoke_agent ignored
        assert_eq!(extract_tokens(&fixture("chat-and-agent.jsonl")), 700);
    }

    #[test]
    fn non_copilot_service_yields_zero() {
        // non-copilot.jsonl: service is "some-other-service"
        assert_eq!(extract_tokens(&fixture("non-copilot.jsonl")), 0);
    }

    #[test]
    fn empty_data_yields_zero() {
        assert_eq!(extract_tokens(b""), 0);
    }

    #[test]
    fn offset_based_processing() {
        let data = fixture("two-chats.jsonl");
        // Find the offset of the second line (after first newline)
        let first_newline = data.iter().position(|&b| b == b'\n').unwrap();
        let offset = first_newline + 1;

        let first_half = extract_tokens(&data[..offset]);
        let second_half = extract_tokens(&data[offset..]);

        // First line: 500+200=700, second line: 1000+300=1300
        assert_eq!(first_half, 700);
        assert_eq!(second_half, 1300);
        assert_eq!(first_half + second_half, 2000);
    }
}
