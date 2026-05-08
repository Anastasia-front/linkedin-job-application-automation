# Architecture

## Overview

**LinkedIn Job Application Automation** is a production-grade AI agent system that automatically scrapes LinkedIn jobs, intelligently evaluates them, generates personalized cover letters, and notifies the user if an error occurs.

Built as a **pet project + portfolio piece** to demonstrate real-world AI automation, n8n orchestration, and multi-LLM workflows.

# Core Components

| Layer | Technology | Responsibility |
|---|---|---|
| Scheduling | n8n Schedule Trigger | Periodic execution |
| Data Collection | Apify + PhantomBuster | Reliable job scraping with fallback |
| Preprocessing | Code + If Nodes | Language detection, remote filter, validation |
| AI Evaluation | LLM | Relevance scoring |
| Personalization | LLM | Cover letter generation |
| Storage | Google Sheets | Applications log + deduplication |
| Notifications | Telegram / Gmail | Real-time alerts |
---

# Key Features & Design Decisions

- **Dual Scraper Resilience** — Apify as primary + PhantomBuster as automatic fallback
- **Two-stage AI Processing** — Fast scoring first, then full cover letter generation only for good matches (saves tokens & cost)
- **Smart Deduplication** — Prevents duplicate applications using Google Sheets
- **Local LLM Support** — Compatible with Ollama for zero-cost operation
- **Modular Design** — Easy to maintain and extend