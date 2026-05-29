# Software Bill of Materials (SBOM) — Claude Code Enterprise Deployment

Tracks all software components in the Claude Code security stack. Required by:
- US Executive Order 14028 (federal contractors)
- EU Cyber Resilience Act
- MAS TRM 8.5 (third-party software inventory)

## Direct Dependencies

| Component | Version (tested) | Source | License | Purpose |
|---|---|---|---|---|
| **Claude Code CLI** | 2.1.150, 2.1.152 | npm `@anthropic-ai/claude-code` | Anthropic proprietary | Main agent CLI |
| **Node.js** | 20.18.0, 20.20.2 LTS | nodejs.org | MIT | Claude Code runtime |
| **npm** | 10.8.2 | bundled with Node | Artistic-2.0 | Package manager |
| **AWS Bedrock** | API (2023-04-20) | AWS managed service | AWS service terms | LLM inference |
| **Claude Sonnet 4.6** | us.anthropic.claude-sonnet-4-6 | Bedrock inference profile | Anthropic terms | Primary model |
| **Claude Haiku 4.5** | us.anthropic.claude-haiku-4-5-20251001-v1:0 | Bedrock inference profile | Anthropic terms | Fast model |

## Hook Dependencies (Linux/macOS)

| Component | Version | Source | License | Used By |
|---|---|---|---|---|
| bash | 4.0+ | OS-bundled | GPL-3.0 | All `.sh` hooks |
| jq | 1.6+ | Package manager | MIT | All hooks (JSON parsing) |
| grep | GNU 3.0+ | OS-bundled | GPL-3.0 | All hooks |
| sed | GNU 4.0+ | OS-bundled | GPL-3.0 | All hooks |
| git | 2.30+ | Package manager | GPL-2.0 | git-guard.sh |
| bubblewrap | 0.10.0 | Package manager | LGPL-2.1+ | sandbox.enabled |
| socat | 1.7.4.2 | Package manager | GPL-2.0 | sandbox network |

## Hook Dependencies (Windows)

| Component | Version | Source | License | Used By |
|---|---|---|---|---|
| PowerShell | 7.4.6 | Microsoft | MIT | pii-guard.ps1 |
| Windows Server 2022 | tested | Microsoft | Microsoft EULA | OS |

## Operational Dependencies

| Component | Required | Source | Purpose |
|---|---|---|---|
| logrotate | Linux | OS-bundled | Audit log rotation |
| cron / systemd timers | Linux | OS-bundled | Scheduled drift detection |
| AWS CLI | Optional | AWS | Manual operations |
| icacls | Windows | OS-bundled | File ACLs |
| chattr | Linux ext4/xfs | OS-bundled | MCP config lock |
| chflags | macOS | OS-bundled | MCP config lock — use `schg` (system immutable), NOT `uchg` (user-removable). See known-issues Issue 11. |

## Network Dependencies

| Endpoint | Purpose | Required | In allowlist |
|---|---|---|---|
| `bedrock-runtime.<region>.amazonaws.com` | Bedrock API | Yes | Yes |
| `*.bedrock-runtime.<region>.vpce.amazonaws.com` | VPC Endpoint | If VPCE used | Yes |
| `registry.npmjs.org` | npm install | Setup only | Optional |
| `nodejs.org` | Node.js install | Setup only | Optional |
| Anthropic telemetry | Usage stats | NO — disabled | Blocked |

## Vulnerability Scanning

| Component | Scanner | Frequency |
|---|---|---|
| Node.js binary | `npm audit` + Snyk | On install + monthly |
| Claude Code package | Anthropic security advisories | On release |
| OS packages | OS package manager security updates | Daily auto-patching |
| Hook scripts | shellcheck (static analysis) | On PR |
| AWS Bedrock service | AWS security bulletins | Subscribed |

## Supply Chain Verification

| Verification | How |
|---|---|
| Claude Code package | npm package signing (Anthropic) |
| Node.js binary | sha256 checksum from nodejs.org |
| Hook script integrity | Git SHA + drift-check.sh |
| Managed settings integrity | Git SHA + drift-check.sh |

## License Compatibility

All components compatible with internal enterprise use:
- MIT / Apache-2.0 (Node.js, jq, this repo): no restrictions
- GPL-3.0 (bash, grep, sed): runtime use only — does NOT trigger copyleft for hook scripts
- LGPL-2.1+ (bubblewrap): runtime use only
- Anthropic proprietary (Claude Code): governed by Anthropic Commercial Terms

## Update Policy

| Component | Strategy | Owner |
|---|---|---|
| Claude Code | Manual approval per version (staging first) | Security Lead |
| Node.js | Pin to LTS major; minor via OS patching | IT Ops |
| OS packages | Auto-patch CVEs within 7 days | IT Ops |
| Hook scripts | Version-controlled; PR review | Security team |
| Managed settings | Version-controlled; PR + CI gate | Security Lead |

## Machine-Readable SBOM

Generate CycloneDX format for compliance tooling:

```bash
# Install
npm install -g @cyclonedx/cyclonedx-npm

# Generate
cyclonedx-npm --output-file sbom.cdx.json

# Verify
cyclonedx-cli validate --input-file sbom.cdx.json
```

Ship `sbom.cdx.json` with each release for EO 14028 / EU CRA compliance.
