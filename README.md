# 🎫 AI Support Ticket Triage & Routing System

> A portfolio-grade automation project demonstrating advanced n8n workflow design, AI-powered decision making, production error handling, retry architecture, and human-in-the-loop governance.

---

## 📋 Project Overview

This system automates the complete lifecycle of customer support tickets — from multi-channel intake through AI classification, intelligent department routing, human review for uncertain cases, and full audit traceability.

Built to showcase the skills expected of an **AI Automation Engineer**, **Forward Deployed Engineer**, or **Workflow Automation Consultant**.

---

## 🏗️ Architecture Diagram

```
┌─────────────┐    ┌──────────────┐    ┌─────────────────┐
│   Customer  │───▶│  WF01        │───▶│  WF02           │
│  Submits    │    │  Ticket      │    │  AI             │
│  Ticket     │    │  Intake      │    │  Classification │
└─────────────┘    └──────────────┘    └────────┬────────┘
                                                │
                                     ┌──────────▼──────────┐
                                     │  WF03               │
                                     │  Review & Routing   │
                                     │                     │
                                     │  confidence < 80?   │
                                     │  ├─ YES → Review Q  │
                                     │  └─ NO  → Dept Q   │
                                     └─────────────────────┘
                                     
         On any failure:
         ┌──────────┐    ┌──────────────────┐
         │  WF05    │───▶│  WF04            │
         │  Error   │    │  Retry           │
         │  Handler │    │  10s→30s→60s→DLQ │
         └──────────┘    └──────────────────┘
```

---

## ✨ Features

### Core Capabilities
- ✅ **Multi-channel ticket intake** — webhook, manual form, extendable to email
- ✅ **AI-powered classification** using Groq LLaMA 3.3 70B
- ✅ **Structured JSON output** with category, priority, confidence, reasoning
- ✅ **Confidence-gated human review** — tickets below 80% confidence halt for review
- ✅ **5-department routing** — Billing, Support, Security, Sales, Account Management
- ✅ **Exponential backoff retry** — 10s → 30s → 60s before Dead Letter Queue
- ✅ **Dead Letter Queue** for permanently failed tickets
- ✅ **Immutable audit trail** — every state change logged to PostgreSQL
- ✅ **Global error handler** with error type classification

### Production-Grade Patterns
- 🔄 Asynchronous workflow chaining via internal webhooks
- 🔒 Credential vault for all API keys
- 📊 Comprehensive PostgreSQL schema with indexes and foreign keys
- 🐳 Complete Docker Compose stack (n8n + PostgreSQL + Redis)
- 📝 Full architecture documentation with Mermaid diagrams

---

## 🛠️ Tech Stack

| Component | Technology |
|-----------|-----------|
| Workflow Engine | n8n (latest) |
| AI Model | Groq — LLaMA 3.3 70B Versatile |
| Database | PostgreSQL 16 |
| Cache/Queue | Redis 7 |
| Container | Docker Compose |
| DB Admin | pgAdmin 4 (optional) |

---

## 🚀 Setup Instructions

### Prerequisites
- Docker & Docker Compose installed
- Groq API key ([get one free](https://console.groq.com/keys))
- 4GB RAM available for containers

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/ai-support-triage.git
cd ai-support-triage
```

### 2. Configure environment variables

```bash
cp .env.example .env
```

Edit `.env` and set:
```env
GROQ_API_KEY=gsk_your_actual_key_here
N8N_ENCRYPTION_KEY=your_32_char_random_string
N8N_BASIC_AUTH_PASSWORD=your_secure_password
POSTGRES_PASSWORD=your_db_password
```

Generate a secure encryption key:
```bash
openssl rand -hex 32
```

### 3. Start the stack

```bash
cd docker
docker compose up -d

# With pgAdmin (optional):
docker compose --profile dev up -d
```

### 4. Verify services

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| n8n | http://localhost:5678 | admin / (your password) |
| pgAdmin | http://localhost:5050 | admin@triage.local / pgadminpassword |
| PostgreSQL | localhost:5432 | n8n / (your password) |
| Redis | localhost:6379 | (your redis password) |

### 5. Initialize the database

```bash
# Connect to PostgreSQL and run schema
docker exec -i postgres_triage psql -U n8n -d support_tickets < db/schema.sql
```

---

## 🔑 Groq API Configuration

1. Sign up at [console.groq.com](https://console.groq.com)
2. Create an API key
3. Add to `.env`: `GROQ_API_KEY=gsk_...`

**In n8n Credentials:**
1. Go to Settings → Credentials → New
2. Type: **HTTP Header Auth**
3. Name: `Groq API Key`
4. Header Name: `Authorization`
5. Header Value: `Bearer {{ $env.GROQ_API_KEY }}`

---

## 📥 Workflow Imports

Import workflows in this order:

1. **Settings → Workflows → Import**
2. Upload files in order:

```
workflows/
  05-error-handler.json     ← Import FIRST (referenced by others)
  01-ticket-intake.json
  02-ai-classification.json
  03-review-and-routing.json
  04-retry-architecture.json
```

3. In each workflow, update the PostgreSQL credential to point to your `Support Tickets DB`
4. Activate all workflows (toggle to Active)

---

## 🗄️ Database Setup

```bash
# Connect
psql -h localhost -U n8n -d support_tickets

# Verify tables
\dt

# Check the summary view
SELECT * FROM v_ticket_summary LIMIT 5;
```

### Useful queries

```sql
-- All tickets by status
SELECT status, COUNT(*) FROM tickets GROUP BY status;

-- Tickets pending human review
SELECT ticket_id, ai_category, ai_confidence, queued_at
FROM human_review_queue
WHERE reviewed_at IS NULL
ORDER BY queued_at ASC;

-- Failed jobs
SELECT ticket_id, error_type, retry_count, failed_at
FROM failed_jobs
WHERE resolved = false;

-- Audit trail for a ticket
SELECT event_type, event_data, created_at
FROM ticket_audit_logs
WHERE ticket_id = 'TKT-20240611-1234'
ORDER BY created_at;
```

---

## 🧪 Testing the System

### Send a test ticket

```bash
curl -X POST http://localhost:5678/webhook/ticket-intake \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Jane Smith",
    "email": "jane@example.com",
    "subject": "Charged twice for my subscription",
    "message": "My credit card was billed $29.99 twice this month for my Pro subscription. Please refund the duplicate charge immediately."
  }'
```

**Expected response:**
```json
{
  "success": true,
  "ticket_id": "TKT-20240611-4821",
  "message": "Ticket received and queued for processing",
  "status": "RECEIVED"
}
```

### Test human review branch (low confidence scenario)

```bash
curl -X POST http://localhost:5678/webhook/ticket-intake \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Bob Chen",
    "email": "bob@example.com",
    "subject": "Problem",
    "message": "Things are not working as expected."
  }'
```

The vague message will likely produce confidence < 80 and route to human review.

### Test validation error

```bash
curl -X POST http://localhost:5678/webhook/ticket-intake \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test User"
  }'
```

**Expected:** 400 with `"error": "Validation failed. Missing fields: email, subject, message"`

---

## 🛡️ Error Handling Design

### Error Classification

```
API Timeout       → Retryable → WF04 (10s → 30s → 60s)
Rate Limit (429)  → Retryable → WF04 (10s → 30s → 60s)
AI API Error      → Retryable → WF04 (10s → 30s → 60s)
DB Error          → Terminal  → logged to failed_jobs
Invalid AI JSON   → Terminal  → logged to failed_jobs
Validation Error  → Terminal  → 400 response
```

### Dead Letter Queue

Permanently failed tickets are stored in `failed_jobs`. Operations team can:
1. Query `SELECT * FROM failed_jobs WHERE resolved = false`
2. Fix the root cause (API key, connectivity, etc.)
3. Re-submit via webhook manually
4. Mark resolved: `UPDATE failed_jobs SET resolved=true WHERE id=...`

---

## 💼 Business Value

This system demonstrates:

| Business Problem | Solution |
|-----------------|---------|
| Manual ticket sorting is slow | AI classifies in <2 seconds |
| Wrong department routing wastes time | Category-based Switch routing |
| AI black-box decisions | Human review for uncertain cases |
| Lost tickets on failures | Retry + Dead Letter Queue |
| No audit trail for compliance | Immutable event log |
| Siloed ticket data | Unified PostgreSQL schema |

**Time savings estimate:** 15–30 minutes per ticket for manual triage → <5 seconds automated

---

## 📚 Lessons Learned

1. **Strict JSON prompting** — Groq's `response_format: json_object` is essential; without it, LLMs embed JSON in markdown code blocks that break parsers.

2. **Confidence thresholds need tuning** — Starting at 80% catches most ambiguous cases. In production, analyze first 1,000 tickets to calibrate.

3. **Async workflow chaining** — Using internal webhooks rather than Execute Workflow nodes gives better error isolation and easier debugging.

4. **Error context preservation** — The error trigger node captures execution context, but extracting ticket_id requires traversing the runData tree carefully.

5. **Idempotency matters** — `ON CONFLICT (ticket_id) DO NOTHING` prevents duplicate inserts on webhook retry storms.

---

## 📁 Project Structure

```
ai-support-triage/
├── workflows/
│   ├── 01-ticket-intake.json
│   ├── 02-ai-classification.json
│   ├── 03-review-and-routing.json
│   ├── 04-retry-architecture.json
│   └── 05-error-handler.json
├── db/
│   ├── schema.sql
│   └── init-multiple-dbs.sh
├── docker/
│   └── docker-compose.yml
├── docs/
│   └── architecture.md
├── .env.example
└── README.md
```

---

## 📸 Screenshots to Capture

For your portfolio, capture these views in n8n:

- [ ] WF01 full canvas — intake flow
- [ ] WF02 — Groq API node configuration
- [ ] WF03 — IF node (confidence branch) + Switch node (category routing)
- [ ] WF04 — Retry chain with Wait nodes
- [ ] WF05 — Error Trigger + classification code
- [ ] PostgreSQL: `v_ticket_summary` with real data
- [ ] Execution history showing successful + failed runs
- [ ] `human_review_queue` table with pending reviews

---

## 📄 License

MIT — use freely for portfolios and learning.

---

*Built with n8n, Groq, PostgreSQL — demonstrating production-grade automation engineering.*
