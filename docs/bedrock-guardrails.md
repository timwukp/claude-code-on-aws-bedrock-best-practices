# AWS Bedrock Guardrails Integration Guide

Server-side content filtering and policy enforcement for Claude Code running on
Amazon Bedrock. Guardrails operate at the API layer -- they apply regardless of
client configuration, local hook bypasses, or `--print` mode gaps.

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
| 1 | Content Filters | **Yes** | 5 categories; input + output |
| 2 | Prompt Attack Filters | **No** | Requires input tags not sent by Claude Code |
| 3 | Denied Topics | **Yes** | Custom topic definitions |
| 4 | Word Filters | **Yes** | Profanity + custom list (up to 10,000 items) |
| 5 | Sensitive Information Filters | **Yes** | PII detection + custom regex |
| 6 | Contextual Grounding Checks | **Yes** | Hallucination detection |
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

### 2. Prompt Attack Filters

Detects three attack categories:
- **Jailbreaks** -- attempts to override model instructions
- **Prompt Injection** -- hidden instructions in user-supplied content
- **Prompt Leakage** -- attempts to extract system prompts (Standard tier only)

> **CRITICAL: This policy does NOT work with Claude Code.**
>
> The Prompt Attack filter requires the client to inject XML input tags of the
> form `<amazon-bedrock-guardrails-guardContent_xyz>` around user content, and
> include `amazon-bedrock-guardrailConfig.tagSuffix` in the request. Claude Code
> does not do either of these. See [Critical Limitation: Prompt Attack Filter
> (#63637)](#critical-limitation-prompt-attack-filter-63637) below.

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

  "contentPolicy": {
    "filtersConfig": [
      { "type": "HATE",       "inputStrength": "HIGH", "outputStrength": "HIGH" },
      { "type": "INSULTS",    "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "SEXUAL",     "inputStrength": "HIGH", "outputStrength": "HIGH" },
      { "type": "VIOLENCE",   "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "MISCONDUCT", "inputStrength": "HIGH", "outputStrength": "HIGH" }
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

> **Note:** Do NOT configure `promptAttackPolicy` -- it will not function with
> Claude Code until the input tagging limitation is resolved.

## What Works and What Doesn't

| Policy | Status | Direction | Reason |
|--------|--------|-----------|--------|
| Content Filters | **Works** | Input + Output | No input tags required |
| Denied Topics | **Works** | Input + Output | Semantic matching, no tags required |
| Word Filters | **Works** | Input + Output | Exact match, no tags required |
| Sensitive Information Filters | **Works** | Input + Output | Pattern/entity matching, no tags required |
| Contextual Grounding Checks | **Works** | Output only | Evaluates model output |
| Automated Reasoning Checks | **Works** | Output only | Evaluates model output |
| Prompt Attack Filters | **Does NOT work** | N/A | Requires `guardContent` input tags not sent by Claude Code |

The key distinction: policies that rely on pattern matching or semantic analysis
of raw content work fine. The Prompt Attack filter is unique in requiring the
client to explicitly mark which portions of the input are user-supplied content
-- and Claude Code does not do this.

## Critical Limitation: Prompt Attack Filter (#63637)

**GitHub Issue:** [anthropics/claude-code#63637](https://github.com/anthropics/claude-code/issues/63637)
-- "[Feature Request] Support Bedrock Guardrails Prompt Attack filter by
injecting guard_content input tags"

**Status:** OPEN

### The Problem

AWS Bedrock's Prompt Attack filter requires the calling application to wrap user
content in XML tags:

```
<amazon-bedrock-guardrails-guardContent_xyz>
  user-supplied content here
</amazon-bedrock-guardrails-guardContent_xyz>
```

The `xyz` suffix is a random value provided via
`amazon-bedrock-guardrailConfig.tagSuffix` in the API request. Claude Code does
not inject these tags and does not include the tag suffix parameter.

### What AWS Documentation States

From the official AWS documentation on input tagging:

> "You must always use input tags with your guardrails to indicate user inputs
> in the input prompt while using InvokeModel and InvokeModelWithResponseStream
> API operations for model inference. If there are no tags, prompt attacks for
> those use cases will not be filtered."

And:

> "If there are no tags in the input prompt, the complete prompt will be
> processed by guardrails. The only exception is Detect prompt attacks with
> Amazon Bedrock Guardrails filters, which require input tags to be present."

### Why the Random Tag Suffix Matters

AWS recommends using a new random string as the `tagSuffix` for every request:

> "It is recommended to use a new, random string as the tagSuffix for every
> request. This helps mitigate potential prompt injection attacks by making the
> tag structure unpredictable."

> "A static tag can result in a malicious user closing the XML tag and appending
> malicious content after the tag closure, resulting in an injection attack."

This is a security-critical design -- without randomized tags, an attacker could
craft input that closes the tag boundary and injects content outside the guarded
region.

### Impact

Without input tags, the Prompt Attack filter is completely non-functional. The
guardrail cannot distinguish between system instructions and user content, so it
cannot detect prompt injection or jailbreak attempts at the API layer.

The other six policies work because they operate on the full request content
without needing to know which parts are user-supplied.

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
│  │  • Denied Topics                                │                    │
│  │  • Word Filters                                 │                    │
│  │  • Sensitive Info (PII + regex)                 │                    │
│  │  • Prompt Attack  ← NOT FUNCTIONAL (no tags)    │                    │
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

## Interim Mitigations

Until [#63637](https://github.com/anthropics/claude-code/issues/63637) is
resolved and Claude Code sends input tags, use these compensating controls for
prompt injection protection:

1. **Deny rules in settings.json** -- block known dangerous tool patterns that a
   prompt injection might attempt. See
   [settings-linux-macos.jsonc](settings-linux-macos.jsonc) for the full deny
   list covering `curl`, `wget`, `sudo`, `git push`, and sensitive file reads.

2. **Local PreToolUse hooks** -- `git-guard.sh` and `pii-guard.sh` inspect every
   tool invocation before execution, blocking suspicious patterns regardless of
   what the model was instructed to do.

3. **Denied Topics policy** -- configure guardrail denied topics for
   "Instructions to disable security controls" and similar. This uses semantic
   matching (not input tag detection) and works today.

4. **Content Filters at HIGH threshold** -- catches many prompt injection
   payloads that contain harmful content categories as a side effect.

5. **Managed settings enforcement** -- use `managed-settings.json` deployed via
   SSM/MDM to prevent developers from removing hooks or deny rules. See
   [deployment-guide.md](deployment-guide.md).

6. **Network isolation** -- VPC endpoint policies and deny rules for `curl`/`wget`
   prevent data exfiltration even if injection succeeds. See
   [security-rationale.md](security-rationale.md).

## Monitoring and CloudWatch

When Guardrails intervene (block or anonymize content), AWS publishes metrics
to CloudWatch. Set up alarms to detect:

### Key Metrics

| Metric | Namespace | Meaning |
|--------|-----------|---------|
| `Invocations` | `AWS/Bedrock/Guardrails` | Total guardrail evaluations |
| `InvocationsIntervened` | `AWS/Bedrock/Guardrails` | Requests where guardrail took action |
| `InvocationsBlocked` | `AWS/Bedrock/Guardrails` | Requests fully blocked |

### Recommended Alarms

```
# Alarm: sustained guardrail interventions (potential attack or misconfiguration)
MetricName: InvocationsIntervened
Statistic: Sum
Period: 300
EvaluationPeriods: 3
Threshold: 10
ComparisonOperator: GreaterThanThreshold
```

```
# Alarm: high block rate (>20% of requests blocked -- likely misconfiguration)
# Use metric math: InvocationsBlocked / Invocations * 100
Threshold: 20
```

### Logging Guardrail Decisions

Enable Bedrock model invocation logging to capture full guardrail traces:
- S3 bucket for long-term storage
- CloudWatch Logs for real-time search

The trace includes which policy triggered, the matched content, and the action
taken. This integrates with the local audit chain from `audit-logger.sh` to
give end-to-end visibility.

## Items Requiring Verification

The following items should be tested in your specific AWS environment before
relying on them in production:

1. **Guardrail intervention behavior with streaming** -- Claude Code uses
   `InvokeModelWithResponseStream`. Verify that guardrail blocks interrupt the
   stream cleanly and Claude Code surfaces the error to the user.

2. **CloudWatch metric names and namespace** -- AWS may update metric names.
   Confirm the exact namespace and metric names available in your account by
   checking the CloudWatch console after triggering a test intervention.

3. **Specific PII types detected** -- test each PII type you care about (credit
   cards, SSNs, phone numbers, emails) with sample data to confirm detection
   thresholds match your expectations.

4. **Interaction with cross-region inference** -- if using inference profiles
   (e.g., `us.anthropic.claude-sonnet-4-6`), confirm guardrails apply correctly
   across region routing.

5. **Standard tier availability** -- Standard tier requires cross-region
   inference and may not be available in all regions. Verify in your account.

6. **Denied Topics semantic matching accuracy** -- test your topic definitions
   with both obvious and edge-case prompts to calibrate false positive/negative
   rates.

7. **Guardrail version behavior** -- when you update a guardrail, verify that
   the version number in `ANTHROPIC_CUSTOM_HEADERS` matches the published
   version, or use `DRAFT` for testing only.

8. **Latency impact** -- measure baseline latency with and without guardrails
   enabled. Complex policies (multiple denied topics, many PII types, custom
   regex) add processing time to every request.

9. **Prompt Attack filter status** -- monitor
   [#63637](https://github.com/anthropics/claude-code/issues/63637) for
   resolution. When Claude Code adds input tag support, re-enable the Prompt
   Attack policy.

10. **Contextual Grounding behavior** -- verify how Bedrock interprets
    conversation history as "source material" for grounding checks. Test whether
    the policy triggers for novel code generation (where no explicit reference
    document is provided) and whether it produces false positives or simply does
    not activate. Adjust thresholds or disable if the behavior is unhelpful for
    your use case.

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
