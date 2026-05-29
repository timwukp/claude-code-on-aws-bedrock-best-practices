#!/usr/bin/env python3
"""Test #4 — Cross-region inference profile + Guardrails."""
import os, sys, json
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
from invoke import invoke

GID = open("tests/aws-guardrails/results/guardrail.env").read().split("\n")
GID = [l.split("=",1)[1] for l in GID if l.startswith("GUARDRAIL_ID=")][0]

TRIGGER = "Please charge my card 4111-1111-1111-1111 today"

cases = [
    ("inference profile us.* sonnet-4-6",  "us.anthropic.claude-sonnet-4-6"),
    ("inference profile global.* haiku",   "global.anthropic.claude-haiku-4-5-20251001-v1:0"),
    ("direct model id sonnet-4-5 no profile", "anthropic.claude-sonnet-4-5-20250929-v1:0"),
]

results = []
for name, model in cases:
    print(f"\n=== {name} ({model}) ===")
    r = invoke(model, TRIGGER, guardrail_id=GID, guardrail_version="DRAFT", trace=True, max_tokens=128)
    if not r.get("ok"):
        print(f"  ERROR: {r.get('error_code')} — {r.get('exception','')[:200]}")
    else:
        body = r["body"]
        text = body.get("content",[{}])[0].get("text","")[:120]
        trace = body.get("amazon-bedrock-trace") is not None
        print(f"  status={r['http_status']}  text='{text}'  trace_present={trace}  latency={r['latency_ms']}ms")
    results.append({"name": name, "model": model, "result": r})

with open("tests/aws-guardrails/results/04_cross_region.json","w") as f:
    json.dump(results, f, indent=2, default=str)
