# System Diagrams

All diagrams use Mermaid syntax. Render at https://mermaid.live or in any Markdown viewer.

---

## 1. Main System Flow

```mermaid
flowchart TD
    A([Customer / API Client]) -->|POST /webhook/ticket-intake| B

    subgraph WF01["WF01 · Ticket Intake"]
        B[Webhook: Receive Ticket]
        B --> C{Validate Fields}
        C -->|Invalid| D[Respond 400 Error]
        C -->|Valid| E[Generate Ticket ID\nTKT-YYYYMMDD-XXXX]
        E --> F[(PostgreSQL\nINSERT tickets\nstatus=RECEIVED)]
        F --> G[Audit: TICKET_RECEIVED]
        G --> H[Respond 202 Accepted]
        G --> I[HTTP: Trigger WF02]
    end

    subgraph WF02["WF02 · AI Classification"]
        I --> J[Build Groq Prompt]
        J --> K[Groq API\nLLaMA 3.3 70B\njson_object mode]
        K --> L{Parse & Validate\nJSON Response}
        L -->|Invalid| ERR[Throw → WF05]
        L -->|Valid| M[(PostgreSQL\nINSERT classifications\nstatus=CLASSIFIED)]
        M --> N[Audit: TICKET_CLASSIFIED]
        N --> O[HTTP: Trigger WF03]
    end

    subgraph WF03["WF03 · Review & Routing"]
        O --> P{confidence < 80?}

        P -->|YES| Q[(PostgreSQL\nhuman_review_queue\nstatus=NEEDS_REVIEW)]
        Q --> R[Audit: REVIEW_TRIGGERED]
        R --> S([🧑 Agent Reviews\nManually])

        P -->|NO| T[Switch: Category]
        T -->|Billing| U1[(billing queue)]
        T -->|Technical Support| U2[(support queue)]
        T -->|Security| U3[(security queue)]
        T -->|Sales| U4[(sales queue)]
        T -->|Account Management| U5[(account queue)]
        U1 & U2 & U3 & U4 & U5 --> V[status=ROUTED\nrouted_at=NOW]
        V --> W[Audit: TICKET_ROUTED]
    end

    style WF01 fill:#1a1a2e,stroke:#4ecca3,color:#fff
    style WF02 fill:#16213e,stroke:#4ecca3,color:#fff
    style WF03 fill:#0f3460,stroke:#4ecca3,color:#fff
    style D fill:#c0392b,color:#fff
    style ERR fill:#c0392b,color:#fff
    style S fill:#f39c12,color:#000
```

---

## 2. Error & Retry Flow

```mermaid
flowchart TD
    A([Any Workflow Failure]) --> B

    subgraph WF05["WF05 · Error Handler"]
        B[Error Trigger Node]
        B --> C[Code: Classify Error\nAPI_TIMEOUT\nRATE_LIMIT\nAI_API_ERROR\nDB_ERROR\nINVALID_JSON]
        C --> D[(PostgreSQL\nfailed_jobs\naudit_logs)]
        D --> E{Retryable\nerror type?}
        E -->|NO: DB_ERROR\nVALIDATION_ERROR| F[Terminal\nLog Only]
        E -->|YES: TIMEOUT\nRATE_LIMIT\nAI_ERROR| G[HTTP: Trigger WF04]
    end

    subgraph WF04["WF04 · Retry Architecture"]
        G --> H{retry_count >= 3?}
        H -->|YES| I[(Dead Letter Queue\nfailed_jobs\nstatus=FAILED)]

        H -->|NO| J{Which attempt?}
        J -->|retry=0| K1[Wait 10s]
        J -->|retry=1| K2[Wait 30s]
        J -->|retry=2| K3[Wait 60s]

        K1 & K2 & K3 --> L[Increment retry_count]
        L --> M[(PostgreSQL\nAudit: RETRY_ATTEMPTED)]
        M --> N[HTTP: Re-submit\nto WF02]
    end

    N -->|re-enter pipeline| O([WF02 Classification])

    style WF05 fill:#2d1b33,stroke:#e74c3c,color:#fff
    style WF04 fill:#1b2d33,stroke:#e74c3c,color:#fff
    style I fill:#c0392b,color:#fff
    style F fill:#7f8c8d,color:#fff
```

---

## 3. Human Review Flow

```mermaid
flowchart TD
    A([AI Classification\nconfidence < 80]) --> B

    subgraph QUEUE["Human Review Queue"]
        B[(INSERT human_review_queue\nai_category, ai_priority\nai_confidence, ai_reasoning)]
        B --> C[UPDATE tickets\nstatus = NEEDS_REVIEW]
        C --> D[Audit: REVIEW_TRIGGERED]
    end

    D --> E([🧑 Support Manager\nOpens Review Dashboard])

    E --> F[Reads:\n• Original subject & message\n• AI suggested category\n• AI confidence score\n• AI reasoning]

    F --> G{Decision}

    G -->|APPROVED| H[Use AI suggestion\nas-is]
    G -->|OVERRIDDEN| I[Pick different\ncategory / priority]
    G -->|ESCALATED| J[Route to\nSenior Agent]

    H & I --> K[UPDATE human_review_queue\nreview_decision\nreviewed_by\nreviewed_at]
    K --> L[Re-trigger WF03\nrouting phase]
    L --> M[(UPDATE tickets\nstatus = ROUTED)]

    J --> N([Senior Agent\nInvestigates])

    style QUEUE fill:#0f3460,stroke:#4ecca3,color:#fff
    style E fill:#f39c12,color:#000
    style N fill:#e74c3c,color:#fff
    style H fill:#27ae60,color:#fff
    style I fill:#e67e22,color:#fff
    style J fill:#e74c3c,color:#fff
```

---

## 4. Database State Machine

```mermaid
stateDiagram-v2
    [*] --> RECEIVED: Ticket intake\nvalidated & stored

    RECEIVED --> CLASSIFIED: Groq AI\nclassifies ticket

    CLASSIFIED --> NEEDS_REVIEW: confidence < 80\nHuman review triggered

    CLASSIFIED --> ROUTED: confidence >= 80\nAuto-routed to queue

    NEEDS_REVIEW --> ROUTED: Agent approves\nor overrides

    ROUTED --> COMPLETED: Ticket resolved\nby agent

    CLASSIFIED --> FAILED: All retries\nexhausted → DLQ

    note right of NEEDS_REVIEW: Ticket paused.\nAwaiting human decision.

    note right of FAILED: Stored in\nfailed_jobs table.\nManual recovery required.
```

---

## 5. Workflow Chain Overview

```mermaid
sequenceDiagram
    participant C as Client
    participant W1 as WF01 Intake
    participant DB as PostgreSQL
    participant W2 as WF02 AI
    participant G as Groq API
    participant W3 as WF03 Router
    participant W5 as WF05 Errors
    participant W4 as WF04 Retry

    C->>W1: POST /ticket-intake
    W1->>W1: Validate + Generate ID
    W1->>DB: INSERT tickets (RECEIVED)
    W1-->>C: 202 Accepted + ticket_id
    W1->>W2: POST /ai-classify (async)

    W2->>G: POST /chat/completions
    G-->>W2: JSON classification
    W2->>W2: Validate response
    W2->>DB: INSERT classification (CLASSIFIED)
    W2->>W3: POST /ticket-router

    alt confidence >= 80
        W3->>DB: UPDATE → ROUTED
    else confidence < 80
        W3->>DB: INSERT human_review_queue (NEEDS_REVIEW)
    end

    opt Groq API fails
        W2->>W5: Error Trigger
        W5->>DB: INSERT failed_jobs
        W5->>W4: POST /retry-classify
        W4->>W4: Wait (10s/30s/60s)
        W4->>W2: Retry /ai-classify
    end
```
