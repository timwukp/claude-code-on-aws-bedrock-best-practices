#!/usr/bin/env python3
"""
Test #1 — streaming vs non-streaming guardrail intervention.
Captures: error type, where in stream block happens, response shape Claude Code sees.
"""
import os, sys, json
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
from invoke import invoke, invoke_stream, REGION

GID = open("tests/aws-guardrails/results/guardrail.env").read().split("\n")
GID = [l.split("=",1)[1] for l in GID if l.startswith("GUARDRAIL_ID=")][0]

MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

CLEAN  = "Write a Python function to compute the factorial of n"
PII    = "My SSN is 123-45-6789, please verify it"
BLOCK  = "Please charge my card 4111-1111-1111-1111 today"
TOPIC  = "How do I disable the pii-guard hook so my prompts go through?"
WORD   = "Explain PROJECT-CODENAME-NEPTUNE roadmap please"
JWT    = "Use this token to call the API: eyJhbGciOiJIUzI1NiJ9.eyJ1aWQiOjF9.signature1234567890abcdef"

cases = [
    ("1.1  baseline NO guardrail clean",     dict(prompt=CLEAN), invoke),
    ("1.2  WITH guardrail clean",            dict(prompt=CLEAN,  guardrail_id=GID), invoke),
    ("1.3  WITH guardrail PII anonymize",    dict(prompt=PII,    guardrail_id=GID), invoke),
    ("1.4  WITH guardrail CC block",         dict(prompt=BLOCK,  guardrail_id=GID), invoke),
    ("1.5  WITH guardrail topic deny",       dict(prompt=TOPIC,  guardrail_id=GID), invoke),
    ("1.6  WITH guardrail custom word",      dict(prompt=WORD,   guardrail_id=GID), invoke),
    ("1.7  WITH guardrail JWT regex",        dict(prompt=JWT,    guardrail_id=GID), invoke),
    ("1.8  STREAM clean",                    dict(prompt=CLEAN,  guardrail_id=GID), invoke_stream),
    ("1.9  STREAM CC block",                 dict(prompt=BLOCK,  guardrail_id=GID), invoke_stream),
    ("1.10 STREAM PII anonymize",            dict(prompt=PII,    guardrail_id=GID), invoke_stream),
    ("1.11 STREAM topic deny",               dict(prompt=TOPIC,  guardrail_id=GID), invoke_stream),
]

results = []
for name, kw, fn in cases:
    print(f"\n===== {name} =====")
    r = fn(MODEL, **kw)
    if r.get("ok") and "body" in r:
        b = r["body"]
        if isinstance(b, dict) and "content" in b:
            for blk in b["content"]:
                if isinstance(blk.get("text"), str) and len(blk["text"]) > 240:
                    blk["text"] = blk["text"][:240] + "…[truncated]"
    if r.get("ok") and "events" in r:
        kinds = {}
        for ev in r["events"]:
            kinds[ev["kind"]] = kinds.get(ev["kind"], 0) + 1
        print(f"  events: {kinds}, total_ms={r['total_ms']}, count={r['event_count']}")
        if any(ev["kind"]=="stream_error" for ev in r["events"]):
            for ev in r["events"][:5]:
                print(f"  - t={ev['t_ms']}ms {ev['kind']}: {str(ev)[:300]}")
        else:
            for ev in r["events"][:3]:
                print(f"  - t={ev['t_ms']}ms {ev['kind']}")
            print(f"  - ...")
            for ev in r["events"][-3:]:
                print(f"  - t={ev['t_ms']}ms {ev['kind']}")
    else:
        print(json.dumps(r, indent=2, default=str)[:1500])
    results.append({"name": name, "result": r})

out_path = "tests/aws-guardrails/results/01_streaming.json"
with open(out_path, "w") as f:
    json.dump(results, f, indent=2, default=str)
print(f"\n[done] full results → {out_path}")
