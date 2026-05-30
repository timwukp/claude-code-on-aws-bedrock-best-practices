#!/usr/bin/env python3
"""
Test #11 — verify blockedInputMessaging / blockedOutputsMessaging customisation.

Question: when we set blockedInputMessaging to a custom string, does Bedrock
return it verbatim in both streaming and non-streaming responses? Are there
length limits, escape rules, or content rules?

This is a follow-up on the streaming-UX-gotcha finding from PR #2: if the
default magic string is BLOCKED_INPUT_BY_GUARDRAIL and we recommend customising
it, we want concrete evidence the custom string actually flows through.
"""
import os, sys, json, time
sys.path.insert(0, os.path.dirname(__file__) + "/lib")
import boto3
from botocore.exceptions import ClientError
from invoke import invoke, invoke_stream

REGION = "us-east-1"
MODEL  = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
b = boto3.client("bedrock", region_name=REGION)

CC_TRIGGER = "Please charge my card 4111-1111-1111-1111 today"

CUSTOM_INPUT_MSG  = "[GUARDRAIL] Your request was blocked by enterprise policy. Contact security@example.com if this is a false positive."
CUSTOM_OUTPUT_MSG = "[GUARDRAIL] The model's response was filtered by enterprise policy."
LONG_MSG          = "[GUARDRAIL-LONG] " + ("X" * 400)  # 416 chars total
SPECIAL_MSG       = "[GUARDRAIL] <script>alert(1)</script> & \"quotes\" 你好 🚨"

def make_guardrail(name, in_msg, out_msg="DEFAULT_OUT"):
    """Create a minimal guardrail with the given messages and a CC PII filter."""
    return b.create_guardrail(
        name=name,
        description="msg-customisation test — auto-deleted",
        blockedInputMessaging=in_msg,
        blockedOutputsMessaging=out_msg,
        sensitiveInformationPolicyConfig={
            "piiEntitiesConfig":[{"type":"CREDIT_DEBIT_CARD_NUMBER","action":"BLOCK"}],
        },
    )

def wait_ready(gid, timeout_s=60):
    for _ in range(timeout_s):
        s = b.get_guardrail(guardrailIdentifier=gid)["status"]
        if s == "READY": return
        time.sleep(1)
    raise RuntimeError(f"guardrail {gid} not ready")

def cleanup(gid):
    try: b.delete_guardrail(guardrailIdentifier=gid)
    except: pass

results = []

# ============================================================
# Test 11.1 — basic custom string roundtrip (non-streaming + streaming)
# ============================================================
print("=== 11.1  Basic custom string ===")
g = make_guardrail(f"msg-test-basic-{int(time.time())}", CUSTOM_INPUT_MSG, CUSTOM_OUTPUT_MSG)
gid = g["guardrailId"]
wait_ready(gid)
print(f"  guardrail: {gid}")

# Non-streaming
r = invoke(MODEL, CC_TRIGGER, guardrail_id=gid, guardrail_version="DRAFT", trace=False, max_tokens=100)
nonstream_text = r["body"]["content"][0]["text"] if r.get("ok") else "ERROR"
nonstream_ok = nonstream_text == CUSTOM_INPUT_MSG
print(f"  non-streaming: ok={nonstream_ok}  text={nonstream_text!r}")

# Streaming
r2 = invoke_stream(MODEL, CC_TRIGGER, guardrail_id=gid, guardrail_version="DRAFT", max_tokens=100)
stream_deltas = []
for ev in r2.get("events", []):
    chunk = ev.get("chunk", {})
    if chunk.get("type") == "content_block_delta":
        stream_deltas.append(chunk.get("delta", {}).get("text", ""))
stream_text = "".join(stream_deltas)
stream_ok = stream_text == CUSTOM_INPUT_MSG
print(f"  streaming: ok={stream_ok}  delta_count={len(stream_deltas)}  text={stream_text!r}")

results.append({
    "test": "11.1 basic custom string",
    "expected": CUSTOM_INPUT_MSG,
    "non_streaming": {"ok": nonstream_ok, "text": nonstream_text},
    "streaming": {"ok": stream_ok, "delta_count": len(stream_deltas), "text": stream_text},
})
cleanup(gid)

# ============================================================
# Test 11.2 — special chars (HTML, quotes, CJK, emoji)
# ============================================================
print("\n=== 11.2  Special chars ===")
g = make_guardrail(f"msg-test-special-{int(time.time())}", SPECIAL_MSG, "out")
gid = g["guardrailId"]
wait_ready(gid)

r = invoke(MODEL, CC_TRIGGER, guardrail_id=gid, guardrail_version="DRAFT", trace=False, max_tokens=100)
got = r["body"]["content"][0]["text"] if r.get("ok") else "ERROR"
ok = got == SPECIAL_MSG
print(f"  special-chars verbatim: {ok}  got={got!r}")
results.append({"test":"11.2 special chars","expected":SPECIAL_MSG,"got":got,"ok":ok})
cleanup(gid)

# ============================================================
# Test 11.3 — long string (416 chars)
# ============================================================
print("\n=== 11.3  Long string (416 chars) ===")
try:
    g = make_guardrail(f"msg-test-long-{int(time.time())}", LONG_MSG, "out")
    gid = g["guardrailId"]
    wait_ready(gid)
    r = invoke(MODEL, CC_TRIGGER, guardrail_id=gid, guardrail_version="DRAFT", trace=False, max_tokens=600)
    got = r["body"]["content"][0]["text"] if r.get("ok") else "ERROR"
    ok = got == LONG_MSG
    truncated = len(got) < len(LONG_MSG)
    print(f"  long verbatim: {ok}  got_len={len(got)}  expected_len={len(LONG_MSG)}  truncated={truncated}")
    results.append({"test":"11.3 long","ok":ok,"got_len":len(got),"expected_len":len(LONG_MSG)})
    cleanup(gid)
except ClientError as e:
    print(f"  long string create failed: {e}")
    results.append({"test":"11.3 long","error":str(e)})

# ============================================================
# Test 11.4 — empty string (probe limits)
# ============================================================
print("\n=== 11.4  Empty string ===")
try:
    g = make_guardrail(f"msg-test-empty-{int(time.time())}", "", "out")
    gid = g["guardrailId"]
    print(f"  empty accepted? guardrail created: {gid}")
    cleanup(gid)
    results.append({"test":"11.4 empty","accepted":True})
except ClientError as e:
    print(f"  empty rejected: {e.response.get('Error',{}).get('Code')}: {str(e)[:200]}")
    results.append({"test":"11.4 empty","accepted":False,"error":str(e)[:200]})

# ============================================================
# Save evidence
# ============================================================
out_path = "tests/aws-guardrails/results/11_blocked_messaging.json"
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path,"w") as f:
    json.dump(results, f, indent=2, default=str)
print(f"\n[done] full results → {out_path}")
