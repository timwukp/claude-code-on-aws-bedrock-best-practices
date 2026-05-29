# =============================================================================
# PII & Secrets Guard Hook for Claude Code (Windows PowerShell)
# =============================================================================
# Scans user prompts and tool inputs for sensitive data BEFORE they reach the
# model. Blocks the request if PII or secrets are detected.
#
# Hook events: UserPromptSubmit, PreToolUse
# Exit codes: 0 = clean, 2 = blocked
#
# Deploy at: C:\Program Files\ClaudeCode\hooks\pii-guard.ps1
# Run via: powershell.exe -File "C:\Program Files\ClaudeCode\hooks\pii-guard.ps1"
# =============================================================================

$ErrorActionPreference = "Stop"
$input_json = [Console]::In.ReadToEnd()
$data = $input_json | ConvertFrom-Json

# Extract text to scan based on event
$event = $data.hook_event_name
switch ($event) {
    "UserPromptSubmit" { $text = $data.prompt }
    "PreToolUse"       { $text = ($data.tool_input | ConvertTo-Json -Depth 10) }
    default            { exit 0 }
}

if (-not $text -or $text.Length -lt 8) { exit 0 }

# Detection patterns: @{Label = Regex}
$patterns = @{
    "CREDIT_CARD"          = "\b[3-6]\d{3}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{1,4}\b"
    "AWS_ACCESS_KEY"       = "AKIA[0-9A-Z]{16}"
    "AWS_SECRET_KEY"       = "['""][0-9a-zA-Z/+=]{40}['""]"
    "API_KEY_ASSIGNMENT"   = "(api[_\-]?key|api[_\-]?secret|access[_\-]?token|auth[_\-]?token|secret[_\-]?key)\s*[:=]\s*['""]?[A-Za-z0-9_\-/.+=]{20,}['""]?"
    "PRIVATE_KEY"          = "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
    "JWT_TOKEN"            = "eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
    "DB_CONNECTION_STRING" = "(mongodb(\+srv)?|postgres(ql)?|mysql|mssql|redis|amqp)://[^\s'""]{10,}"
    "PASSWORD_ASSIGNMENT"  = "(password|passwd|pwd|pass)\s*[:=]\s*['""]?[^\s'""]{8,}['""]?"
    "SG_NRIC"              = "\b[STFGM]\d{7}[A-Z]\b"
    "EMAIL_ADDRESS"        = "\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
    "PHONE_INTL"           = "\+\d{1,3}[-\s]?\d{4,14}"
    "PASSPORT_NUMBER"      = "\b[A-Z]{1,2}\d{6,9}\b"
    "GIT_TOKEN"            = "(ghp_[A-Za-z0-9]{36}|glpat-[A-Za-z0-9\-]{20,})"
    "SLACK_TOKEN"          = "xox[bpras]-\d{10,}-[A-Za-z0-9\-]+"
    "HEX_SECRET"           = "\b[0-9a-f]{32,}\b"
}

# Scan
$detected = @()
foreach ($entry in $patterns.GetEnumerator()) {
    if ($text -match $entry.Value) {
        $detected += $entry.Key
    }
}

# Result
if ($detected.Count -gt 0) {
    $matches_str = $detected -join ", "
    [Console]::Error.WriteLine(@"
PII/SECRETS GUARD: Sensitive data detected - request BLOCKED before reaching the model.

Detected patterns: $matches_str

This content contains what appears to be sensitive information (credentials,
PII, or secrets). To protect against data leakage, this request has been
blocked at the hook layer and was NOT sent to the AI model.

Actions:
  - Remove the sensitive data from your prompt or file content
  - Use environment variables or secret references instead of literal values
  - If this is a false positive, contact your IT security team

Hook: pii-guard.ps1 | Event: $event
"@)
    exit 2
}

exit 0
