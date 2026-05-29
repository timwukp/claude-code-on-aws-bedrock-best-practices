# Third-Party Risk Assessment — Anthropic / AWS Bedrock

Vendor risk assessment template for the Claude Code stack.
Required by MAS Outsourcing Guidelines, OCC Bulletin 2013-29, EBA Guidelines on Outsourcing.

## Vendors in Scope

| Vendor | Role | Risk Tier |
|---|---|---|
| **Anthropic** | LLM provider (Claude models) | Tier 1 (Critical) |
| **Amazon Web Services** | Compute, network, Bedrock service | Tier 1 (Critical) |
| **Node.js Foundation / npm Inc.** | Runtime + package registry | Tier 2 (High) |

## Vendor Assessment: Anthropic

### Service description
Provider of Claude foundation models accessed via AWS Bedrock. The CLI tool (Claude Code)
is also distributed by Anthropic.

### Data flow
- **Outbound**: User prompts + tool inputs flow to Bedrock (which Anthropic's models read)
- **Inbound**: Model responses
- **No direct connection to Anthropic** when using Bedrock — AWS is the intermediary

### Compliance & certifications
- [ ] SOC 2 Type II — REQUEST FROM ANTHROPIC
- [ ] ISO 27001 — REQUEST FROM ANTHROPIC
- [ ] Anthropic Commercial Terms reviewed by Legal
- [ ] Data Processing Agreement (DPA) signed
- [ ] GDPR compliance statement from Anthropic
- [ ] Sub-processor list documented (likely AWS, possibly others)

### Security controls
| Control | Status | Notes |
|---|---|---|
| Data encryption in transit | ✅ | TLS 1.2+ (via Bedrock) |
| Data encryption at rest | ✅ | AWS-managed (Bedrock-side) |
| Customer data not used for training | ✅ Confirmed by AWS | Per AWS Bedrock service terms — data stays in customer account |
| Access logging | ✅ | CloudTrail records all Bedrock API calls |
| Vulnerability disclosure program | ✅ | https://www.anthropic.com/security |
| Incident notification SLA | ⚠ | Verify with Anthropic; default per DPA |

### Contractual provisions to verify
- [ ] Right to audit
- [ ] Data localization (e.g., US-only or EU-only data residency via Bedrock region)
- [ ] Termination assistance
- [ ] Sub-processor change notification
- [ ] Data deletion on termination
- [ ] Liability limits acceptable

### Concentration risk
- Single vendor for foundation model — mitigation: Bedrock supports multi-vendor (Claude, Llama, Titan)
- Can switch model with config change if Anthropic becomes unavailable

### Exit strategy
- 90-day notice possible (no long-term lock-in)
- Code in this kit is mostly vendor-agnostic (works with any Bedrock model)
- Migration path documented in disaster-recovery.md

## Vendor Assessment: AWS Bedrock

### Service description
Managed LLM inference service. Hosts Claude models via Anthropic partnership.

### Compliance & certifications
- ✅ SOC 1, 2, 3 Type II
- ✅ ISO 27001, 27017, 27018
- ✅ PCI DSS Level 1
- ✅ HIPAA eligible (BAA available)
- ✅ FedRAMP Moderate
- ✅ MAS authorized for use by Singapore financial institutions
- ✅ Multi-region (data residency choice)

### Existing enterprise contracts
- AWS Enterprise Support agreement (assumed in place)
- AWS BAA for HIPAA workloads (if applicable)
- AWS Data Processing Addendum

### Security controls in use
- VPC Endpoint (private connectivity, no public internet)
- IAM role-based access (least privilege)
- CloudTrail logging
- Bedrock Guardrails (content filtering)
- AWS KMS for any persistent data

## Vendor Assessment: Node.js / npm

### Service description
Runtime and package registry. Claude Code is distributed as an npm package.

### Risk
- Supply chain attack via npm package compromise (medium probability, high impact)

### Controls
- Pin to specific version
- Verify package signature
- Use private npm registry mirror (recommended for banks)
- npm audit on install
- Monitor Anthropic's package signing key

## Periodic Review

| Review type | Frequency | Owner |
|---|---|---|
| Anthropic Terms review | Annually | Legal + Security |
| AWS contract review | Annually | Legal |
| SOC 2 report review (Anthropic) | Annually | Security + Audit |
| AWS audit reports | Annually | Security |
| npm package supply chain | Quarterly | Security |
| Vendor incident notification check | After each notification | Security |

## Risk Register Entries

| Risk | Likelihood | Impact | Owner | Mitigation | Status |
|---|---|---|---|---|---|
| Anthropic data breach | Low | High | CISO | Bedrock isolation + DPA + monitoring | Accepted |
| Bedrock service outage | Medium | Medium | IT Ops | Multi-region failover (DR doc) | Mitigated |
| Anthropic terms change unfavorable | Low | Medium | Legal | Annual review + 90-day exit | Accepted |
| npm package compromise | Low | High | Security | Pin version + private mirror | Mitigated |
| AWS region failure | Low | Medium | IT Ops | Multi-region | Mitigated |

## Approval

| Role | Approved | Date |
|---|---|---|
| CISO | ☐ | __ |
| Chief Risk Officer | ☐ | __ |
| Legal | ☐ | __ |
| Data Protection Officer | ☐ | __ |
| Procurement | ☐ | __ |

(Sign-off required before production deployment.)
