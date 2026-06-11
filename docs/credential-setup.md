# n8n Credential & Integration Setup Guide

## Step 1: PostgreSQL Credential

1. In n8n → **Settings** → **Credentials** → **+ Add Credential**
2. Search for: `PostgreSQL`
3. Fill in:

| Field | Value |
|-------|-------|
| Credential Name | `Support Tickets DB` |
| Host | `postgres` (Docker) or `localhost` (bare metal) |
| Port | `5432` |
| Database | `support_tickets` |
| User | `n8n` (or your POSTGRES_USER) |
| Password | (your POSTGRES_PASSWORD from .env) |
| SSL | Off (local dev) |

4. Click **Test** → should show green ✓
5. Click **Save**

---

## Step 2: Groq API Credential

1. **Settings** → **Credentials** → **+ Add Credential**
2. Search for: `HTTP Header Auth`
3. Fill in:

| Field | Value |
|-------|-------|
| Credential Name | `Groq API Key` |
| Name | `Authorization` |
| Value | `Bearer gsk_your_actual_key_here` |

4. Click **Save**

> **Tip:** Get your Groq API key at https://console.groq.com/keys — free tier is generous for development.

---

## Step 3: Groq HTTP Node Configuration

In **WF02**, the `HTTP: Groq Classification API` node:

- **Method:** POST
- **URL:** `https://api.groq.com/openai/v1/chat/completions`
- **Authentication:** Generic Credential Type → HTTP Header Auth → select `Groq API Key`
- **Content Type:** JSON
- **Body:** (see workflow JSON for full body)
- **Timeout:** 30000ms

### Model Options

| Model | Speed | Quality | Use Case |
|-------|-------|---------|----------|
| `llama-3.3-70b-versatile` | Fast | High | **Recommended** |
| `mixtral-8x7b-32768` | Faster | Good | High-volume |
| `llama-3.1-8b-instant` | Fastest | Lower | Testing only |

---

## Step 4: Environment Variables in n8n

n8n makes env vars available via `$env.VARIABLE_NAME`.

In each HTTP node that calls internal webhooks, use:
```
={{ $env.WEBHOOK_URL }}/webhook/ai-classify
```

This allows easy environment switching (local → staging → production).

---

## Step 5: Set Error Workflow

For WF01, WF02, WF03 — in each workflow's **Settings** tab:

- **Error Workflow:** Select `05 - Error Handler`

This ensures any unhandled exception is caught and routed to the central error handler.

---

## Step 6: Workflow Activation Order

Activate in this order to avoid "webhook not found" errors:

1. ✅ `05 - Error Handler` — activate first
2. ✅ `04 - Retry Architecture`
3. ✅ `03 - Review & Routing`
4. ✅ `02 - AI Classification`
5. ✅ `01 - Ticket Intake` — activate last

---

## Step 7: Verify Webhook URLs

After activation, each webhook node shows its URL. Confirm:

| Workflow | Webhook Path | Should be active |
|----------|-------------|-----------------|
| WF01 | `/webhook/ticket-intake` | ✅ |
| WF02 | `/webhook/ai-classify` | ✅ |
| WF03 | `/webhook/ticket-router` | ✅ |
| WF04 | `/webhook/retry-classify` | ✅ |

---

## Troubleshooting

### "Credentials not found"
→ Re-import workflows after creating credentials. Credentials are matched by name.

### Groq returns 401
→ Check API key starts with `Bearer ` (note the space)

### PostgreSQL connection refused
→ Ensure containers are on same Docker network (`triage_net`)  
→ In n8n container, hostname should be `postgres`, not `localhost`

### Workflow not receiving webhooks
→ Ensure workflow is **Active** (toggle in top-right)  
→ Check `WEBHOOK_URL` env var matches your n8n hostname
