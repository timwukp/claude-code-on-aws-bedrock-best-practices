#!/usr/bin/env python3
"""Test #8 — latency impact of guardrails."""
import os, sys, json, time, statistics
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
from invoke import invoke

GID = open("tests/aws-guardrails/results/guardrail.env").read().split("\n")
GID = [l.split("=",1)[1] for l in GID if l.startswith("GUARDRAIL_ID=")][0]

MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
N = 30
PROMPT = "Reply with just the word OK"

def bench(label, **kw):
    samples = []
    for i in range(N):
        r = invoke(MODEL, PROMPT, max_tokens=8, **kw)
        if r.get("ok"):
            samples.append(r["latency_ms"])
        else:
            print(f"  err: {r.get('error_code')}")
    s = sorted(samples)
    p = lambda q: s[max(0,min(len(s)-1, int(q/100*(len(s)-1))))]
    print(f"{label:30s} n={len(s):2d}  p50={p(50):4d}ms  p95={p(95):4d}ms  p99={p(99):4d}ms  mean={int(sum(s)/len(s)):4d}ms")
    return {"label": label, "samples": samples, "p50":p(50), "p95":p(95), "p99":p(99), "mean": sum(s)/len(s)}

print(f"=== Latency: {N} invocations each ===\n")
r1 = bench("WITHOUT guardrail")
r2 = bench("WITH guardrail (no trigger)", guardrail_id=GID, guardrail_version="DRAFT", trace=False)
r3 = bench("WITH guardrail (trace=ENABLED)", guardrail_id=GID, guardrail_version="DRAFT", trace=True)

delta_p50 = r2["p50"] - r1["p50"]
delta_p95 = r2["p95"] - r1["p95"]
print(f"\nGuardrail overhead at p50: {delta_p50:+d}ms  ({delta_p50/max(r1['p50'],1)*100:+.0f}%)")
print(f"Guardrail overhead at p95: {delta_p95:+d}ms  ({delta_p95/max(r1['p95'],1)*100:+.0f}%)")

with open("tests/aws-guardrails/results/08_latency.json","w") as f:
    json.dump({"baseline":r1,"with_guardrail":r2,"with_trace":r3}, f, indent=2)
