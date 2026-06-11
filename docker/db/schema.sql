-- ============================================================
-- AI Support Ticket Triage & Routing System
-- PostgreSQL Schema
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLE: tickets
-- Core ticket store. Every ticket begins here.
-- ============================================================
CREATE TABLE tickets (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id           VARCHAR(20) UNIQUE NOT NULL,       -- Human-readable: TKT-20240611-0001
    name                VARCHAR(255) NOT NULL,
    email               VARCHAR(255) NOT NULL,
    subject             TEXT NOT NULL,
    message             TEXT NOT NULL,
    source_channel      VARCHAR(50) DEFAULT 'webhook',      -- webhook | email | manual
    status              VARCHAR(30) NOT NULL DEFAULT 'RECEIVED',
    -- Statuses: RECEIVED | CLASSIFIED | NEEDS_REVIEW | ROUTED | COMPLETED | FAILED
    assigned_queue      VARCHAR(50),                        -- billing | support | security | sales | account
    retry_count         INT DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    routed_at           TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ
);

CREATE INDEX idx_tickets_ticket_id    ON tickets (ticket_id);
CREATE INDEX idx_tickets_status       ON tickets (status);
CREATE INDEX idx_tickets_email        ON tickets (email);
CREATE INDEX idx_tickets_created_at   ON tickets (created_at DESC);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tickets_updated_at
    BEFORE UPDATE ON tickets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ============================================================
-- TABLE: ticket_classifications
-- AI classification output per ticket.
-- ============================================================
CREATE TABLE ticket_classifications (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id       VARCHAR(20) NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    category        VARCHAR(50) NOT NULL,   -- Billing | Technical Support | Sales | Security | Account Management
    priority        VARCHAR(20) NOT NULL,   -- Low | Medium | High | Critical
    confidence      INT NOT NULL,           -- 0–100
    reasoning       TEXT,
    model_used      VARCHAR(100),
    raw_response    JSONB,
    classified_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_classifications_ticket_id  ON ticket_classifications (ticket_id);
CREATE INDEX idx_classifications_category   ON ticket_classifications (category);
CREATE INDEX idx_classifications_priority   ON ticket_classifications (priority);
CREATE INDEX idx_classifications_confidence ON ticket_classifications (confidence);


-- ============================================================
-- TABLE: human_review_queue
-- Tickets with AI confidence < 80 land here for manual review.
-- ============================================================
CREATE TABLE human_review_queue (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id           VARCHAR(20) NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
    ai_category         VARCHAR(50),
    ai_priority         VARCHAR(20),
    ai_confidence       INT,
    ai_reasoning        TEXT,
    reviewed_by         VARCHAR(255),
    reviewed_at         TIMESTAMPTZ,
    review_decision     VARCHAR(30),         -- APPROVED | OVERRIDDEN | ESCALATED
    override_category   VARCHAR(50),
    override_priority   VARCHAR(20),
    review_notes        TEXT,
    queued_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_review_queue_ticket_id   ON human_review_queue (ticket_id);
CREATE INDEX idx_review_queue_reviewed_at ON human_review_queue (reviewed_at);
CREATE INDEX idx_review_queue_decision    ON human_review_queue (review_decision);


-- ============================================================
-- TABLE: ticket_audit_logs
-- Immutable event log. One row per state change / action.
-- ============================================================
CREATE TABLE ticket_audit_logs (
    id              BIGSERIAL PRIMARY KEY,
    ticket_id       VARCHAR(20),             -- nullable: some system events have no ticket
    event_type      VARCHAR(60) NOT NULL,
    -- e.g. TICKET_RECEIVED | TICKET_CLASSIFIED | REVIEW_TRIGGERED |
    --      TICKET_ROUTED | WORKFLOW_FAILED | RETRY_ATTEMPTED | TICKET_COMPLETED
    event_data      JSONB,
    workflow_name   VARCHAR(100),
    node_name       VARCHAR(100),
    actor           VARCHAR(100) DEFAULT 'system',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_logs_ticket_id   ON ticket_audit_logs (ticket_id);
CREATE INDEX idx_audit_logs_event_type  ON ticket_audit_logs (event_type);
CREATE INDEX idx_audit_logs_created_at  ON ticket_audit_logs (created_at DESC);


-- ============================================================
-- TABLE: failed_jobs (Dead Letter Queue)
-- Tickets that exhausted all retries live here.
-- ============================================================
CREATE TABLE failed_jobs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id       VARCHAR(20),
    payload         JSONB NOT NULL,          -- original ticket payload
    error_type      VARCHAR(100) NOT NULL,
    error_message   TEXT,
    workflow_name   VARCHAR(100),
    node_name       VARCHAR(100),
    retry_count     INT DEFAULT 0,
    final_failure_reason TEXT,
    failed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved        BOOLEAN DEFAULT FALSE,
    resolved_at     TIMESTAMPTZ,
    resolved_by     VARCHAR(255)
);

CREATE INDEX idx_failed_jobs_ticket_id  ON failed_jobs (ticket_id);
CREATE INDEX idx_failed_jobs_resolved   ON failed_jobs (resolved);
CREATE INDEX idx_failed_jobs_failed_at  ON failed_jobs (failed_at DESC);


-- ============================================================
-- Seed: helpful view for ops dashboard
-- ============================================================
CREATE OR REPLACE VIEW v_ticket_summary AS
SELECT
    t.ticket_id,
    t.name,
    t.email,
    t.subject,
    t.status,
    t.assigned_queue,
    t.retry_count,
    c.category,
    c.priority,
    c.confidence,
    hrq.review_decision,
    t.created_at,
    t.routed_at
FROM tickets t
LEFT JOIN ticket_classifications c ON c.ticket_id = t.ticket_id
LEFT JOIN human_review_queue hrq   ON hrq.ticket_id = t.ticket_id
ORDER BY t.created_at DESC;
