# Setup Guide

## Prerequisites

- n8n account (n8n.cloud or self-hosted)
- Apify account with API token
- PhantomBuster account
- LLM API key (OpenRouter, Gemini, Open AI or Groq recommended)
- Google Account
- Telegram account

## Installation Steps

1.  **Clone the repository**

2.  **Import the Workflow**
    - Open n8n
    - Go to `Workflows → Import from File`
    - Select `workflow.json`

3.  **Configure Credentials**
    - Apify API
    - PhantomBuster
    - LLM Provider (OpenRouter / Gemini / Groq / Ollama / other)
    - Gmail / Google Sheets (OAuth2 or Service Account)
    - Telegram Bot

4.  **Google Sheets Setup**
    - Create a new spreadsheet
    - Share it with your Service Account (`Editor` access)
    - Copy the Spreadsheet ID

5.  **Telegram Bot Setup**
    - Message `@BotFather`
    - Create a bot and get the token
    - Get your personal chat ID

            How to Get Your Telegram Chat ID

            1. Open a chat with the bot you want to send messages from.

            2. Send any message to the bot (for example: `/start`).

            3. In your browser, open:
            https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates

            Replace `YOUR_BOT_TOKEN` with the token provided by `@BotFather`.

            Example token format:
            123456789:AAExampleBotToken123456789

            4. In the returned JSON response, find:

            json:
            "chat": {
            "id": 123456789
            }

            The value inside "id" is your Chat ID.

            Personal chats usually have a positive ID
            Group chats usually have a negative ID

6.  **Activate the Workflow**
    - Enable the `Schedule Trigger`
    - Recommended interval: every 3 hours
    - Test manually first

## **Troubleshooting**

- Apify Forbidden → Check API token or switch to PhantomBuster
- LLM errors → Reduce maxTokens or change model
- No jobs → Adjust search keywords in scraper nodes
