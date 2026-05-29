#!/usr/bin/env bash
# Drives every corpus case through hooks/pii-guard.sh and produces an FNR/FPR report.
#
# Each corpus line is JSON: {label, desc, text}.
# We wrap text into a real UserPromptSubmit hook payload and pipe to the guard.
# Exit 2 = blocked = "positive" detection.
# Exit 0 = passed  = "negative" detection.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${PII_GUARD:-$ROOT/hooks/pii-guard.sh}"
RESULTS_DIR="$ROOT/tests/results"
mkdir -p "$RESULTS_DIR"

OUT="$RESULTS_DIR/pii-corpus-results.tsv"
SUMMARY="$RESULTS_DIR/pii-corpus-summary.md"

printf 'kind\tlabel\tdesc\texpected\tactual\tcorrect\tlatency_ms\n' > "$OUT"

run_case() {
  local kind="$1" line="$2"
  local label desc text payload start end actual expected correct latency_ms
  label=$(printf '%s' "$line" | jq -r '.label')
  desc=$(printf '%s'  "$line" | jq -r '.desc')
  text=$(printf '%s'  "$line" | jq -r '.text')
  payload=$(jq -nc --arg p "$text" '{hook_event_name:"UserPromptSubmit", session_id:"test-sess", cwd:"/tmp", prompt:$p}')

  start=$(python3 -c 'import time;print(int(time.time()*1000))')
  printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1
  actual=$?
  end=$(python3 -c 'import time;print(int(time.time()*1000))')
  latency_ms=$((end - start))

  if [[ "$kind" == "positive" ]]; then
    expected=2
  else
    expected=0
  fi

  if [[ "$actual" == "$expected" ]]; then
    correct=1
  else
    correct=0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$label" "$desc" "$expected" "$actual" "$correct" "$latency_ms" >> "$OUT"
}

# Positives
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  run_case "positive" "$line"
done < <(cat "$ROOT/tests/pii-corpus/positive/"*.jsonl)

# Negatives
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  run_case "negative" "$line"
done < <(cat "$ROOT/tests/pii-corpus/negative/"*.jsonl)

# Compute summary with awk
python3 - "$OUT" "$SUMMARY" <<'PY'
import sys, csv, statistics
from collections import defaultdict
tsv_path, md_path = sys.argv[1], sys.argv[2]

rows = []
with open(tsv_path) as f:
    r = csv.DictReader(f, delimiter='\t')
    rows = list(r)

pos = [r for r in rows if r['kind']=='positive']
neg = [r for r in rows if r['kind']=='negative']
TP = sum(1 for r in pos if r['actual']=='2')
FN = sum(1 for r in pos if r['actual']!='2')
TN = sum(1 for r in neg if r['actual']=='0')
FP = sum(1 for r in neg if r['actual']!='0')

P = TP+FN
N = TN+FP
fnr = FN/P if P else 0
fpr = FP/N if N else 0
acc = (TP+TN)/(P+N) if (P+N) else 0

lat = sorted([int(r['latency_ms']) for r in rows])
def pct(p):
    if not lat: return 0
    k = max(0, min(len(lat)-1, int(round(p/100*(len(lat)-1)))))
    return lat[k]

# Per-label breakdown for positives
by_label = defaultdict(lambda: {'total':0,'caught':0})
for r in pos:
    by_label[r['label']]['total']+=1
    if r['actual']=='2': by_label[r['label']]['caught']+=1

# Per-label breakdown for negatives (false positive labels)
fp_cases = [r for r in neg if r['actual']!='0']

with open(md_path,'w') as f:
    f.write("# PII Guard — Corpus Test Results\n\n")
    f.write(f"- Positives: **{P}** (PII present)\n")
    f.write(f"- Negatives: **{N}** (clean text)\n")
    f.write(f"- True Positives: **{TP}** | False Negatives: **{FN}**\n")
    f.write(f"- True Negatives: **{TN}** | False Positives: **{FP}**\n\n")
    f.write(f"| Metric | Value |\n|---|---|\n")
    f.write(f"| Accuracy | {acc*100:.2f}% |\n")
    f.write(f"| **FNR (miss rate)** | **{fnr*100:.2f}%** |\n")
    f.write(f"| **FPR (false alarm)** | **{fpr*100:.2f}%** |\n")
    f.write(f"| Latency p50 | {pct(50)} ms |\n")
    f.write(f"| Latency p95 | {pct(95)} ms |\n")
    f.write(f"| Latency p99 | {pct(99)} ms |\n")
    f.write(f"| Latency max | {pct(100)} ms |\n\n")
    f.write("## Per-label detection\n\n| Label | Caught | Total | Recall |\n|---|---|---|---|\n")
    for lbl in sorted(by_label):
        v=by_label[lbl]
        f.write(f"| {lbl} | {v['caught']} | {v['total']} | {v['caught']/v['total']*100:.1f}% |\n")
    if fp_cases:
        f.write("\n## False positives (clean text incorrectly blocked)\n\n")
        for r in fp_cases:
            f.write(f"- `{r['label']}` — {r['desc']}\n")
    if FN:
        f.write("\n## False negatives (PII missed)\n\n")
        for r in pos:
            if r['actual']!='2':
                f.write(f"- `{r['label']}` — {r['desc']}\n")

print(f"FNR={fnr*100:.2f}%  FPR={fpr*100:.2f}%  acc={acc*100:.2f}%  p95={pct(95)}ms")
print(f"Wrote {md_path}")
PY
