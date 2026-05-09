# Telegram Integration

Shelfarr supports a command-based Telegram bot integration.

## Setup

1. Create a bot with BotFather and copy its token.
2. In Shelfarr, open **Admin > Settings > Integrations > Telegram Bot**.
3. Enable Telegram and set:
   - bot token
   - bot username
   - webhook secret
   - allowed chat IDs
   - notification events
4. Use **Test Telegram Bot** to verify the token.
5. Use **Set Telegram Webhook** to register Shelfarr's webhook URL with Telegram.

The webhook endpoint is:

```text
/integrations/telegram/webhook
```

Telegram sends `X-Telegram-Bot-Api-Secret-Token`; Shelfarr requires it to match the configured webhook secret.

## User Linking

Users link their own Telegram account from **Profile**:

1. Generate a Telegram link code.
2. Send this command to the bot within 15 minutes:

```text
/link <shelfarr_username> <code>
```

After linking, the user can run request commands and receive lifecycle notifications.

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

- Telegram webhook secret
- allowed chat ID
- linked Telegram user ID
- per-user rate limit
- duplicate Telegram update IDs

Admin-managed `telegram_user_mappings` remain as a legacy fallback, but profile-generated link codes are preferred.
