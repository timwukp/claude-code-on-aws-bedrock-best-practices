#!/usr/bin/env python3
"""Test #9 — Contextual Grounding for code generation tasks."""
import os, sys, json
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
import boto3

GID = open("tests/aws-guardrails/results/guardrail.env").read().split("\n")
GID = [l.split("=",1)[1] for l in GID if l.startswith("GUARDRAIL_ID=")][0]
c = boto3.client("bedrock-runtime", region_name="us-east-1")

# Contextual grounding requires: user content with qualifiers=[guard_content] AND
# at least one item with qualifiers=[grounding_source]. Apply-guardrail accepts both.

def apply(items):
    return c.apply_guardrail(guardrailIdentifier=GID, guardrailVersion="DRAFT",
                             source="OUTPUT", content=items)

print("=== A. novel code gen (no source) ===")
try:
    r = apply([{"text":{"text":"def factorial(n): return 1 if n<2 else n*factorial(n-1)",
                        "qualifiers":["guard_content"]}}])
    print(f"  action={r.get('action')}, assessments[0].contextualGrounding=", json.dumps(r.get("assessments",[{}])[0].get("contextualGroundingPolicy"), indent=2))
except Exception as e:
    print(f"  Exception: {type(e).__name__}: {e}")

print("\n=== B. faithful summary of provided source ===")
source = "The repo contains 3 files: main.py, util.py, test.py. main.py has 42 lines."
output = "There are three Python files in the repo, totalling 42 lines in main.py."
r = apply([
    {"text":{"text":source, "qualifiers":["grounding_source"]}},
    {"text":{"text":"How many files are in the repo?", "qualifiers":["query"]}},
    {"text":{"text":output, "qualifiers":["guard_content"]}},
])
print(f"  action={r.get('action')}")
cg = r.get("assessments",[{}])[0].get("contextualGroundingPolicy",{})
print(f"  filters: {json.dumps(cg.get('filters'), indent=2)}")

print("\n=== C. fabricated answer (should flag low grounding) ===")
output = "The repo contains 17 files, primarily Java with some Kotlin, plus a Dockerfile and CI config."
r = apply([
    {"text":{"text":source, "qualifiers":["grounding_source"]}},
    {"text":{"text":"How many files are in the repo?", "qualifiers":["query"]}},
    {"text":{"text":output, "qualifiers":["guard_content"]}},
])
print(f"  action={r.get('action')}")
cg = r.get("assessments",[{}])[0].get("contextualGroundingPolicy",{})
print(f"  filters: {json.dumps(cg.get('filters'), indent=2)}")

print("\n=== D. code gen task with no source material at all ===")
try:
    r = apply([
        {"text":{"text":"Write a Python sort function", "qualifiers":["query"]}},
        {"text":{"text":"def sort(arr): return sorted(arr)", "qualifiers":["guard_content"]}},
    ])
    print(f"  action={r.get('action')}")
    cg = r.get("assessments",[{}])[0].get("contextualGroundingPolicy",{})
    print(f"  filters: {json.dumps(cg.get('filters'), indent=2)}")
except Exception as e:
    print(f"  Exception: {type(e).__name__}: {e}")
