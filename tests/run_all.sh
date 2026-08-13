#!/usr/bin/env bash
# Master runner — executes every test and stores results.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p tests/results

step() { echo; echo "=== $1 ==="; }

OK=0; FAIL=0; track() { [[ "$1" == 0 ]] && OK=$((OK+1)) || FAIL=$((FAIL+1)); }

step "1. PII corpus (FNR/FPR)"
bash tests/run_pii_corpus.sh; track $?

step "2. Hook telemetry shim"
bash tests/test_hook_wrapper.sh; track $?

step "3. Audit HMAC chain"
bash tests/test_audit_chain.sh; track $?

step "4. Token budget guard"
bash tests/test_token_budget.sh; track $?

step "5. Drift watcher self-test"
bash scripts/drift-watcher.sh --self-test; track $?

step "6. Bypass red-team harness"
bash tests/bypass-attempts.sh; track $?

step "7. Hook latency micro-bench"
bash tests/bench_hook_latency.sh; track $?

step "8. gh CLI guard"
bash tests/test_gh_guard.sh; track $?

step "9. MCP repo guard"
bash tests/test_mcp_repo_guard.sh; track $?

step "10. git guard"
bash tests/test_git_guard.sh; track $?

# Runs last on purpose: it is the suite that tells you the other two were
# testing the file you think they were.
step "11. Shared parser (no drift between the hooks and their canonical source)"
bash tests/test_shared_parser.sh; track $?

echo
echo "=================================="
echo "RUN-ALL: $OK suites passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
