//! LLM-based message classifier — classifies user messages as "chat" or "order"
//! using a single fast LLM call. Replaces brittle rule-based keyword matching.
//!
//! - **Chat**: conversational messages (greetings, questions, opinions, thanks).
//!   The LLM provides a complete response in `chat_text`. One call total.
//! - **Order**: actionable requests (create, search, fix, open, build, etc.).
//!   The LLM provides a brief acknowledgment in `chat_text` and classifies difficulty.

use serde::{Deserialize, Serialize};
use skyclaw_core::types::error::SkyclawError;
use skyclaw_core::types::message::{ChatMessage, CompletionRequest, ContentPart, Usage};
use skyclaw_core::types::optimization::ExecutionProfile;
use skyclaw_core::Provider;
use tracing::{debug, info, warn};

/// Classification result from the LLM.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageClassification {
    pub category: MessageCategory,
    pub chat_text: String,
    pub difficulty: TaskDifficulty,
}

/// Whether a message is conversational or an actionable order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageCategory {
    Chat,
    Order,
    /// The request is ambiguous or missing info — ask a clarifying question.
    Clarify,
}

/// Difficulty level for order messages, maps to execution profiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskDifficulty {
    Simple,
    Standard,
    Complex,
}

impl TaskDifficulty {
    /// Convert to an execution profile for the agent pipeline.
    pub fn execution_profile(&self) -> ExecutionProfile {
        match self {
            TaskDifficulty::Simple => ExecutionProfile::simple(),
            TaskDifficulty::Standard => ExecutionProfile::standard(),
            TaskDifficulty::Complex => ExecutionProfile::complex(),
        }
    }
}

const CLASSIFY_SYSTEM_PROMPT: &str = r#"You are batabeto — the personal AI agent of Ahmed Ekram (goes by X), a DevOps engineer based in Cairo, Egypt.
Classify X's message and respond with ONLY a valid JSON object. No markdown, no explanation — just the JSON.

WHO X IS:
- Professional DevOps engineer — experienced, knows his tools, does not need hand-holding
- Also learning: ERB (Ruby on Rails ecosystem) — new territory for him
- Builds: AI/ML bots, web apps, DevOps infrastructure, experiments
- Talks to you in Arabic or English — reply in whichever language he used

CATEGORIES:
- "chat": Conversational — greetings, questions, opinions, study/learning questions, planning discussions, casual talk. You give a complete helpful answer.
- "clarify": The request is genuinely ambiguous OR you could do the WRONG THING without more info. Ask a focused question with buttons.
- "order": X wants you to DO something and the request is clear enough to execute now.

CLARIFY RULES — X hates unnecessary questions. Be strict:
✅ DO clarify when:
  - Multiple targets exist and you cannot infer which (e.g. "restart the service" — you know of 3 services)
  - A destructive action has irreversible consequences (e.g. "drop the database" — which one, are you sure?)
  - The task is fundamentally ambiguous and guessing wrong wastes significant time
✋ DO NOT clarify when:
  - X is a DevOps engineer asking about DevOps things — assume he knows what he means
  - The request has an obvious default (e.g. "check disk" = check /, "show logs" = journalctl -fu skyclaw)
  - You can make a reasonable inference and correct easily if wrong
  - It's a simple one-step task

DIFFICULTY (for orders only):
- "simple": Single tool call or direct answer
- "standard": Multi-step, needs several tool calls
- "complex": Deep work — debugging, architecture, research, multi-system analysis

Response format:
{"category":"chat","chat_text":"your response","difficulty":"simple"}

Rules:
- "chat": chat_text = your complete answer. Be the sharp brilliant friend — direct, no fluff.
- "clarify": chat_text = focused question + BUTTONS line with 2-4 options. Always end with "✏️ Other".
  Format: "<question>\nBUTTONS: Option A | Option B | ✏️ Other"
- "order": chat_text = brief natural ack (1-2 sentences max). e.g. "On it..." or "Let me check that."
- difficulty only matters for "order" — use "simple" for chat and clarify.
- ALWAYS reply in the same language X wrote in: Arabic → Arabic, English → English."#;

/// Classify a user message using a fast LLM call.
///
/// `history` must already include the current user message as its last element.
/// Returns the classification and the raw usage for budget tracking.
/// Falls back with an error if the provider call or JSON parsing fails —
/// the caller should use rule-based classification as fallback.
pub async fn classify_message(
    provider: &dyn Provider,
    model: &str,
    _user_text: &str,
    history: &[ChatMessage],
) -> Result<(MessageClassification, Usage), SkyclawError> {
    // Use last 10 history messages for conversational context.
    // History already includes the current user message (pushed by runtime
    // before calling classify), so we don't add it again.
    let context_start = history.len().saturating_sub(10);
    let messages: Vec<ChatMessage> = history[context_start..].to_vec();

    let request = CompletionRequest {
        model: model.to_string(),
        messages,
        tools: vec![],
        max_tokens: Some(1000),
        temperature: Some(0.0),
        system: Some(CLASSIFY_SYSTEM_PROMPT.to_string()),
    };

    debug!("LLM classify: sending classification request");

    let response = provider.complete(request).await?;

    // Extract text from response content
    let response_text = response
        .content
        .iter()
        .filter_map(|p| match p {
            ContentPart::Text { text } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("");

    debug!(raw_response = %response_text, "LLM classify: got response");

    let classification = parse_classification(&response_text)?;

    info!(
        category = ?classification.category,
        difficulty = ?classification.difficulty,
        chat_text_len = classification.chat_text.len(),
        "LLM classify: message classified"
    );

    Ok((classification, response.usage))
}

/// Parse the classification JSON from the LLM response.
/// Handles markdown code blocks, extra whitespace, and surrounding text.
fn parse_classification(text: &str) -> Result<MessageClassification, SkyclawError> {
    let json_str = extract_json(text);

    serde_json::from_str::<MessageClassification>(json_str).map_err(|e| {
        warn!(
            error = %e,
            raw = %text,
            "Failed to parse classification JSON"
        );
        SkyclawError::Provider(format!("Classification parse error: {}", e))
    })
}

/// Extract JSON object from text that may contain markdown formatting
/// or surrounding prose.
fn extract_json(text: &str) -> &str {
    let trimmed = text.trim();

    // Find the first '{' and last '}' to extract the JSON object
    if let Some(start) = trimmed.find('{') {
        if let Some(end) = trimmed.rfind('}') {
            if end >= start {
                return &trimmed[start..=end];
            }
        }
    }

    trimmed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_chat_classification() {
        let json = r#"{"category":"chat","chat_text":"Hello! How can I help you today?","difficulty":"simple"}"#;
        let result = parse_classification(json).unwrap();
        assert_eq!(result.category, MessageCategory::Chat);
        assert_eq!(result.chat_text, "Hello! How can I help you today?");
        assert_eq!(result.difficulty, TaskDifficulty::Simple);
    }

    #[test]
    fn parse_order_classification() {
        let json = r#"{"category":"order","chat_text":"On it! Let me search for that.","difficulty":"standard"}"#;
        let result = parse_classification(json).unwrap();
        assert_eq!(result.category, MessageCategory::Order);
        assert_eq!(result.chat_text, "On it! Let me search for that.");
        assert_eq!(result.difficulty, TaskDifficulty::Standard);
    }

    #[test]
    fn parse_complex_order() {
        let json = r#"{"category":"order","chat_text":"Let me dig into that codebase.","difficulty":"complex"}"#;
        let result = parse_classification(json).unwrap();
        assert_eq!(result.category, MessageCategory::Order);
        assert_eq!(result.difficulty, TaskDifficulty::Complex);
    }

    #[test]
    fn parse_clarify_classification() {
        let json = r#"{"category":"clarify","chat_text":"Which server should I deploy to?\nBUTTONS: Production | Staging | Dev | ✏️ Other","difficulty":"simple"}"#;
        let result = parse_classification(json).unwrap();
        assert_eq!(result.category, MessageCategory::Clarify);
        assert!(result.chat_text.contains("BUTTONS:"));
        assert_eq!(result.difficulty, TaskDifficulty::Simple);
    }

    #[test]
    fn parse_with_markdown_code_block() {
        let text =
            "```json\n{\"category\":\"chat\",\"chat_text\":\"Hi!\",\"difficulty\":\"simple\"}\n```";
        let result = parse_classification(text).unwrap();
        assert_eq!(result.category, MessageCategory::Chat);
        assert_eq!(result.chat_text, "Hi!");
    }

    #[test]
    fn parse_with_surrounding_text() {
        let text = "Here is the classification: {\"category\":\"order\",\"chat_text\":\"Sure!\",\"difficulty\":\"complex\"} end";
        let result = parse_classification(text).unwrap();
        assert_eq!(result.category, MessageCategory::Order);
        assert_eq!(result.difficulty, TaskDifficulty::Complex);
    }

    #[test]
    fn parse_with_extra_whitespace() {
        let text =
            "  \n  {\"category\":\"chat\",\"chat_text\":\"OK\",\"difficulty\":\"simple\"}  \n  ";
        let result = parse_classification(text).unwrap();
        assert_eq!(result.category, MessageCategory::Chat);
    }

    #[test]
    fn invalid_json_returns_error() {
        let result = parse_classification("not json at all");
        assert!(result.is_err());
    }

    #[test]
    fn empty_input_returns_error() {
        let result = parse_classification("");
        assert!(result.is_err());
    }

    #[test]
    fn difficulty_maps_to_execution_profile() {
        let simple = TaskDifficulty::Simple.execution_profile();
        assert_eq!(simple.max_iterations, 2);
        assert!(!simple.skip_tool_loop);

        let standard = TaskDifficulty::Standard.execution_profile();
        assert_eq!(standard.max_iterations, 5);

        let complex = TaskDifficulty::Complex.execution_profile();
        assert_eq!(complex.max_iterations, 10);
    }

    #[test]
    fn category_serde_roundtrip() {
        let chat = MessageCategory::Chat;
        let json = serde_json::to_string(&chat).unwrap();
        assert_eq!(json, "\"chat\"");
        let restored: MessageCategory = serde_json::from_str(&json).unwrap();
        assert_eq!(restored, MessageCategory::Chat);

        let order = MessageCategory::Order;
        let json = serde_json::to_string(&order).unwrap();
        assert_eq!(json, "\"order\"");

        let clarify = MessageCategory::Clarify;
        let json = serde_json::to_string(&clarify).unwrap();
        assert_eq!(json, "\"clarify\"");
        let restored: MessageCategory = serde_json::from_str(&json).unwrap();
        assert_eq!(restored, MessageCategory::Clarify);
    }

    #[test]
    fn difficulty_serde_roundtrip() {
        for difficulty in [
            TaskDifficulty::Simple,
            TaskDifficulty::Standard,
            TaskDifficulty::Complex,
        ] {
            let json = serde_json::to_string(&difficulty).unwrap();
            let restored: TaskDifficulty = serde_json::from_str(&json).unwrap();
            assert_eq!(restored, difficulty);
        }
    }

    #[test]
    fn full_classification_serde_roundtrip() {
        let classification = MessageClassification {
            category: MessageCategory::Order,
            chat_text: "Looking into it!".to_string(),
            difficulty: TaskDifficulty::Standard,
        };
        let json = serde_json::to_string(&classification).unwrap();
        let restored: MessageClassification = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.category, MessageCategory::Order);
        assert_eq!(restored.chat_text, "Looking into it!");
        assert_eq!(restored.difficulty, TaskDifficulty::Standard);
    }
}
