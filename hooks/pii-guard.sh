#!/bin/bash
# =============================================================================
# PII & Secrets Guard Hook for Claude Code
# =============================================================================
# Hook version: 1.0.0
# Last updated: 2026-05-28
# Compatible with: claude-code 2.1.150+
# Dependencies: bash 4+, jq (preferred), grep, sed
# Maintainer: <your security team email>
# Change log:
#   1.0.0 (2026-05-28) — initial release: 15 PII/secret patterns
# =============================================================================
# Scans user prompts and tool inputs for sensitive data BEFORE they reach the
# model. Blocks the request if PII or secrets are detected.
#
# Hook events supported:
#   - UserPromptSubmit: scans user prompt text
#   - PreToolUse: scans tool_input (file content being written, commands, etc.)
#
# Exit codes:
#   0 = clean, allow through
#   2 = sensitive data detected, BLOCK (stderr shown to user)
#
# Deploy at: /usr/local/etc/claude-code/hooks/pii-guard.sh
# Ownership: root:root 0755
# =============================================================================

set -u
input=$(cat)

# Extract the text to scan based on hook event
if command -v jq >/dev/null 2>&1; then
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
  case "$event" in
    UserPromptSubmit)
      text=$(printf '%s' "$input" | jq -r '.prompt // empty')
      ;;
    PreToolUse)
      # Scan the entire tool_input as a string (catches file content, commands, etc.)
      text=$(printf '%s' "$input" | jq -r '.tool_input | tostring')
      ;;
    *)
      exit 0
      ;;
  esac
else
  # Fallback without jq: scan entire input
  text="$input"
fi

# If text is empty or too short, skip
if [[ ${#text} -lt 8 ]]; then
  exit 0
fi

# =============================================================================
# DETECTION PATTERNS
# Each pattern: "LABEL:::REGEX"
# =============================================================================
patterns=(
  # Credit card numbers — Visa/MC/Discover/JCB (16 digit, 4-4-4-4) and Amex (15 digit, 4-6-5)
  "CREDIT_CARD_16:::[3-6][0-9]{3}[- ]?[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}"
  "CREDIT_CARD_AMEX:::3[47][0-9]{2}[- ]?[0-9]{6}[- ]?[0-9]{5}"

  # AWS Access Key ID
  "AWS_ACCESS_KEY:::AKIA[0-9A-Z]{16}"

  # AWS Secret Access Key (40 chars base64-ish after common prefixes)
  "AWS_SECRET_KEY:::['\"][0-9a-zA-Z/+=]{40}['\"]"

  # Generic API key patterns. NOTE: putting '-' at end of class avoids ERE range parse.
  "API_KEY_ASSIGNMENT:::(api[_-]?key|api[_-]?secret|access[_-]?token|auth[_-]?token|secret[_-]?key)[ ]*[:=][ ]*['\"]?[A-Za-z0-9_/.+=-]{20,}['\"]?"

  # Private key header
  "PRIVATE_KEY:::-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"

  # JWT token (3 base64url segments separated by dots). '-' placed at end of class.
  "JWT_TOKEN:::eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"

  # Database connection strings
  "DB_CONNECTION_STRING:::(mongodb(\+srv)?|postgres(ql)?|mysql|mssql|redis|amqp)://[^ '\"]{10,}"

  # Password in common assignment formats
  "PASSWORD_ASSIGNMENT:::(password|passwd|pwd|pass)[ ]*[:=][ ]*['\"]?[^ '\"]{8,}['\"]?"

  # Singapore NRIC/FIN
  "SG_NRIC:::[STFGM][0-9]{7}[A-Z]"

  # Email
  "EMAIL_ADDRESS:::[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"

  # Phone numbers (international, allows internal spaces or hyphens between digit groups)
  "PHONE_INTL:::\+[0-9]{1,3}([-. ][0-9]{2,5}){2,4}"

  # Passport numbers
  "PASSPORT_NUMBER:::[A-Z]{1,2}[0-9]{6,9}"

  # GitHub/GitLab tokens
  "GIT_TOKEN:::(ghp_[A-Za-z0-9]{36}|glpat-[A-Za-z0-9-]{20,})"

  # Slack tokens
  "SLACK_TOKEN:::xox[bpras]-[0-9]{10,}-[A-Za-z0-9-]+"

  # Generic hex secrets — 32+ hex chars containing at least one a-f letter
  # (rejects pure-decimal IDs and 0b binary literals which would otherwise match [0-9a-f]+).
  "HEX_SECRET:::(^|[^A-Za-z0-9_])[0-9a-f]*[a-f][0-9a-f]*[a-f][0-9a-f]{28,}([^A-Za-z0-9_]|$)"
)

# =============================================================================
# SCAN
# =============================================================================
detected=()

for entry in "${patterns[@]}"; do
  label="${entry%%:::*}"
  regex="${entry#*:::}"
  # PASSPORT_NUMBER, SG_NRIC, AWS_ACCESS_KEY require uppercase letters — match case-sensitive
  case "$label" in
    PASSPORT_NUMBER|SG_NRIC|AWS_ACCESS_KEY)
      if echo "$text" | grep -qE -- "$regex"; then
        detected+=("$label")
      fi
      ;;
    *)
      if echo "$text" | grep -qiE -- "$regex"; then
        detected+=("$label")
      fi
      ;;
  esac
done

# =============================================================================
# RESULT
# =============================================================================
if [[ ${#detected[@]} -gt 0 ]]; then
  matches=$(IFS=', '; echo "${detected[*]}")
  cat >&2 <<EOF
🚨 PII/SECRETS GUARD: Sensitive data detected — request BLOCKED before reaching the model.

Detected patterns: $matches

This content contains what appears to be sensitive information (credentials,
PII, or secrets). To protect against data leakage, this request has been
blocked at the hook layer and was NOT sent to the AI model.

Actions:
  • Remove the sensitive data from your prompt or file content
  • Use environment variables or secret references instead of literal values
  • If this is a false positive, contact your IT security team to adjust
    the detection patterns in the PII guard hook

Hook: pii-guard.sh | Event: $event
EOF
  exit 2
fi

exit 0
