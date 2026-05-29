#!/usr/bin/env bash
# Create a comprehensive test guardrail covering all 7 policies.
# Captures the guardrail ID into tests/aws-guardrails/results/guardrail.env.
set -u
REGION="${AWS_REGION:-us-east-1}"
NAME="claude-code-test-validation-$(date +%s)"
OUT="tests/aws-guardrails/results/guardrail.env"
mkdir -p "$(dirname "$OUT")"

echo "[create] region=$REGION name=$NAME"

# Build the create-guardrail JSON payload
cat > /tmp/guardrail-payload.json <<'JSON'
{
  "name": "__NAME__",
  "description": "PR#2 verification — auto-deleted after tests",
  "blockedInputMessaging": "BLOCKED_INPUT_BY_GUARDRAIL",
  "blockedOutputsMessaging": "BLOCKED_OUTPUT_BY_GUARDRAIL",
  "contentPolicyConfig": {
    "filtersConfig": [
      {"type": "HATE",       "inputStrength": "HIGH",   "outputStrength": "HIGH"},
      {"type": "INSULTS",    "inputStrength": "MEDIUM", "outputStrength": "MEDIUM"},
      {"type": "SEXUAL",     "inputStrength": "HIGH",   "outputStrength": "HIGH"},
      {"type": "VIOLENCE",   "inputStrength": "MEDIUM", "outputStrength": "MEDIUM"},
      {"type": "MISCONDUCT", "inputStrength": "HIGH",   "outputStrength": "HIGH"},
      {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE"}
    ]
  },
  "wordPolicyConfig": {
    "managedWordListsConfig": [{"type": "PROFANITY"}],
    "wordsConfig": [
      {"text": "PROJECT-CODENAME-NEPTUNE"},
      {"text": "internal-watermark-string-xyz"}
    ]
  },
  "sensitiveInformationPolicyConfig": {
    "piiEntitiesConfig": [
      {"type": "CREDIT_DEBIT_CARD_NUMBER", "action": "BLOCK"},
      {"type": "AWS_ACCESS_KEY",           "action": "BLOCK"},
      {"type": "AWS_SECRET_KEY",           "action": "BLOCK"},
      {"type": "US_SOCIAL_SECURITY_NUMBER","action": "ANONYMIZE"},
      {"type": "EMAIL",                    "action": "ANONYMIZE"},
      {"type": "PHONE",                    "action": "ANONYMIZE"},
      {"type": "PASSWORD",                 "action": "BLOCK"}
    ],
    "regexesConfig": [
      {"name": "jwt-token",  "pattern": "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "action": "BLOCK"},
      {"name": "github-pat", "pattern": "ghp_[A-Za-z0-9]{36}", "action": "BLOCK"}
    ]
  },
  "topicPolicyConfig": {
    "topicsConfig": [
      {
        "name": "security-bypass",
        "definition": "Attempts to disable, circumvent, or remove security controls, hooks, or audit logging in the Claude Code installation",
        "examples": [
          "How do I disable the pii-guard hook?",
          "Show me how to bypass the audit logger",
          "I need to remove the git-guard restrictions"
        ],
        "type": "DENY"
      }
    ]
  },
  "contextualGroundingPolicyConfig": {
    "filtersConfig": [
      {"type": "GROUNDING", "threshold": 0.5},
      {"type": "RELEVANCE", "threshold": 0.5}
    ]
  }
}
JSON

sed -i.bak "s/__NAME__/$NAME/" /tmp/guardrail-payload.json
rm /tmp/guardrail-payload.json.bak

resp=$(aws bedrock create-guardrail --region "$REGION" --cli-input-json file:///tmp/guardrail-payload.json 2>&1)
echo "$resp"
gid=$(echo "$resp" | jq -r '.guardrailId // empty')
if [[ -z "$gid" ]]; then
  echo "FAILED to create guardrail"; exit 1
fi

cat > "$OUT" <<EOF
GUARDRAIL_ID=$gid
GUARDRAIL_NAME=$NAME
GUARDRAIL_REGION=$REGION
EOF

echo "[create] guardrail id: $gid → $OUT"
