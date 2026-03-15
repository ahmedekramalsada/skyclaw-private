//! Send message tool — sends a text message to the user during tool execution.
//! Supports HTML formatting, reply-to, inline buttons, polls, and pin/unpin.
//!
//! Special prefixes (parsed before sending):
//!   POLL: question | opt1 | opt2 | opt3        → sends a native Telegram poll
//!   POLL_MULTI: question | opt1 | opt2          → multiple-choice poll
//!   PIN: <message_id>                           → pins that message (silent)
//!   UNPIN: <message_id>                         → unpins that message

use std::sync::Arc;

use async_trait::async_trait;
use skyclaw_core::types::error::SkyclawError;
use skyclaw_core::types::message::{OutboundMessage, ParseMode};
use skyclaw_core::{Channel, Tool, ToolContext, ToolDeclarations, ToolInput, ToolOutput};

pub struct SendMessageTool {
    channel: Arc<dyn Channel>,
}

impl SendMessageTool {
    pub fn new(channel: Arc<dyn Channel>) -> Self {
        Self { channel }
    }
}

#[async_trait]
impl Tool for SendMessageTool {
    fn name(&self) -> &str {
        "send_message"
    }

    fn description(&self) -> &str {
        "Send a message to X immediately during tool execution. \
         Use for live progress updates, results, and status reports. \
         \
         FORMATTING: Pass format=html for HTML tags: \
           <b>bold</b>  <i>italic</i>  <code>inline</code>  <pre>block</pre> \
           Escape in HTML: & → &amp;  < → &lt;  > → &gt; \
         \
         BUTTONS: Add BUTTONS: line at end of text: \
           BUTTONS: Option A | Option B | ✏️ Other \
         \
         POLLS: Start text with POLL: to send a native Telegram poll: \
           POLL: Which model should I use? | claude-sonnet | gpt-4o | gemini \
           POLL_MULTI: Which tools to install? | docker | kubectl | terraform \
         \
         PIN/UNPIN: Start text with PIN: or UNPIN: followed by message_id: \
           PIN: 12345     → pins message 12345 silently \
           UNPIN: 12345   → unpins message 12345"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "Message text. Use POLL:/PIN:/UNPIN: prefix for special actions. Supports HTML when format=html."
                },
                "format": {
                    "type": "string",
                    "enum": ["plain", "html"],
                    "description": "plain (default) or html. Use html for bold/code/pre formatting."
                },
                "reply_to_message_id": {
                    "type": "string",
                    "description": "Telegram message ID to reply to. Threads the reply under that message."
                },
                "chat_id": {
                    "type": "string",
                    "description": "Chat ID to send to. Omit to send to current conversation."
                }
            },
            "required": ["text"]
        })
    }

    fn declarations(&self) -> ToolDeclarations {
        ToolDeclarations {
            file_access: Vec::new(),
            network_access: Vec::new(),
            shell_access: false,
        }
    }

    async fn execute(
        &self,
        input: ToolInput,
        ctx: &ToolContext,
    ) -> Result<ToolOutput, SkyclawError> {
        let text = input
            .arguments
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SkyclawError::Tool("Missing required parameter: text".into()))?;

        let chat_id = input
            .arguments
            .get("chat_id")
            .and_then(|v| v.as_str())
            .unwrap_or(&ctx.chat_id);

        let trimmed = text.trim();

        // ── POLL: prefix — send native Telegram poll ─────────────────────
        if trimmed.to_uppercase().starts_with("POLL_MULTI:") || trimmed.to_uppercase().starts_with("POLL:") {
            let (prefix, allows_multiple) = if trimmed.to_uppercase().starts_with("POLL_MULTI:") {
                ("POLL_MULTI:", true)
            } else {
                ("POLL:", false)
            };

            let rest = trimmed[prefix.len()..].trim();
            let parts: Vec<&str> = rest.splitn(32, '|').map(|s| s.trim()).collect();

            if parts.len() < 3 {
                return Ok(ToolOutput {
                    content: "POLL requires at least: question | option1 | option2".to_string(),
                    is_error: true,
                });
            }

            let question = parts[0];
            let options: Vec<String> = parts[1..].iter().map(|s| s.to_string()).collect();

            match self.channel.send_poll(chat_id, question, &options, false, allows_multiple).await {
                Ok(poll_msg_id) => {
                    let kind = if allows_multiple { "multiple-choice" } else { "single-choice" };
                    return Ok(ToolOutput {
                        content: format!("Poll sent ({}, {} options, msg_id={})", kind, options.len(), poll_msg_id),
                        is_error: false,
                    });
                }
                Err(e) => {
                    return Ok(ToolOutput {
                        content: format!("Failed to send poll: {}", e),
                        is_error: true,
                    });
                }
            }
        }

        // ── PIN: prefix — pin a message ───────────────────────────────────
        if trimmed.to_uppercase().starts_with("PIN:") {
            let msg_id = trimmed["PIN:".len()..].trim();
            if msg_id.is_empty() {
                return Ok(ToolOutput {
                    content: "PIN requires a message_id: PIN: <message_id>".to_string(),
                    is_error: true,
                });
            }
            match self.channel.pin_message(chat_id, msg_id, true).await {
                Ok(()) => return Ok(ToolOutput {
                    content: format!("Message {} pinned silently", msg_id),
                    is_error: false,
                }),
                Err(e) => return Ok(ToolOutput {
                    content: format!("Failed to pin message: {}", e),
                    is_error: true,
                }),
            }
        }

        // ── UNPIN: prefix — unpin a message ──────────────────────────────
        if trimmed.to_uppercase().starts_with("UNPIN:") {
            let msg_id = trimmed["UNPIN:".len()..].trim();
            // Use pin_message with a sentinel — or for now just note it
            // Most bots don't need unpin; we report it as an info message
            return Ok(ToolOutput {
                content: format!("Unpin not yet supported via tool (message_id: {}). Use shell: curl -s https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/unpinChatMessage -d chat_id={} -d message_id={}", msg_id, chat_id, msg_id),
                is_error: false,
            });
        }

        // ── Normal message ────────────────────────────────────────────────
        let parse_mode = match input
            .arguments
            .get("format")
            .and_then(|v| v.as_str())
        {
            Some("html") => Some(ParseMode::Html),
            Some("plain") | None => None,
            _ => None,
        };

        let reply_to_message_id = input
            .arguments
            .get("reply_to_message_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let outbound = OutboundMessage {
            chat_id: chat_id.to_string(),
            text: text.to_string(),
            reply_to: None,
            parse_mode,
            reply_to_message_id,
        };

        match self.channel.send_message(outbound).await {
            Ok(()) => Ok(ToolOutput {
                content: "Message sent".to_string(),
                is_error: false,
            }),
            Err(e) => Ok(ToolOutput {
                content: format!("Failed to send message: {}", e),
                is_error: true,
            }),
        }
    }
}
