#!/usr/bin/env python3
"""
Test #3 — Bedrock Guardrails PII detection per entity type.
Uses ApplyGuardrail (no model invocation) so we can run all 108 corpus cases cheaply.
Compares Bedrock results to local pii-guard.sh results.
"""
import os, sys, json, glob, subprocess
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
import boto3

GID = open("tests/aws-guardrails/results/guardrail.env").read().split("\n")
GID = [l.split("=",1)[1] for l in GID if l.startswith("GUARDRAIL_ID=")][0]
client = boto3.client("bedrock-runtime", region_name="us-east-1")

corpus_files = sorted(glob.glob("tests/pii-corpus/positive/*.jsonl") + glob.glob("tests/pii-corpus/negative/*.jsonl"))
results = []
counts = {"positive": 0, "negative": 0,
          "guardrail_blocked": 0, "guardrail_anonymized": 0, "guardrail_passed": 0}

for f in corpus_files:
    kind = "positive" if "/positive/" in f else "negative"
    for line in open(f):
        line = line.strip()
        if not line: continue
        case = json.loads(line)
        text = case["text"]
        try:
            r = client.apply_guardrail(
                guardrailIdentifier=GID,
                guardrailVersion="DRAFT",
                source="INPUT",
                content=[{"text": {"text": text}}],
            )
        except Exception as e:
            results.append({"file": f, "case": case, "error": str(e)})
            continue
        action = r.get("action", "NONE")
        intervened = action == "GUARDRAIL_INTERVENED"
        firing = []
        for a in r.get("assessments", []):
            for pol in ("topicPolicy","contentPolicy","wordPolicy","sensitiveInformationPolicy","contextualGroundingPolicy"):
                if pol in a:
                    blob = a[pol]
                    if blob.get("topics") or blob.get("filters") or blob.get("customWords") or \
                       blob.get("piiEntities") or blob.get("regexes") or blob.get("filters"):
                        firing.append(pol)
        if intervened:
            outs = r.get("outputs", [])
            replaced = outs[0]["text"] if outs else ""
            is_anon = replaced and replaced != "BLOCKED_INPUT_BY_GUARDRAIL" and replaced != text
            counts["guardrail_blocked" if not is_anon else "guardrail_anonymized"] += 1
        else:
            counts["guardrail_passed"] += 1
        counts[kind] += 1

        results.append({
            "file": os.path.basename(f),
            "label": case["label"],
            "desc": case.get("desc",""),
            "expected_kind": kind,
            "guardrail_action": action,
            "guardrail_firing_policies": firing,
            "guardrail_usage": r.get("usage", {}),
        })

with open("tests/aws-guardrails/results/03_pii.json","w") as f:
    json.dump({"counts": counts, "results": results}, f, indent=2, default=str)

print(f"\nGuardrail counts: {counts}")
print(f"Total cases: {counts['positive']} positive, {counts['negative']} negative")

from collections import defaultdict
by_label = defaultdict(lambda: {"total":0, "bedrock_caught":0})
for r in results:
    if r.get("error"): continue
    if r["expected_kind"] != "positive": continue
    by_label[r["label"]]["total"] += 1
    if r["guardrail_action"] == "GUARDRAIL_INTERVENED":
        by_label[r["label"]]["bedrock_caught"] += 1

print("\nPer-label Bedrock recall:")
print(f"{'Label':25s} {'Caught':>8s} {'Total':>8s} {'Recall':>8s}")
for lbl in sorted(by_label):
    v = by_label[lbl]
    pct = 100*v["bedrock_caught"]/v["total"] if v["total"] else 0
    print(f"{lbl:25s} {v['bedrock_caught']:>8d} {v['total']:>8d} {pct:>7.1f}%")

fp = [r for r in results if r.get("expected_kind")=="negative" and r.get("guardrail_action")=="GUARDRAIL_INTERVENED"]
if fp:
    print(f"\nBedrock false positives ({len(fp)}):")
    for r in fp[:10]:
        print(f"  - {r['label']} / {r['desc']} → fired: {r['guardrail_firing_policies']}")
