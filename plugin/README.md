# Claude Code Bedrock Security

**Enterprise security controls for Claude Code on Amazon Bedrock** — fail-closed hooks for regulated industries (banking, healthcare, government). This plugin is the opt-in, one-command entry point to a larger production package: [**claude-code-on-aws-bedrock-best-practices**](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices), which adds Terraform IaC, managed-settings enforcement, a CloudWatch observability dashboard, Bedrock Guardrails integration, a STRIDE threat model, and compliance documentation.

> **Plugin vs. enterprise enforcement.** Installed as a plugin, these hooks run with *your* user permissions and can be removed by the user — good for evaluation and individual developers. For **un-removable, root-owned, fail-closed enforcement** across a fleet, deploy the same hooks via `managed-settings.json` + the Terraform modules in the full repo. The hooks are identical; only the trust boundary and default paths change (see [Enterprise deployment](#enterprise-deployment)).

## What it does

Five hooks, wired through a fail-closed telemetry shim:

| Hook | Event(s) | What it enforces |
|---|---|---|
| **pii-guard** | `UserPromptSubmit`, `PreToolUse` | Scans prompts and tool inputs for secrets (AWS keys, private keys, JWTs, DB connection strings, credit cards) **and national identifiers across the US, UK, Japan, South Korea, Singapore, EU (IBAN), and Australia**, then **blocks before the content reaches the model**. Every pattern is individually disable-able. |
| **git-guard** | `PreToolUse` (Bash) | Remote-URL allowlist, force-push prevention, protected-branch enforcement, and destructive-op blocking (`reset --hard`, `clean -f`, forced checkout). |
| **audit-logger** | `UserPromptSubmit`, `PostToolUse` | **Tamper-evident HMAC-SHA256 hash-chained** JSONL audit log. Any post-hoc edit, deletion, reorder, or insertion breaks the chain forward and is caught by `chain-verify.sh`. Optional dual-write to CloudWatch + SIEM webhook. |
| **token-budget-guard** | `PreToolUse`, `PostToolUse` | Per-session circuit breaker. Blocks further tool calls once a token or call budget is exceeded — a backstop against runaway agent loops. |
| **hook-wrapper** | (wraps all of the above) | Telemetry shim. Emits per-hook timing/exit JSON and **converts silent hook crashes/timeouts into explicit `exit 2` denials** (fail-closed), so a broken control fails *safe* instead of failing *open*. |

### Why this exists (the gap it fills)

Official AWS guidance for Claude Code on Bedrock ([`aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock`](https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock)) covers authentication and observability, but **stops above the hook layer** — no PII blocking, no git policy, no tamper-evident audit, no budget breaker. Anthropic's official [`security-guidance`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/security-guidance) plugin is advisory (warnings + LLM review), **not fail-closed enforcement**. The closest community audit tool, [`claude-notary`](https://github.com/K-sushi/claude-notary), signs entries with HMAC but does **not** hash-chain them, is not fail-closed, and has no cloud/SIEM integration. This plugin occupies exactly that empty layer: **fail-closed, enterprise-grade enforcement on the agent's actions**, with a hash-chained audit trail.

## Install

```
/plugin install fail-closed-security-hooks@claude-community
```

Or browse `/plugin > Discover`.

**Dependencies:** `bash` 4+, `jq`, `openssl`. `python3` is used for cross-platform hook timeouts. The `aws` CLI is optional (only for CloudWatch dual-write).

## Data handling (read before installing)

- **No data leaves your machine by default.** All hooks process input locally. Detected PII/secrets are **never** transmitted — the request is blocked *before* it reaches the model.
- **Default write locations are user-local:** `~/.claude/claude-code-security/` (audit log, telemetry, per-session budget state, dev HMAC key). Nothing is written to system paths in plugin mode.
- **Optional outbound calls — off unless you configure them:**
  - `audit-logger` calls the `aws` CLI **only if** `CLAUDE_AUDIT_CLOUDWATCH_GROUP` is set (CloudWatch Logs).
  - `audit-logger` runs `CLAUDE_AUDIT_ALERT_CMD` **only if** you set it (your SIEM webhook).
  - No telemetry, no analytics, no calls to any author-controlled endpoint — ever.
- **No `bypass-permissions` mode required.** Hooks only ever *allow* (exit 0) or *block* (exit 2).

## Verify the claims yourself

Every claim above is reproducible. Run the bundled suite (76 assertions, isolated sandbox, no network/root needed):

```bash
bash tests/run-tests.sh        # → RESULT: 76 passed, 0 failed
```

See [`tests/TEST_REPORT.md`](./tests/TEST_REPORT.md) for the method and full results. Or verify the headline differentiator — the tamper-evident audit chain — by hand:

```bash
git clone https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices
cd claude-code-on-aws-bedrock-best-practices

# 1. PII guard blocks an AWS key (expect: BLOCKED, exit 2)
#    (key assembled from fragments so this doc trips no secret scanner)
KEY="AKIA""IOSFODNN7""EXAMPLE"
echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"key $KEY\"}" \
  | bash hooks/pii-guard.sh; echo "exit=$?"

# 2. git-guard blocks a force push (expect: GIT GUARD ..., exit 2)
echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
  | bash hooks/git-guard.sh; echo "exit=$?"

# 3. Tamper-evident audit chain: write 3 events, verify, tamper, re-verify
export CLAUDE_AUDIT_LOG=/tmp/a.jsonl CLAUDE_AUDIT_STATE=/tmp/astate; mkdir -p /tmp/astate
for i in 1 2 3; do echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $i\"}}" | bash hooks/audit-logger.sh; done
bash scripts/chain-verify.sh /tmp/a.jsonl            # → chain intact, exit 0
sed -i '' '2s/echo 2/echo HACKED/' /tmp/a.jsonl 2>/dev/null || sed -i '2s/echo 2/echo HACKED/' /tmp/a.jsonl
bash scripts/chain-verify.sh /tmp/a.jsonl            # → CHAIN BROKEN, exit 1
```

## Detected identifiers — official sources & compliance drivers

The PII guard recognises national identifiers across seven jurisdictions. Two distinct authorities matter for each: the **format authority** (the body that issues/defines the number — *what it looks like*) and the **regulatory driver** (the financial / data-protection regulator that makes intercepting it a compliance requirement for regulated firms — *why an enterprise must block it*).

| Identifier | Format authority (A) | Regulatory driver (B) |
|---|---|---|
| 🇺🇸 SSN / ITIN | [SSA](https://www.ssa.gov/employer/structure.html) (20 CFR 422.103) · [IRS W-7](https://www.irs.gov/instructions/iw7) | [GLBA/FTC](https://www.ftc.gov/business-guidance/privacy-security/gramm-leach-bliley-act), [FFIEC](https://www.ffiec.gov/), [HIPAA/HHS](https://www.hhs.gov/hipaa/) |
| 🇬🇧 NINO / NHS | [HMRC·DWP (GOV.UK)](https://www.gov.uk/national-insurance/your-national-insurance-number) · [NHS England](https://www.datadictionary.nhs.uk/attributes/nhs_number.html) | [FCA](https://www.fca.org.uk/), [PRA](https://www.bankofengland.co.uk/prudential-regulation), [ICO (UK GDPR)](https://ico.org.uk/) |
| 🇯🇵 My Number | [Digital Agency](https://www.digital.go.jp/policies/mynumber) / [J-LIS](https://www.j-lis.go.jp/) | [FSA](https://www.fsa.go.jp/), [PPC (APPI)](https://www.ppc.go.jp/) |
| 🇰🇷 RRN | [MOIS](https://www.mois.go.kr/) (Resident Registration Act) | [FSC](https://www.fsc.go.kr/), [PIPC (PIPA)](https://www.pipc.go.kr/) |
| 🇸🇬 NRIC / FIN | [ICA](https://www.ica.gov.sg/) | [MAS](https://www.mas.gov.sg/), [PDPC](https://www.pdpc.gov.sg/) |
| 🇪🇺 IBAN | [ISO 13616](https://www.iso.org/standard/81090.html) / [SWIFT registry](https://www.swift.com/standards/data-standards/iban-international-bank-account-number) | [EBA](https://www.eba.europa.eu/), [EDPB (GDPR)](https://edpb.europa.eu/) |
| 🇦🇺 TFN / Medicare | [ATO](https://www.ato.gov.au/individuals-and-families/tax-file-number) · [Services Australia](https://www.servicesaustralia.gov.au/your-medicare-card) | [APRA](https://www.apra.gov.au/), [ASIC](https://asic.gov.au/), [AUSTRAC](https://www.austrac.gov.au/), [OAIC (TFN Rule)](https://www.oaic.gov.au/) |
| 💳 Card number | [ISO/IEC 7812-1](https://www.iso.org/standard/70484.html) (Luhn) | [PCI DSS](https://www.pcisecuritystandards.org/) |

> **Scope honesty.** These patterns validate **format only** (digit count and grouping). Check-digit/check-letter algorithms are published and *could* be enforced for UK NHS (Mod 11), IBAN (mod-97), and card numbers (Luhn), but are **deliberately not published** by the issuing authorities for Australia TFN/Medicare, Singapore NRIC/FIN, and Korea RRN — so this guard does not claim algorithmic validation for those. Links point to the official sources; verify currency before relying on them in an audit. Patterns and citations are iterated over time.

## Configuration

All hooks are configured through environment variables (set them in your Claude Code settings `env` block). Defaults are safe for individual use.

| Variable | Default | Purpose |
|---|---|---|
| `GIT_GUARD_ALLOWED_DOMAINS` | `github.com,gitlab.com,bitbucket.org` | Push/remote allowlist (supports `*.internal.example.com`). |
| `GIT_GUARD_PROTECTED_BRANCHES` | `main,master,release/*,production` | Branches that reject direct pushes. |
| `CLAUDE_TOKEN_BUDGET` / `CLAUDE_CALL_BUDGET` | `1000000` / `500` | Per-session circuit-breaker thresholds. |
| `CLAUDE_AUDIT_CLOUDWATCH_GROUP` | _(unset)_ | If set, dual-write audit events to this CloudWatch Logs group. |
| `CLAUDE_AUDIT_ALERT_CMD` | _(unset)_ | If set, pipe each audit event to this command (SIEM webhook). |
| `AUDIT_HMAC_KEY` | _(dev key auto-generated)_ | Provide a real secret in production; in plugin mode a per-machine dev key is generated under `~/.claude/claude-code-security/`. |

Full variable reference, hook contract, and threat model are in the [main repository](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices).

## Enterprise deployment

For fleet-wide, un-removable enforcement (the recommended posture for regulated environments):

1. Deploy the hooks via root-owned `managed-settings.json` with `allowManagedHooksOnly: true` so users cannot disable them.
2. Override the default user paths to root-owned locations (`/var/log/claude-code`, `/var/lib/claude-code`) and supply a real `AUDIT_HMAC_KEY` from Secrets Manager.
3. Run the Terraform modules for the EC2 baseline, CloudWatch dashboard, and SSM-distributed managed settings.

Step-by-step deployment, disaster recovery, incident response, and compliance mapping are documented in the [full repository](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices).

## Disclaimer

This is an **independent, personal open-source project — not affiliated with,
endorsed by, or supported by Anthropic or AWS.** "Claude", "Bedrock", and
related names are trademarks of their respective owners, used here for
descriptive purposes only. The security controls are provided **"AS IS",
without warranty of any kind** — they are best-effort, do not guarantee
detection of all sensitive data or compliance with any law or standard, and do
**not** constitute legal, regulatory, or professional security advice. You are
responsible for validating them in your own environment. See the repository's
[DISCLAIMER.md](https://github.com/timwukp/claude-code-on-aws-bedrock-best-practices/blob/main/DISCLAIMER.md). **Use at your own risk.**

## License

Apache-2.0. See [LICENSE](./LICENSE).
