# Telegram Integration

Shelfarr supports a command-based Telegram bot integration.

## Setup

1. Create a bot with BotFather and copy its token.
2. In Shelfarr, open **Admin > Settings > Integrations > Telegram Bot**.
3. Enable Telegram and set:
   - update mode, usually polling
   - bot token
   - bot username
   - request owner username, if you do not want to use the first admin
   - notification events
4. Use **Test Telegram Bot** to verify the token.

## Update Modes

Polling is the default mode. Shelfarr calls Telegram for updates from the running app, so local installs only need outbound internet access.

Webhook mode is optional for public HTTPS deployments. If you select webhook mode, set a webhook secret and use **Set Telegram Webhook** to register Shelfarr's webhook URL with Telegram.

The webhook endpoint is:

```text
/integrations/telegram/webhook
```

Telegram sends `X-Telegram-Bot-Api-Secret-Token`; Shelfarr requires it to match the configured webhook secret. Polling and webhooks cannot run at the same time. When polling mode is saved, Shelfarr clears the Telegram webhook for that bot token.

## Group Authorization

Shelfarr only accepts Telegram commands from authorized groups. Private chats are rejected.

1. Add the bot to a Telegram group.
2. Send any message or command to the bot from that group.
3. Shelfarr replies with a 6-digit approval code.
4. Within 2 minutes, an admin opens **Admin > Settings > Integrations > Telegram** and enters the code under **Telegram Group Authorization**.

After approval, the group can run commands. Requests created from Telegram are owned by the configured `telegram_request_username`; if that setting is blank, Shelfarr uses the first active admin.

Approved groups are listed on the same settings page. Pausing a group keeps the approval record but stops command processing and lifecycle notifications. Resuming re-enables the group. Deleting a group removes its approval, so it must pair again before it can use the bot.

`telegram_allowed_chat_ids` remains available as a manual fallback allowlist for group chat IDs, but the approval-code flow is preferred. If a stored group approval is paused, that pause takes precedence over the manual allowlist.

## Commands

```text
/search <title or author>
/request <work_id> <ebook|audiobook|both> [language]
/status
/whoami
/help
```

Search replies include inline buttons for quick ebook/audiobook requests.

## Access Control

Shelfarr checks all of the following:

- polling mode or webhook mode
- Telegram webhook secret, when webhook mode is used
- authorized, unpaused Telegram group or manual group allowlist
- configured Shelfarr request owner
- per-user rate limit
- duplicate Telegram update IDs

Lifecycle notifications for Telegram-created requests are sent back to the authorized group that created the request.
