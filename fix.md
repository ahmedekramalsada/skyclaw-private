# Teloxide 0.17 API Gotchas
# Read this before writing ANY Telegram bot code with teloxide 0.17

---

## 1. PollAnswer voter field

### ❌ WRONG — does not exist in teloxide 0.17
```rust
// PollAnswerVoter enum path DOES NOT EXIST
match &answer.voter {
    teloxide::types::PollAnswerVoter::User(u) => u.id.0.to_string(),
    _ => "unknown".to_string(),
}

// .user field DOES NOT EXIST
answer.user.as_ref().map(|u| u.id.0.to_string())
```

### ✅ CORRECT — available fields on PollAnswer are: poll_id, voter, option_ids
```rust
// voter is a field but PollAnswerVoter enum variants are not directly matchable
// by path in 0.17 — use debug format to extract user ID safely
let voter_id = format!("{:?}", answer.voter)
    .chars().filter(|c| c.is_ascii_digit()).take(12).collect::<String>();
let voter_id = if voter_id.is_empty() { "unknown".to_string() } else { voter_id };
let username: Option<String> = None;
```

---

## 2. allowed_updates on DispatcherBuilder

### ❌ WRONG — .allowed_updates() does not exist on DispatcherBuilder in 0.17
```rust
let mut dispatcher = Dispatcher::builder(bot.clone(), handler)
    .allowed_updates(vec![
        teloxide::types::AllowedUpdate::Message,
        teloxide::types::AllowedUpdate::CallbackQuery,
        teloxide::types::AllowedUpdate::PollAnswer,
    ])
    .build(); // ERROR: trait bounds not satisfied
```

### ✅ CORRECT — set allowed_updates on the Polling listener, not the dispatcher
```rust
// Step 1: build dispatcher normally
let mut dispatcher = Dispatcher::builder(bot.clone(), handler).build();

// Step 2: build a Polling listener with allowed_updates
// NOTE: .build() is SYNCHRONOUS — no .await
let listener = teloxide::update_listeners::Polling::builder(bot.clone())
    .allowed_updates(vec![
        teloxide::types::AllowedUpdate::Message,
        teloxide::types::AllowedUpdate::CallbackQuery,
        teloxide::types::AllowedUpdate::PollAnswer,
    ])
    .build(); // NO .await — returns listener directly, not a future, not a Result

// Step 3: dispatch with the listener
dispatcher.dispatch_with_listener(
    listener,
    teloxide::error_handlers::LoggingErrorHandler::with_custom_text(
        "Telegram listener error",
    ),
).await;
```

---

## 3. Polling::build() is NOT async and NOT a Result

### ❌ WRONG
```rust
// Do NOT .await it
let listener = Polling::builder(bot).allowed_updates(...).build().await;

// Do NOT match it as a Result
match listener {
    Ok(l) => dispatcher.dispatch_with_listener(l, ...).await,
    Err(e) => dispatcher.dispatch().await,
}
```

### ✅ CORRECT
```rust
// Just call .build() — synchronous, returns Polling<Bot> directly
let listener = Polling::builder(bot).allowed_updates(...).build();
dispatcher.dispatch_with_listener(listener, ...).await;
```

---

## Summary table

| What you want | Wrong approach | Correct approach |
|---|---|---|
| Get voter ID from PollAnswer | `answer.user` or `PollAnswerVoter::User(u)` | `format!("{:?}", answer.voter)` extract digits |
| Set allowed_updates | `.allowed_updates()` on `DispatcherBuilder` | `.allowed_updates()` on `Polling::builder()` |
| Build Polling listener | `.build().await` | `.build()` (sync, no await) |
| Handle build result | `match result { Ok(l) => ... }` | direct: `let listener = ...build(); dispatch_with_listener(listener, ...)` |

---

## Full working pattern for poll_answer support in teloxide 0.17

```rust
// In the dispatcher loop rebuild block:

let tx_pa = tx.clone();

let handler = dptree::entry()
    .branch(Update::filter_message().endpoint(...))
    .branch(Update::filter_callback_query().endpoint(...))
    .branch(Update::filter_poll_answer().endpoint(
        move |_bot: Bot, answer: teloxide::types::PollAnswer| {
            let tx_poll = tx_pa.clone();
            async move {
                let owner_chat = std::env::var("OWNER_CHAT_ID").unwrap_or_default();
                if owner_chat.is_empty() {
                    return respond(());
                }
                // voter_id: extract digits from debug representation
                let voter_id = format!("{:?}", answer.voter)
                    .chars().filter(|c| c.is_ascii_digit()).take(12).collect::<String>();
                let voter_id = if voter_id.is_empty() { "unknown".to_string() } else { voter_id };
                let options = answer.option_ids.iter()
                    .map(|i| i.to_string()).collect::<Vec<_>>().join(", ");
                let inbound = InboundMessage {
                    id: uuid::Uuid::new_v4().to_string(),
                    channel: "telegram".to_string(),
                    chat_id: owner_chat,
                    user_id: voter_id,
                    username: None,
                    text: Some(format!("[Poll vote] poll_id:{} options:[{}]", answer.poll_id, options)),
                    attachments: vec![],
                    reply_to: None,
                    timestamp: chrono::Utc::now(),
                };
                let _ = tx_poll.send(inbound).await;
                respond(())
            }
        }
    ));

// Dispatcher: build normally
let mut dispatcher = Dispatcher::builder(bot.clone(), handler).build();

// Polling listener: build with allowed_updates (sync, no .await, no Result)
let listener = teloxide::update_listeners::Polling::builder(bot.clone())
    .allowed_updates(vec![
        teloxide::types::AllowedUpdate::Message,
        teloxide::types::AllowedUpdate::CallbackQuery,
        teloxide::types::AllowedUpdate::PollAnswer,
    ])
    .build();

// Dispatch with listener
dispatcher.dispatch_with_listener(
    listener,
    teloxide::error_handlers::LoggingErrorHandler::with_custom_text("Telegram listener error"),
).await;
```
