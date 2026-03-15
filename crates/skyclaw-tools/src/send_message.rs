//! Send message tool — sends a text message to the user during tool execution.
//! Supports HTML formatting, reply-to, and inline buttons via BUTTONS: syntax.

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
         Supports HTML formatting (bold, code, pre blocks) and inline buttons. \
         HTML tags: <b>bold</b>, <i>italic</i>, <code>inline code</code>, \
         <pre>code block</pre>, <a href=\'url\'>link</a>. \
         Add inline buttons with a BUTTONS: line at the end of text: \
         BUTTONS: Option A | Option B | ✏️ Other"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "Message text. Supports HTML tags when format=html."
                },
                "format": {
                    "type": "string",
                    "enum": ["plain", "html"],
                    "description": "Message format. Use html for bold/code/pre formatting. Default: plain."
                },
                "reply_to_message_id": {
                    "type": "string",
                    "description": "Telegram message ID to reply to. Makes message appear as a reply."
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
