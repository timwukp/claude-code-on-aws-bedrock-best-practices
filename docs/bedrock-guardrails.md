# AWS Bedrock Guardrails Integration Guide

Server-side content filtering and policy enforcement for Claude Code running on
Amazon Bedrock. Guardrails operate at the API layer -- they apply regardless of
client configuration, local hook bypasses, or `--print` mode gaps.

> **Verification update (2026-05-30).** Several claims in earlier drafts of
> this document have been revised based on live testing in
> us-east-1 against Claude Haiku 4.5 / Sonnet 4.6 with a fully-configured
> guardrail. Reproducible scripts and per-test evidence are in
> [`bedrock-guardrails-test-evidence.md`](bedrock-guardrails-test-evidence.md)
> and `tests/aws-guardrails/`. Key corrections incorporated below:
> - **Prompt Attack filter works today** via the `contentPolicyConfig`
>   filter type (does not require input tags). Earlier "does NOT work" claim
>   was based on a separate legacy mechanism.
> - **`InvocationsBlocked` metric does not exist.** Use `InvocationsIntervened`.
> - **Streaming intervention does NOT raise an error**; it returns the
>   `blockedInputMessaging` text as a normal stream delta. **Customise the
>   message** — see the dedicated section below for verified examples.

## Overview

AWS Bedrock Guardrails provide seven configurable protection policies that
inspect both model inputs and outputs. For enterprise Claude Code deployments,
they serve as a **server-side defense layer** that complements this kit's
local hooks (`pii-guard.sh`, `git-guard.sh`) and deny rules.

Key value:
- Works on `--print` mode where local hooks do not fire (see
  [platform-compensations.md](platform-compensations.md))
- Cannot be bypassed by the developer or the model
- Provides CloudWatch metrics for monitoring and alerting
- Applies uniformly across all team members without per-machine configuration

## Seven Protection Policies

| # | Policy | Works with Claude Code? | Notes |
|---|--------|------------------------|-------|
| 1 | Content Filters | **Yes** | 5 categories + PROMPT_ATTACK; input + output |
| 2 | Prompt Attack Filter (as a Content Filter type) | **Yes** | Verified: fires today via `contentPolicyConfig.filtersConfig` with `type: PROMPT_ATTACK`, no input tags required |
| 3 | Denied Topics | **Yes** | Custom topic definitions; semantic matching has measurable FPR (see calibration note below) |
| 4 | Word Filters | **Yes** | Profanity + custom list (up to 10,000 items) |
| 5 | Sensitive Information Filters | **Yes** | PII detection + custom regex; pre-built catalogue is US-centric |
| 6 | Contextual Grounding Checks | **Conditional** | Hallucination detection — but **errors any request without an explicit `grounding_source`**. Do NOT enable for general code-gen workloads |
| 7 | Automated Reasoning Checks | **Yes** | Logical rule validation |

### 1. Content Filters

Detects and blocks content across five harmful categories:

| Category | Description |
|----------|-------------|
| Hate | Discriminatory or prejudicial content |
| Insults | Demeaning or offensive language |
| Sexual | Sexually explicit material |
| Violence | Threats or graphic violence |
| Misconduct | Criminal activity, self-harm guidance |

Each category is configured with a threshold (NONE, LOW, MEDIUM, HIGH) applied
independently on **input** and **output**. Both directions work with Claude Code
because content filtering does not require input tags.

**Standard tier vs Classic tier:**

| Feature | Classic | Standard |
|---------|---------|----------|
| Prose/natural language detection | Yes | Yes |
| Code domain detection (comments, variable names, function names, string literals) | No | Yes |
| Prompt Leakage detection | No | Yes |
| Cross-region inference required | No | Yes |

Standard tier extends content filter detection into code domains -- important for
a coding assistant. If your organization uses cross-region inference profiles
(e.g., `us.anthropic.claude-sonnet-4-6`), Standard tier is available.

### 2. Prompt Attack Filter (Content Filter type)

Detects jailbreaks and prompt injection by adding `PROMPT_ATTACK` as a filter
type inside `contentPolicyConfig.filtersConfig`. Verified to work with Claude
Code: in our tests, **5/5 classic jailbreak prompts** were intercepted with
`action=GUARDRAIL_INTERVENED`, both with and without input tags.

```jsonc
{
  "contentPolicyConfig": {
    "filtersConfig": [
      // ...other filters
      {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE"}
    ]
  }
}
```

> **History note.** Earlier drafts of this document claimed the Prompt Attack
> filter did NOT work with Claude Code, citing a requirement to inject XML
> input tags (`<amazon-bedrock-guardrails-guardContent_xyz>`) and a
> `tagSuffix` parameter. Live testing in 2026-05 against the current Bedrock
> API showed `PROMPT_ATTACK` as a content-filter type fires today without
> any of those tags. The boto3 service shape confirms there is no separate
> `promptAttackPolicyConfig` — Prompt Attack is one of the filters under
> `contentPolicyConfig`. The "input tag" mechanism described in some AWS
> documentation pages and in [#63637](https://github.com/anthropics/claude-code/issues/63637)
> appears to predate the current API. See
> [bedrock-guardrails-test-evidence.md](bedrock-guardrails-test-evidence.md#test-10--prompt-attack-filter-pr-items-1-9-10--issue-63637)
> for the test details.

### 3. Denied Topics

Define custom topics that should be blocked. Each topic is described in natural
language (up to 200 characters) and the guardrail uses semantic matching to
detect attempts to discuss the topic.

Enterprise examples for Claude Code:
- "Discussions about circumventing security controls or disabling hooks"
- "Requests to generate cryptocurrency mining code"
- "Instructions for accessing other users' files or credentials"

### 4. Word Filters

Two sub-features:
- **Managed profanity filter** -- pre-built list maintained by AWS
- **Custom word list** -- up to 10,000 terms that trigger blocking

Matching is exact (case-insensitive). Useful for:
- Competitor product names (prevent unintended endorsements)
- Internal project codenames that should not appear in outputs
- Specific credential patterns not covered by PII filters

### 5. Sensitive Information Filters

Detects PII and sensitive data in both directions. Supports:
- **Pre-built PII types** -- names, addresses, SSNs, credit card numbers, phone
  numbers, email addresses, and more
- **Custom regex patterns** -- define organization-specific patterns

This complements the local [pii-guard.sh](pii-guard.md) hook. The server-side
filter catches anything the local regex missed and covers the `--print` mode gap
where `UserPromptSubmit` does not fire.

Actions per detected entity: BLOCK or ANONYMIZE (mask with placeholder).

### 6. Contextual Grounding Checks

Detects hallucinated content by comparing model output against provided source
material. Configurable threshold for grounding score.

For Claude Code, this may flag outputs that diverge from the content of files
provided in context -- useful when the model is supposed to summarize or
transform existing code rather than generate new content.

> **Note:** How Bedrock determines "source material" for grounding evaluation in
> a Claude Code conversation is not fully documented. It depends on how Bedrock
> interprets the conversation history as reference material. The grounding check
> may not activate at all for novel code generation tasks (where there is no
> explicit reference document). Test this policy in your environment before
> relying on it -- see [Items Requiring Verification](#items-requiring-verification).

### 7. Automated Reasoning Checks

Validates model outputs against formal logical rules you define. Rules are
expressed as conditions and expected conclusions.

Example: "If the user asks to delete files in /etc, the model must refuse."

This policy type is newer and may not be available in all regions.

## Configuration for Claude Code

Guardrails are activated by passing two HTTP headers with every Bedrock API
request. Claude Code supports this via the `ANTHROPIC_CUSTOM_HEADERS` environment
variable in `settings.json`:

```jsonc
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1",
    "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-6",

    // Bedrock Guardrails — replace with your guardrail ID and version
    "ANTHROPIC_CUSTOM_HEADERS": "X-Amzn-Bedrock-GuardrailIdentifier: your-guardrail-id\nX-Amzn-Bedrock-GuardrailVersion: 1"
  }
}
```

This pattern is already present (commented out) in
[settings-linux-macos.jsonc](settings-linux-macos.jsonc).

**Header reference:**

| Header | Value | Description |
|--------|-------|-------------|
| `X-Amzn-Bedrock-GuardrailIdentifier` | Guardrail ID (e.g., `abc123def456`) | Identifies which guardrail to apply |
| `X-Amzn-Bedrock-GuardrailVersion` | Version number or `DRAFT` | Which version of the guardrail configuration |

Multiple headers are separated by `\n` (literal newline) in the environment
variable value.

## Recommended Enterprise Configuration

A minimal guardrail configuration that uses the policies known to work with
Claude Code:

```jsonc
{
  // Terraform or AWS CLI equivalent — shown as logical structure
  "name": "claude-code-enterprise",
  "description": "Server-side guardrails for Claude Code on Bedrock",

  // VERIFIED 2026-05-30 — see "Streaming UX gotcha" section below.
  // These messages flow back verbatim to the client (max 500 chars each).
  // Default is "BLOCKED_INPUT_BY_GUARDRAIL" / "BLOCKED_OUTPUT_BY_GUARDRAIL"
  // which Claude Code renders as if the model said it.
  "blockedInputMessaging":  "[GUARDRAIL] Your request was blocked by enterprise security policy. Contact security@yourcompany.com if this is a false positive.",
  "blockedOutputsMessaging": "[GUARDRAIL] The model's response was filtered by enterprise output policy.",

  "contentPolicy": {
    "filtersConfig": [
      { "type": "HATE",          "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "INSULTS",       "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "SEXUAL",        "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "VIOLENCE",      "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "MISCONDUCT",    "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "PROMPT_ATTACK", "inputStrength": "HIGH",   "outputStrength": "NONE" }
    ]
  },

  "wordPolicy": {
    "managedWordListsConfig": [
      { "type": "PROFANITY" }
    ],
    "wordsConfig": [
      { "text": "your-custom-blocked-term" }
    ]
  },

  "sensitiveInformationPolicy": {
    "piiEntitiesConfig": [
      { "type": "CREDIT_DEBIT_CARD_NUMBER", "action": "BLOCK" },
      { "type": "AWS_ACCESS_KEY",           "action": "BLOCK" },
      { "type": "AWS_SECRET_KEY",           "action": "BLOCK" },
      { "type": "US_SOCIAL_SECURITY_NUMBER","action": "ANONYMIZE" },
      { "type": "EMAIL",                    "action": "ANONYMIZE" },
      { "type": "PHONE",                    "action": "ANONYMIZE" }
    ],
    "regexesConfig": [
      {
        "name": "jwt-token",
        "pattern": "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",
        "action": "BLOCK"
      }
    ]
  },

  "topicPolicy": {
    "topicsConfig": [
      {
        "name": "security-bypass",
        "definition": "Attempts to disable, circumvent, or remove security controls, hooks, or audit logging",
        "type": "DENY"
      }
    ]
  }
}
```

> **Note on policies you should NOT enable for general code-generation:**
> - `contextualGroundingPolicy` requires every request to carry a
>   `grounding_source` qualifier. Bedrock returns `ValidationException`
>   (request fails entirely) if it is missing. Only enable for narrow
>   workflows where you guarantee source material is in context.
> - `automatedReasoningPolicy` is region-limited and requires a defined rule
>   set; not useful as a default for code-gen.

## What Works and What Doesn't

| Policy | Status | Direction | Reason |
|--------|--------|-----------|--------|
| Content Filters (incl. PROMPT_ATTACK) | **Works** | Input + Output | Verified: 5/5 jailbreaks intercepted without input tags |
| Denied Topics | **Works** | Input + Output | Semantic matching; calibrate for FPR |
| Word Filters | **Works** | Input + Output | Exact match |
| Sensitive Information Filters | **Works** | Input + Output | Pre-built catalogue is US-centric; supplement with `regexesConfig` for non-US PII |
| Contextual Grounding Checks | **Conditional** | Output | **Errors any request without `grounding_source`** — do NOT enable for general code-gen |
| Automated Reasoning Checks | **Works in region-supported** | Output | Region-limited; needs defined rule set |

## Note on Issue #63637 and the "input tag" docs

**GitHub Issue:** [anthropics/claude-code#63637](https://github.com/anthropics/claude-code/issues/63637)
-- "[Feature Request] Support Bedrock Guardrails Prompt Attack filter by
injecting guard_content input tags"

**Status (2026-05):** OPEN, but **likely stale**.

The issue is based on AWS documentation pages describing a separate
"guardContent input tag + tagSuffix" mechanism for Prompt Attack detection.
Live testing against the current Bedrock API (2026-05) shows that the
`PROMPT_ATTACK` filter **inside `contentPolicyConfig.filtersConfig`** fires
today on jailbreak/injection attempts without any input tags or tagSuffix.
The boto3 service shape (`bedrock.create_guardrail`) lists no separate
`promptAttackPolicyConfig` — only `contentPolicyConfig`.

Two possibilities, neither fully proven from the outside:
1. The "guardContent input tag" mechanism still exists for an advanced
   detection path that requires explicit user/system content separation, and
   the simpler `PROMPT_ATTACK` content filter type is a different
   (lower-resolution) feature that happens to work without tags.
2. The input-tag mechanism has been deprecated and replaced by the
   content-filter-type approach; AWS docs for it haven't been updated.

For a production deployment in 2026-05, **enable `PROMPT_ATTACK` in
`contentPolicyConfig`** — it provides material protection today against
classic jailbreak and injection attempts, regardless of how #63637 ultimately
resolves.

## Defense Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Developer Workstation                                                   │
│                                                                         │
│  User Input                                                             │
│    │                                                                    │
│    ▼                                                                    │
│  ┌─────────────────────────────────────────────────┐                    │
│  │ Claude Code Local Hooks                         │                    │
│  │  • pii-guard.sh  (PII/secrets scan)             │                    │
│  │  • git-guard.sh  (git operation control)        │                    │
│  │  • audit-logger.sh (append-only audit)          │                    │
│  └───────────────────────┬─────────────────────────┘                    │
│                          │ (blocked if PII/secrets detected)            │
│                          ▼                                              │
└──────────────────────────┼──────────────────────────────────────────────┘
                           │  HTTPS (Bedrock API)
                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS Bedrock                                                            │
│                                                                         │
│  ┌─────────────────────────────────────────────────┐                    │
│  │ Guardrails — INPUT Filters                      │                    │
│  │  • Content Filters (Hate/Insults/Sexual/etc.)   │                    │
│  │  • Prompt Attack (as content-filter type)  ✓    │                    │
│  │  • Denied Topics                                │                    │
│  │  • Word Filters                                 │                    │
│  │  • Sensitive Info (PII + regex)                 │                    │
│  └───────────────────────┬─────────────────────────┘                    │
│                          │ (blocked if policy violated)                 │
│                          ▼                                              │
│  ┌─────────────────────────────────────────────────┐                    │
│  │ Claude Model (Inference)                        │                    │
│  └───────────────────────┬─────────────────────────┘                    │
│                          │                                              │
│                          ▼                                              │
│  ┌─────────────────────────────────────────────────┐                    │
│  │ Guardrails — OUTPUT Filters                     │                    │
│  │  • Content Filters                              │                    │
│  │  • Word Filters                                 │                    │
│  │  • Sensitive Info (PII + regex)                 │                    │
│  │  • Contextual Grounding                         │                    │
│  │  • Automated Reasoning                          │                    │
│  └───────────────────────┬─────────────────────────┘                    │
│                          │ (blocked/anonymized if policy violated)      │
│                          ▼                                              │
└──────────────────────────┼──────────────────────────────────────────────┘
                           │  HTTPS Response
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Developer Workstation                                                    │
│    Response displayed to user                                            │
└──────────────────────────────────────────────────────────────────────────┘
```

## Layered Mitigations for Prompt Injection

Even with `PROMPT_ATTACK` enabled, prompt injection is one of the harder
classes of attack to fully prevent. Use these compensating controls in
combination:

1. **`PROMPT_ATTACK` in contentPolicyConfig** -- the first line of defence,
   verified to fire on classic jailbreak/injection patterns.

2. **Deny rules in settings.json** -- block known dangerous tool patterns
   that a successful injection might attempt. See
   [settings-linux-macos.jsonc](settings-linux-macos.jsonc) for the full
   deny list covering `curl`, `wget`, `sudo`, `git push`, and sensitive
   file reads.

3. **Local PreToolUse hooks** -- `git-guard.sh` and `pii-guard.sh` inspect
   every tool invocation before execution, blocking suspicious patterns
   regardless of what the model was instructed to do.

4. **Denied Topics policy** -- configure denied topics for "Instructions to
   disable security controls" and similar. Semantic matching; calibrate
   topic definitions against your prompts to manage FPR (we measured
   ~16.7% on a small edge-case set).

5. **Content Filters at HIGH threshold** -- catches many prompt injection
   payloads that contain harmful content categories as a side effect.

6. **Managed settings enforcement** -- use `managed-settings.json`
   deployed via SSM/MDM to prevent developers from removing hooks or deny
   rules. See [deployment-guide.md](deployment-guide.md).

7. **Network isolation** -- VPC endpoint policies and deny rules for
   `curl`/`wget` prevent data exfiltration even if injection succeeds.
   See [security-rationale.md](security-rationale.md).

## Monitoring and CloudWatch

When Guardrails intervene (block or anonymize content), AWS publishes metrics
to CloudWatch. Set up alarms to detect:

### Key Metrics

Verified from `aws cloudwatch list-metrics --namespace AWS/Bedrock/Guardrails`
(2026-05-29):

| Metric | Namespace | Meaning |
|--------|-----------|---------|
| `Invocations` | `AWS/Bedrock/Guardrails` | Total guardrail evaluations |
| `InvocationsIntervened` | `AWS/Bedrock/Guardrails` | Requests where guardrail took action (block or anonymize) |
| `InvocationLatency` | `AWS/Bedrock/Guardrails` | Guardrail processing latency, ms |
| `TextUnitCount` | `AWS/Bedrock/Guardrails` | Text policy units consumed (for cost tracking) |

**Dimensions:** `GuardrailArn`, `GuardrailVersion`, `GuardrailPolicyType`,
`GuardrailContentSource`, `Operation`. Use `GuardrailPolicyType` to slice
intervention rate by policy (content/topic/word/sensitive/contextual).

> **Note:** an earlier draft of this doc listed `InvocationsBlocked` — that
> metric does **not** exist. Use `InvocationsIntervened`.

### Recommended Alarms

```
# Alarm 1: sustained interventions (potential attack or misconfiguration)
MetricName: InvocationsIntervened
Statistic: Sum
Period: 300
EvaluationPeriods: 3
Threshold: 10
ComparisonOperator: GreaterThanThreshold
```

```
# Alarm 2: high intervention rate (>20% of requests intervened — likely misconfig)
# Use metric math: InvocationsIntervened / Invocations * 100
Threshold: 20
```

```
# Alarm 3: guardrail latency regression
MetricName: InvocationLatency
Statistic: p99
Period: 300
EvaluationPeriods: 2
Threshold: 1000   # ms; baseline observed in tests was 130–230ms
ComparisonOperator: GreaterThanThreshold
```

### Logging Guardrail Decisions

Enable Bedrock model invocation logging to capture full guardrail traces:
- S3 bucket for long-term storage
- CloudWatch Logs for real-time search

The trace includes which policy triggered, the matched content, and the action
taken. This integrates with the local audit chain from `audit-logger.sh` to
give end-to-end visibility.

## Streaming UX gotcha (read this)

When a guardrail blocks a prompt sent via
`InvokeModelWithResponseStream` (which Claude Code uses by default), Bedrock
does **not** raise an HTTP error or `stream_error` event. Instead, the client
receives a structurally-valid streaming response whose first (and only)
`content_block_delta` carries the literal text from
`blockedInputMessaging` — by default `BLOCKED_INPUT_BY_GUARDRAIL`.

Claude Code renders this as the model's reply, so the user sees:

```
> Please charge my card 4111-1111-1111-1111

BLOCKED_INPUT_BY_GUARDRAIL
```

### Verified facts (2026-05-30, `tests/aws-guardrails/11_blocked_messaging.py`)

| Property | Verified value |
|---|---|
| `blockedInputMessaging` flows verbatim in non-streaming response | ✅ exact match |
| `blockedInputMessaging` flows verbatim as a **single** stream `content_block_delta` | ✅ exact match (delta count = 1) |
| `blockedOutputsMessaging` (when output filter fires) flows verbatim, both modes | ✅ exact match |
| Special characters preserved (`<script>`, `&`, `"`, CJK, emoji) | ✅ no escape, no mangle |
| Min length | 1 char (empty rejected client-side) |
| **Max length** | **500 chars** — `1000` chars rejected with `ValidationException: Member must have length less than or equal to 500` |
| String templating (e.g., interpolating policy name into the message) | ❌ not supported; the string is returned exactly as configured |

### Recommended customisation

Set both messages to a clearly non-model prefix so the user (and any UI on
the receiving end) can tell this came from the guardrail, not the model.
Both tested verbatim:

```jsonc
{
  "blockedInputMessaging":  "[GUARDRAIL] Your request was blocked by enterprise security policy. Contact security@yourcompany.com if this is a false positive.",
  "blockedOutputsMessaging": "[GUARDRAIL] The model's response was filtered by enterprise output policy."
}
```

Stay under 500 chars per field. If you need more detail (e.g., an internal
ticket link), keep the customer-facing message short and put the rest in a
runbook the support email leads to.

### Optional: client-side detection

Because the guardrail message arrives through the same channel as model output,
client code can't tell them apart at the protocol level. Two pragmatic options:

1. **Distinctive prefix** (this kit's recommendation): pick a literal prefix
   you would never expect from the model (`[GUARDRAIL]`, `🚫`, etc.) and have
   a local hook scan output for it. If matched, surface the message via
   `stderr` instead of letting it look like model text.

2. **Watch CloudWatch `InvocationsIntervened`** out-of-band: this won't change
   the in-session UX but lets ops see when interventions fire. See the
   monitoring section above.

This wire behaviour is consistent across Mac, Linux EC2, and Windows EC2
(verified 2026-05).

## Items Requiring Verification

Most items in earlier drafts have now been verified live (see
[bedrock-guardrails-test-evidence.md](bedrock-guardrails-test-evidence.md)).
The remaining items still to validate **in your own environment**:

| # | Item | Status | Why your env may differ |
|---|---|---|---|
| 1 | Streaming intervention shape | ✅ verified — see "Streaming UX gotcha" above | Behaviour stable across SDKs/regions in our tests, but Claude Code's specific rendering of the magic string may change between releases. |
| 2 | CloudWatch metric names & namespace | ✅ verified `AWS/Bedrock/Guardrails` with 4 metric names | AWS occasionally adds metrics; re-check `list-metrics` after major Bedrock releases. |
| 3 | PII detection thresholds | ✅ verified — Bedrock pre-built catalogue is US-centric | Country-specific PII (NRIC, EU phone formats) needs `regexesConfig` patterns. |
| 4 | Cross-region inference + Guardrails | ✅ verified for `us.*` and `global.*` | Other inference-profile prefixes may exist for new regions. |
| 5 | Standard tier availability | ✅ available in us-east-1 | Re-check in your target region; schema is `tierConfig.tierName="STANDARD"` + `crossRegionConfig`. |
| 6 | Denied Topics FPR | ✅ measured ~16.7% on small edge-case set | Calibrate against your actual prompt distribution — your topic definitions and example data will differ. |
| 7 | Version handling | ✅ verified | DRAFT / numeric / invalid all behave as expected; bad-id and bad-version produce identical errors. |
| 8 | Latency impact | ✅ measured +18% p50 / +21% p95 | Will vary by policy complexity; re-measure after adding many regex patterns or denied topics. |
| 9 | `PROMPT_ATTACK` recall in your environment | partial — measured 5/5 on classic jailbreaks | Test against your domain's actual injection attempts; some specific patterns may slip. |
| 10 | Contextual Grounding for code-gen | ✅ verified — errors any request without `grounding_source` | Do NOT enable for general code-gen; only for narrow workflows with guaranteed source material. |
| 11 | `blockedInputMessaging` / `blockedOutputsMessaging` customisation | ✅ verified — verbatim, max 500 chars, special chars OK | If you need >500 chars, summarise + link to runbook. |

## References

- [AWS Bedrock Guardrails -- Components](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-components.html)
- [AWS Bedrock Guardrails -- Content Filters](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-content-filters.html)
- [AWS Bedrock Guardrails -- Prompt Attacks](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-prompt-attack.html)
- [AWS Bedrock Guardrails -- Input Tagging](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-input-tagging.html)
- [AWS Bedrock Guardrails -- Word Filters](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-word-filters.html)
- [AWS Bedrock Guardrails -- Sensitive Information](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-sensitive-information.html)
- [GitHub Issue #63637 -- Support Bedrock Guardrails Prompt Attack filter](https://github.com/anthropics/claude-code/issues/63637)
- Related docs in this repository:
  - [pii-guard.md](pii-guard.md) -- local PII/secrets scanning hook
  - [platform-compensations.md](platform-compensations.md) -- Windows `--print` mode gap and Bedrock Guardrails as compensation
  - [settings-linux-macos.jsonc](settings-linux-macos.jsonc) -- reference settings with guardrail headers
  - [security-rationale.md](security-rationale.md) -- overall security architecture
