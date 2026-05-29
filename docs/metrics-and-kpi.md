# Security Metrics & KPIs — Claude Code Enterprise

How to measure if the security controls are actually working.

## Leading Indicators (preventive)

Track weekly. These show the controls are firing.

| Metric | Source | Target | Alert Threshold |
|---|---|---|---|
| **Hook block rate (PII)** | audit log: count of `pii-guard` exit 2 | Stable trend | +50% week-over-week → investigate |
| **Hook block rate (git)** | audit log: count of `git-guard` exit 2 | Stable trend | +50% WoW → investigate |
| **Wrapper rejection count** | wrapper stderr → syslog | Low (< 5/week) | > 20/week → user training needed |
| **Deny rule trigger count** | audit log: tool denials | Low | High = users trying dangerous things |
| **Active developers using Claude Code** | unique users in audit log | Track for capacity | — |
| **Sessions with no policy events** | audit log analysis | > 90% (most use is benign) | < 80% = review usage patterns |

## Lagging Indicators (detective)

Track monthly. These show effectiveness.

| Metric | Source | Target | Alert |
|---|---|---|---|
| **Mean Time To Detect (MTTD) policy violation** | incident timestamps | < 5 min (real-time hooks) | > 1 hour = control gap |
| **Mean Time To Respond (MTTR)** | P1/P2 incident reports | P1: 1 hour, P2: 4 hours | Exceed SLA = process gap |
| **False Positive Rate (FPR) — pii-guard** | (FP reports / total blocks) | < 5% | > 10% = pattern too broad |
| **False Negative Rate (FNR) — pii-guard** | red team test findings | 0 | Any FN = critical |
| **Hook availability** | (hook fires expected / actual) | 99.9% | < 99% = hook reliability issue |
| **Audit log integrity** | sha256 chain or chattr +a verification | 100% intact | Tampering = P1 |

## Compliance Metrics

Track quarterly for audit reports.

| Metric | Target | Used For |
|---|---|---|
| % developers with signed AI Usage Policy | 100% | MAS TRM 7.5.3 |
| % developer machines with managed-settings deployed | 100% | Centralized governance |
| % audit logs retained per policy | 100% (7 years for banking) | SOX, MAS, PDPA |
| Quarterly DR drill completion | 100% | MAS TRM 8.4 |
| Annual penetration test completion | 100% | ISO 27001 A.12.6 |
| Time since last hook pattern update | < 90 days | Continuous improvement |
| Number of UNVERIFIED settings still in production | 0 | Test coverage |

## Cost Metrics

Track to detect anomalies.

| Metric | Source | Target | Alert |
|---|---|---|---|
| **Bedrock spend per developer per month** | AWS Cost Explorer | Baseline + 20% | > 2x baseline = investigate |
| **Token usage per session** | OTEL telemetry / CloudWatch | < 100k avg | > 500k single session = check loop/abuse |
| **Bedrock API call rate per user** | CloudTrail | < 100 calls/hour | > 1000/hour = potential abuse |

## Dashboard Layout (recommended)

```
┌─────────────────────────────────────────────────────────────┐
│  Claude Code Security Dashboard                             │
├─────────────────────────────────────────────────────────────┤
│  TODAY     |  Total sessions  |  Policy events |  P1 alerts │
│            |     1,247        |      89        |     0      │
├─────────────────────────────────────────────────────────────┤
│  Hook block reasons (last 7 days)                           │
│   ▓▓▓▓▓▓▓▓ 156  PII (credit_card)                           │
│   ▓▓▓▓▓ 98     PII (aws_key)                                │
│   ▓▓▓ 45       git (unauthorized_remote)                    │
│   ▓ 12         git (force_push)                             │
├─────────────────────────────────────────────────────────────┤
│  Top 5 users by policy events     |  False positive rate    │
│   alice@bank      45              |   pii-guard:    3.2%    │
│   bob@bank        32              |   git-guard:    1.1%    │
│   ...                             |   wrapper:      0.0%    │
├─────────────────────────────────────────────────────────────┤
│  Coverage:                                                  │
│   Managed settings deployed:  98% (245/250 machines)        │
│   Wrapper script intact:      100%                          │
│   Hooks intact + root-owned:  100%                          │
│   Bedrock VPCE healthy:       ✓                             │
└─────────────────────────────────────────────────────────────┘
```

## Alerting Rules

Implement in your SIEM (Splunk SPL / Elastic KQL / CloudWatch alarms):

```
# 1. PII pattern frequency spike (potential active exfil attempt)
COUNT(event="pii-guard.deny") > 10 IN 5min FROM single user → P2 alert

# 2. Multiple wrapper rejections (potential bypass attempt)
COUNT(event="wrapper.refused") > 3 IN 1hour FROM single user → P2 alert

# 3. Off-hours activity (policy violation)
event="*" AND time NOT IN business_hours AND user NOT IN approved_oncall → P3

# 4. Geographic anomaly
event="*" AND user.geo NOT IN approved_regions → P3

# 5. Configuration drift
event="ConfigChange" AND source="user_settings" AND config="hooks" → P2

# 6. Audit log gap (tampering attempt)
NO event="*" FROM machine FOR > 1hour AND machine.heartbeat=alive → P1
```

## Reporting

Generate monthly executive summary with:
- Top 5 leading indicators
- Top 5 lagging indicators
- Notable incidents
- False positive trend
- Coverage gaps
- Recommendations
