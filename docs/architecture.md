# AI Support Ticket Triage & Routing System
## Architecture Documentation

---

## 1. System Overview

This system automates the end-to-end lifecycle of customer support tickets — from multi-channel ingestion through AI-powered classification, intelligent routing, human review governance, and complete audit tracing.

The architecture is built around five cooperative n8n workflows, each with a single responsibility, connected via internal webhooks to form a resilient processing pipeline.

### Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Never lose a ticket** | Every ticket is persisted to PostgreSQL before any processing begins |
| **Graceful degradation** | Retry architecture with exponential backoff; Dead Letter Queue as last resort |
| **Human-in-the-loop** | Low-confidence AI classifications are halted and queued for human review |
| **Full observability** | Immutable audit log captures every state transition |
| **Separation of concerns** | Each workflow has one job; cross-workflow calls via internal webhooks |

---

## 2. Workflow Architecture

### Workflow Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ENTRY POINT                                  │
│  POST /webhook/ticket-intake                                        │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  WORKFLOW 01: Ticket Intake                                         │
│  Validate → Generate ID → INSERT tickets → Audit → Trigger WF02    │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ POST /webhook/ai-classify
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  WORKFLOW 02: AI Classification                                     │
│  Build Prompt → Groq API → Parse/Validate → Store → Trigger WF03   │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ POST /webhook/ticket-router
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  WORKFLOW 03: Review & Routing                                      │
│        │                                                            │
│   confidence < 80?                                                  │
│    ├── YES → human_review_queue (status: NEEDS_REVIEW)              │
│    └── NO  → Switch(category) → dept queue (status: ROUTED)        │
└─────────────────────────────────────────────────────────────────────┘

         ┌─────────────────── On any WF failure ──────────────────┐
         ▼                                                         │
┌─────────────────┐     ┌──────────────────────────────────────┐  │
│  WF05: Error    │────▶│  WF04: Retry Architecture            │  │
│  Handler        │     │  10s → 30s → 60s → Dead Letter Queue │  │
└─────────────────┘     └──────────────────────────────────────┘  │
         │                                                         │
         └─────────────────────────────────────────────────────────┘
```

---

## 3. Workflow Details

### Workflow 01 — Ticket Intake

**Trigger:** `POST /webhook/ticket-intake`

| Step | Node | Action |
|------|------|--------|
| 1 | Webhook | Receive ticket payload |
| 2 | Code: Validate Fields | Check required fields, email format |
| 3 | Code: Generate Ticket ID | Create `TKT-YYYYMMDD-XXXX` |
| 4 | PostgreSQL: Insert Ticket | Persist with status=`RECEIVED` |
| 5 | PostgreSQL: Audit | Write `TICKET_RECEIVED` audit event |
| 6 | HTTP: Trigger Classification | Fire-and-forget to WF02 |
| 7 | Respond: 202 Accepted | Return ticket_id to caller |

**Error path:** Validation failures return 400 immediately. DB/downstream failures route to WF05.

---

### Workflow 02 — AI Classification

**Trigger:** `POST /webhook/ai-classify`

**Groq Model:** `llama-3.3-70b-versatile`  
**Temperature:** `0.1` (deterministic output)  
**Response format:** `json_object` (forced JSON mode)

**System prompt instructs the model to return strictly:**
```json
{
  "category": "Billing | Technical Support | Sales | Security | Account Management",
  "priority": "Low | Medium | High | Critical",
  "confidence": 0-100,
  "reasoning": "One sentence explanation"
}
```

**Validation in Code node:**
- Category must be from allowed list
- Priority must be from allowed list
- Confidence must be integer 0–100
- Invalid responses throw and trigger WF05 → WF04

---

### Workflow 03 — Review & Routing

**Trigger:** `POST /webhook/ticket-router`

#### Human Review Branch (confidence < 80)

```
IF confidence < 80
  → INSERT human_review_queue
  → UPDATE tickets SET status='NEEDS_REVIEW'
  → Audit: REVIEW_TRIGGERED
  → [STOP — awaits manual agent action]
```

A support manager reviews the queue, overrides if needed, and manually re-triggers routing.

#### Auto-Routing Branch (confidence ≥ 80)

```
Switch(category)
  "Billing"            → assigned_queue='billing'
  "Technical Support"  → assigned_queue='support'
  "Security"           → assigned_queue='security'
  "Sales"              → assigned_queue='sales'
  "Account Management" → assigned_queue='account'

UPDATE tickets SET status='ROUTED', routed_at=NOW()
Audit: TICKET_ROUTED
```

---

### Workflow 04 — Retry Architecture

**Trigger:** Called by WF05 for retryable errors

```
Entry
 └─ Check retry_count (throw if ≥ 3 → Dead Letter Queue)
    ├─ retry_count == 0 → Wait 10s → increment → re-submit to WF02
    ├─ retry_count == 1 → Wait 30s → increment → re-submit to WF02
    └─ retry_count == 2 → Wait 60s → increment → re-submit to WF02

Dead Letter Queue (retry_count ≥ 3):
  → INSERT failed_jobs
  → UPDATE tickets SET status='FAILED'
  → Audit: TICKET_DEAD_LETTERED
```

---

### Workflow 05 — Error Handler

**Trigger:** `Error Trigger` node (set as `errorWorkflow` in WF01–03)

**Error classification logic:**

| Pattern | Error Type |
|---------|-----------|
| `timeout / ETIMEDOUT` | `API_TIMEOUT` |
| `429 / rate limit` | `RATE_LIMIT_ERROR` |
| `postgres / ECONNREFUSED` | `DATABASE_ERROR` |
| `groq / llm / classification` | `AI_API_ERROR` |
| `json / parse / invalid` | `INVALID_AI_RESPONSE` |

**Retryable errors:** `API_TIMEOUT`, `RATE_LIMIT_ERROR`, `AI_API_ERROR` → trigger WF04  
**Terminal errors:** `DATABASE_ERROR`, `INVALID_AI_RESPONSE`, `VALIDATION_ERROR` → log only

---

## 4. Database Schema

### Entity Relationship

```
tickets (1) ─────────────── (1) ticket_classifications
    │                                
    │ (1)────────────────── (0..1) human_review_queue
    │
    │ (1)────────────────── (0..N) ticket_audit_logs
    │
    └ (1)────────────────── (0..1) failed_jobs
```

### Status Flow

```
RECEIVED → CLASSIFIED → ROUTED → COMPLETED
                      ↘
                        NEEDS_REVIEW → [manual] → ROUTED
                      ↘
                        FAILED (Dead Letter Queue)
```

---

## 5. Failure Recovery Strategy

### Failure Matrix

| Failure Scenario | Detection | Recovery |
|-----------------|-----------|----------|
| Groq API timeout | HTTP 408 / node timeout | WF05 → WF04 retry |
| Groq rate limit (429) | HTTP 429 | WF05 → WF04 retry with backoff |
| Invalid JSON from Groq | Parse error in Code node | WF05 → WF04 retry |
| PostgreSQL down | Connection error | WF05 logs to file fallback; alerts |
| Max retries exceeded | retry_count ≥ 3 | Dead Letter Queue |
| Validation failure | Code node throw | 400 response; no retry |

### Dead Letter Queue Resolution

Failed jobs in `failed_jobs` table are resolved by:
1. Ops team reviews `failed_jobs` where `resolved = false`
2. Root cause identified (API key expired, DB config, etc.)
3. Ticket re-submitted manually via webhook with corrected config
4. `failed_jobs.resolved = true`, `resolved_at = NOW()`, `resolved_by = 'ops_name'`

---

## 6. Human Review Process

```
                    ┌─────────────────────┐
                    │  AI Confidence < 80 │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  human_review_queue  │
                    │  status: NEEDS_REVIEW│
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Agent Reviews:     │
                    │  - AI suggestion    │
                    │  - Original ticket  │
                    │  - AI reasoning     │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼─────────────────┐
              │                │                 │
     ┌────────▼──────┐ ┌───────▼──────┐ ┌───────▼──────┐
     │   APPROVED    │ │  OVERRIDDEN  │ │  ESCALATED   │
     │ Use AI result │ │ Agent picks  │ │ Senior review │
     └────────┬──────┘ └───────┬──────┘ └───────┬──────┘
              └────────────────┴─────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Re-trigger WF03    │
                    │  (routing phase)    │
                    └─────────────────────┘
```

---

## 7. Audit Logging Design

Every state transition writes an immutable row to `ticket_audit_logs`.

### Event Types

| Event | Workflow | Trigger |
|-------|----------|---------|
| `TICKET_RECEIVED` | WF01 | Ticket inserted |
| `TICKET_CLASSIFIED` | WF02 | AI classification stored |
| `REVIEW_TRIGGERED` | WF03 | Confidence < threshold |
| `TICKET_ROUTED` | WF03 | Department queue assigned |
| `RETRY_ATTEMPTED` | WF04 | Each retry attempt |
| `TICKET_DEAD_LETTERED` | WF04 | Max retries exceeded |
| `WORKFLOW_FAILED` | WF05 | Any unhandled error |
| `TICKET_COMPLETED` | Manual/future | Ticket resolved |

### Query: Full ticket history
```sql
SELECT event_type, event_data, workflow_name, created_at
FROM ticket_audit_logs
WHERE ticket_id = 'TKT-20240611-1234'
ORDER BY created_at ASC;
```

---

## 8. Scalability Considerations

### Current (Single-node n8n)
- Handles ~100–500 tickets/hour comfortably
- PostgreSQL connection pooling handles concurrent workflows
- Redis available for queue-based patterns

### Path to Scale
1. **n8n queue mode** — Enable `EXECUTIONS_PROCESS=queue` + Redis for horizontal scaling
2. **Read replicas** — Separate read/write PostgreSQL for reporting vs. ops
3. **Webhook batching** — Implement batch intake endpoint for high-volume sources
4. **Priority queues** — Critical tickets bypass standard queue
5. **Groq rate limit management** — Implement token bucket counter in Redis

---

## 9. Security Considerations

| Area | Implementation |
|------|---------------|
| **API Keys** | Stored in n8n credentials vault (encrypted at rest) |
| **Webhook auth** | Add HMAC signature verification header |
| **DB credentials** | Environment variables only, never in workflow JSON |
| **PII handling** | Email/name stored; no payment data in message field |
| **n8n access** | Basic auth enabled; HTTPS in production |
| **Audit immutability** | No UPDATE/DELETE on audit_logs table |

### Production Hardening Checklist
- [ ] Change all default passwords in `.env`
- [ ] Generate strong `N8N_ENCRYPTION_KEY`
- [ ] Enable HTTPS (reverse proxy: nginx/traefik)
- [ ] Restrict PostgreSQL to internal network
- [ ] Add webhook signature verification
- [ ] Set up log rotation and backup schedule
- [ ] Enable n8n 2FA

---

## 10. Future Improvements

| Feature | Priority | Description |
|---------|----------|-------------|
| Email trigger | High | Ingest tickets via IMAP/Gmail directly |
| Slack notifications | High | Alert agents on new Critical tickets |
| Auto-response | Medium | Send acknowledgement email on receipt |
| SLA tracking | Medium | Track time-to-route per priority |
| Dashboard | Medium | Real-time ticket status via n8n's data tables |
| Multi-model fallback | Low | Failover to secondary Groq model |
| Sentiment analysis | Low | Enrich classification with customer sentiment |
| Ticket deduplication | Low | Detect same customer filing duplicate tickets |
