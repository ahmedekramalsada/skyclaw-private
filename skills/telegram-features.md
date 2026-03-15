---
name: telegram-features
description: Complete guide to using all Telegram features — formatting, buttons, polls, pins, files, replies
capabilities: [telegram, formatting, buttons, polls, pins, files, html, replies]
---

# Telegram Features

batabeto has full Telegram API access. Use these features actively — not just plain text.

---

## HTML FORMATTING

Use `format=html` in `send_message` when output has structure.

### Tags
```html
<b>bold text</b>
<i>italic text</i>
<code>inline code</code>
<pre>
multiline
code block
</pre>
<a href="https://example.com">link text</a>
<s>strikethrough</s>
<u>underline</u>
```

### CRITICAL: Always escape these in HTML content
```
&  →  &amp;
<  →  &lt;
>  →  &gt;
```

### When to use HTML
✅ Use for:
- Status reports with sections (use `<b>` for headers)
- Code output, error messages, config snippets (use `<pre>` or `<code>`)
- Deploy results with URLs
- Long structured outputs

❌ Skip for:
- Quick acks: "On it...", "Done"
- Simple questions
- Conversational replies

### Example — status report in HTML
```
send_message(
  text="<b>Deploy complete</b>\n\n<b>Service:</b> my-api\n<b>Version:</b> v2.1.3\n<b>Health:</b> ✅ 200 OK\n\n<pre>Container: my-api\nStatus: Up 12 seconds\nPort: 0.0.0.0:8080</pre>",
  format="html"
)
```

---

## INLINE BUTTONS

Add a `BUTTONS:` line at the end of any `send_message` text.

### Format
```
Your message text here
BUTTONS: Label A | Label B | Label C | ✏️ Other
```

### Rules
- Max 3 buttons per row (auto-wrapped)
- Always include `✏️ Other` as last option
- When X taps `✏️ Other` → batabeto automatically sends "✏️ Type your answer:" and waits
- Button taps arrive as regular text messages — process them normally
- Keep labels short: 1-5 words

### When to use buttons
✅ Use for:
- Plan approval: `BUTTONS: ✅ Execute | ✏️ Modify | ❌ Cancel`
- Clarifying questions: `BUTTONS: Production | Staging | Dev | ✏️ Other`
- Feature choices: `BUTTONS: 🚀 Deploy now | 📅 Schedule | ❌ Cancel`
- Post-task offers: `BUTTONS: ✅ Done | 📋 Show logs | 🔁 Run again`

---

## REAL TELEGRAM POLLS

Use the `send_message` tool with the `POLL:` prefix to send a native Telegram poll.

### Syntax
```
# Single-choice poll (user picks one)
POLL: question | option1 | option2 | option3

# Multiple-choice poll (user picks many)
POLL_MULTI: question | option1 | option2 | option3
```

### Examples
```
POLL: Which model should I use for this task? | claude-sonnet | gpt-4o | gemini-2.5-pro

POLL_MULTI: Which tools should I install on the new server? | docker | kubectl | terraform | nginx
```

### Parameters (handled automatically)
- `is_anonymous=false` — X can see who voted (just him anyway)
- Single-choice for decisions, POLL_MULTI for "select all that apply"

### When to use polls vs buttons

| Situation | Use |
|-----------|-----|
| Yes/No confirmation | Buttons |
| Plan approval (Execute/Cancel) | Buttons |
| Quick 2-3 option choice | Buttons |
| Choosing between 4+ technical approaches | Poll |
| Decision that feels permanent / official | Poll |
| Selecting a model, architecture, or stack | Poll |

### Reading poll answers
Poll votes arrive as:
```
[Poll vote] poll_id:abc123 options:[0]
```
`options:[0]` means X voted for the first option (0-indexed).
Parse the option index to know what X chose, then act on it.

### Smart poll settings
- `is_anonymous=false` — since it's just X, no need for anonymity
- `allows_multiple_answers=true` — use when multiple options can coexist (e.g. "which tools to install?")
- `allows_multiple_answers=false` — use when only one option wins (e.g. "which model to use?")

---

## PIN MESSAGES

Pin important messages so X can always find them.

### Syntax
```
# Pin a message by its ID (sent silently — no notification)
PIN: <message_id>

# To get a message_id: send_message_with_id returns it
```

### Full pin workflow
```
# Step 1: Send message and capture its ID
message_id = send_message_with_id(text="📊 Server Status...", chat_id=<chat_id>)

# Step 2: Pin it using the PIN: prefix in send_message
send_message(text="PIN: <message_id>", chat_id=<chat_id>)
```

### `disable_notification`
- `true` — pin silently (no ping to X)
- `false` — send notification that a message was pinned

### What to pin
✅ Pin:
- Daily/weekly status summaries
- Active project plan
- Important deploy results X wants to reference
- Links/URLs X asked to keep handy

❌ Don't pin:
- Routine progress updates
- Temporary results
- Error messages after they're resolved

---

## REPLY TO MESSAGE

Thread a reply under a specific message.

```
send_message(
  text="Here's the result of your request.",
  reply_to_message_id="<message_id from inbound message>"
)
```

The `reply_to_message_id` comes from `msg.id` on the inbound message X sent.

### When to use replies
- Directly answering a specific question X asked earlier in the chat
- Delivering a result that belongs to a request from minutes ago
- When X might have sent multiple messages and you want to clarify which you're answering

---

## FILE UPLOAD

Send any file directly to X.

```
send_file(chat_id=X's chat ID, path="/path/to/file", caption="optional caption")
```

### Max size: 50MB

### When to send files vs inline text
| Output size | Format |
|-------------|--------|
| < 20 lines | Inline in send_message |
| 20-100 lines | Inline with `<pre>` HTML block |
| > 100 lines | send_file as .txt or .log |
| Any config file X needs to edit | send_file |
| Diff / patch | send_file as .diff |
| Report / plan | send_file as .md |

### Offer pattern for long output
```
send_message(
  text="<b>Task complete.</b>\n\nOutput: 847 lines\nErrors: 0\nDuration: 12s",
  format="html"
)
send_message(
  text="Want the full output?",
  text="BUTTONS: 📄 Send full log | ✅ Summary is enough"
)
```

---

## COMBINING FEATURES

### Example: deploy result with buttons and HTML
```
send_message(
  text="<b>✅ Deploy complete</b>\n\n<b>Service:</b> my-api v2.1.3\n<b>Health:</b> 200 OK\n<b>Time:</b> 14:32 EET\n\nWhat next?\nBUTTONS: 🔁 Roll back | 📋 Show logs | ✅ All good",
  format="html"
)
```

### Example: pinnable status card
```python
# 1. Build the card
msg_id = send_message_with_id(
  text="<b>📊 Server Status — 14:00 EET</b>\n\nCPU: 12% | RAM: 45% | Disk: 62%\nDocker: 4/4 ✅ | Nginx: ✅ | K3s: ✅\nLast backup: 5 min ago ✅",
  format="html"
)
# 2. Pin it silently
pin_message(chat_id=X's chat ID, message_id=msg_id, disable_notification=true)
```
