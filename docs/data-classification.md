# Data Classification Policy — Claude Code Usage

Defines what classes of data may be processed by Claude Code on AWS Bedrock.
This document satisfies regulatory requirements for AI tool data governance
(MAS TRM 7.5, PDPA, GDPR Art. 30).

## Classification Levels

| Level | Definition | Examples | Claude Code Allowed? |
|---|---|---|---|
| **Public** | Information already in public domain | Open-source code, public docs, marketing material | ✅ Yes |
| **Internal** | Non-sensitive enterprise information | Internal wikis, code comments, build configs | ✅ Yes |
| **Confidential** | Business-sensitive, restricted to need-to-know | Source code, architecture diagrams, internal APIs | ⚠ Yes — with controls |
| **Restricted** | Highly sensitive, regulatory-protected | Customer PII, payment data, credentials, trading algorithms | ❌ No — must be redacted |

## Per-Class Controls

### Public — no special controls
- May be pasted into prompts freely
- May be referenced in tool inputs

### Internal — standard controls
- May be processed via Claude Code
- Audit log records the access
- No additional approval needed

### Confidential — controlled use
- Requires `git-guard.sh` to enforce push allowlist (no exfiltration)
- Requires `audit-logger.sh` for full activity trail
- Sandbox `denyRead` should NOT include the working directory
- Manager approval required for projects involving >100 confidential files

### Restricted — prohibited or with strong controls
- **Customer PII (NRIC, addresses, phone numbers)**: blocked by `pii-guard.sh`
- **Payment data (card numbers, CVV)**: blocked by `pii-guard.sh`
- **Credentials (API keys, passwords)**: blocked by `pii-guard.sh`
- **Trading algorithms / risk models**: requires CISO + Business Head approval; segregated environment
- **Customer financial records**: never directly; only via approved data-masking pipeline

## Mandatory Redaction Patterns

The `pii-guard.sh` hook blocks these patterns by default. Add bank-specific
patterns to the hook's `patterns=()` array:

| Pattern | Default | Bank-specific additions |
|---|---|---|
| Singapore NRIC | ✅ included | — |
| Credit cards | ✅ included | Internal card BIN ranges |
| AWS keys | ✅ included | Internal API token formats |
| Email addresses | ✅ included | Customer email domains (more aggressive) |
| Phone numbers | ✅ included | — |
| Account numbers | ❌ add | `\b[0-9]{10,16}\b` (banking account format) |
| SWIFT codes | ❌ add | `[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?` |
| IBAN | ❌ add | `[A-Z]{2}[0-9]{2}[A-Z0-9]{1,30}` |
| Internal employee IDs | ❌ add | per bank's HR ID format |

## Workflow Requirements

### Before using Claude Code on a project

1. **Classify the data** in the working directory:
   - Run `find . -type f | xargs -I{} sh -c 'head -100 {} | grep -l <restricted-pattern>'`
   - Or use existing DLP tools (Symantec DLP, Forcepoint, etc.)

2. **Determine highest classification** present
3. **Apply controls** per the matrix above
4. **Document** in project README which classification level applies

### During use

- `audit-logger.sh` records every action automatically
- If `pii-guard.sh` blocks a request, **STOP** — investigate why restricted data was in the prompt
- Report false positives via your enterprise security helpdesk

### After use

- Remove any model output containing classified data from local caches
- Verify no Claude session transcripts contain restricted data
- Comply with retention policy (typically 7 years for banking records)

## Compliance Mapping

| Regulation | Relevant requirement | How this policy satisfies it |
|---|---|---|
| MAS TRM 7.5.3 | AI tools must have data classification | This document + enforcement via hooks |
| PDPA s. 13 (consent) | Personal data processing requires consent | Restricted data blocked from Claude Code by default |
| GDPR Art. 30 (records of processing) | Must document data processing | audit-logger.sh provides records |
| GDPR Art. 35 (DPIA) | High-risk processing requires DPIA | DPIA required before Confidential/Restricted use |
| ISO 27001 A.8.2 | Information classification | This document |
| PCI DSS 3.4 | Cardholder data must be protected | pii-guard.sh blocks card numbers |

## Review Cycle

This document must be reviewed:
- **Annually** by CISO + Data Protection Officer
- **On regulatory change** (new MAS guidelines, PDPA amendment)
- **On incident** (after any data classification breach)
