# Meera LinkedIn Post Bot

A Telegram bot that turns rough notes into a single LinkedIn post in Meera's voice.

1. Send rough notes to the bot on Telegram.
2. Gemini scores the thought out of 10 for LinkedIn-worthiness against the voice blueprint.
3. Below `min_score` (default 8): the bot replies with the score and a one-line reason.
4. At or above it: Gemini searches Google for recent related news, then writes exactly one post using `voice.md` as the style source of truth. The reply is the post only.

Each message is independent; the bot keeps no history.

## Setup (Windows, no installs needed)

1. Copy `config.example.json` to `config.json` and fill in your Telegram bot token and Gemini API key.
2. Double-click `start-bot.bat` (or run `powershell -ExecutionPolicy Bypass -File bot.ps1`).
3. Send `/start` to the bot. Its log prints your chat ID; add it to `allowed_chat_ids` so only you can use it.

Test the pipeline without Telegram:

```
powershell -ExecutionPolicy Bypass -File bot.ps1 -Test "your rough note"
```

## Config

| Key | Meaning |
| --- | --- |
| `gemini_model` | Main model |
| `fallback_models` | Tried in order when the main model is overloaded or unavailable |
| `min_score` | Score needed (out of 10) to get a post |
| `voice_file` | Voice blueprint used as the style guide |
| `allowed_chat_ids` | Telegram chat IDs allowed to use the bot; empty allows anyone |

The news step uses Gemini's Google Search grounding, which needs billing enabled on the Gemini key's project. Without it, posts are written from the notes alone.
