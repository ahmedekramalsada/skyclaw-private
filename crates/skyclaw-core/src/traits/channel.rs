use crate::types::error::SkyclawError;
use crate::types::file::{FileMetadata, OutboundFile, ReceivedFile};
use crate::types::message::{InboundMessage, OutboundMessage};
use async_trait::async_trait;
use bytes::Bytes;
use futures::stream::BoxStream;

/// Messaging channel trait. Implement for each platform (Telegram, Discord, etc.)
#[async_trait]
pub trait Channel: Send + Sync {
    /// Channel name (e.g., "telegram", "discord", "cli")
    fn name(&self) -> &str;

    /// Start the channel listener (connect to platform API)
    async fn start(&mut self) -> Result<(), SkyclawError>;

    /// Stop the channel listener gracefully
    async fn stop(&mut self) -> Result<(), SkyclawError>;

    /// Send a text message to a specific chat
    async fn send_message(&self, msg: OutboundMessage) -> Result<(), SkyclawError>;

    /// Get the file transfer capability for this channel (None if not supported)
    fn file_transfer(&self) -> Option<&dyn FileTransfer>;

    /// Check if a user is allowed to use this channel
    fn is_allowed(&self, user_id: &str) -> bool;

    /// Delete a message from a chat by its ID.
    ///
    /// Used to remove sensitive content (API keys, credentials) from chat
    /// history after ingestion. Default implementation is a no-op for channels
    /// that don't support deletion (e.g. CLI).
    async fn delete_message(&self, _chat_id: &str, _message_id: &str) -> Result<(), SkyclawError> {
        Ok(())
    }

    /// Show a "typing..." indicator while the agent is working.
    /// Default no-op — meaningful only on real messaging platforms.
    async fn send_typing(&self, _chat_id: &str) -> Result<(), SkyclawError> {
        Ok(())
    }

    /// Edit an existing message in-place.
    async fn edit_message(
        &self,
        _chat_id: &str,
        _message_id: &str,
        _new_text: &str,
    ) -> Result<(), SkyclawError> {
        Ok(())
    }

    /// Send a message and return its platform message_id for later editing.
    /// Default: send normally, return empty string (editing not supported).
    async fn send_message_with_id(
        &self,
        msg: OutboundMessage,
    ) -> Result<String, SkyclawError> {
        self.send_message(msg).await?;
        Ok(String::new())
    }

    /// Send a native Telegram poll.
    /// question: the poll question text.
    /// options: list of answer strings (2-10 items).
    /// is_anonymous: true = anonymous poll, false = visible who voted.
    /// allows_multiple_answers: true = multiple choice, false = single choice.
    /// Default no-op — only Telegram implements this.
    async fn send_poll(
        &self,
        _chat_id: &str,
        _question: &str,
        _options: &[String],
        _is_anonymous: bool,
        _allows_multiple_answers: bool,
    ) -> Result<String, SkyclawError> {
        Ok(String::new())
    }

    /// Pin a message in a chat.
    /// message_id: the Telegram message ID to pin.
    /// disable_notification: true = pin silently (no notification).
    /// Default no-op — only Telegram implements this.
    async fn pin_message(
        &self,
        _chat_id: &str,
        _message_id: &str,
        _disable_notification: bool,
    ) -> Result<(), SkyclawError> {
        Ok(())
    }
}

/// Bi-directional file transfer sub-trait. Every messaging channel should implement this.
#[async_trait]
pub trait FileTransfer: Send + Sync {
    /// Receive files attached to an inbound message
    async fn receive_file(&self, msg: &InboundMessage) -> Result<Vec<ReceivedFile>, SkyclawError>;

    /// Send a file to a user via the messaging platform
    async fn send_file(&self, chat_id: &str, file: OutboundFile) -> Result<(), SkyclawError>;

    /// Stream a large file with progress
    async fn send_file_stream(
        &self,
        chat_id: &str,
        stream: BoxStream<'_, Bytes>,
        metadata: FileMetadata,
    ) -> Result<(), SkyclawError>;

    /// Maximum file size this channel supports (in bytes)
    fn max_file_size(&self) -> usize;
}
