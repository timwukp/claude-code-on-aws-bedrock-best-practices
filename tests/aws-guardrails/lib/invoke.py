#!/usr/bin/env python3
"""Helpers used by every guardrail test."""
import json, os, sys, time
import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
DEFAULT_MODEL = os.environ.get("TEST_MODEL", "us.anthropic.claude-haiku-4-5-20251001-v1:0")

_runtime = boto3.client("bedrock-runtime", region_name=REGION)
_control = boto3.client("bedrock", region_name=REGION)
_cwlogs  = boto3.client("logs", region_name=REGION)
_cw      = boto3.client("cloudwatch", region_name=REGION)


def build_body(prompt: str, max_tokens: int = 256) -> str:
    return json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    })


def invoke(model: str, prompt: str, *, guardrail_id: str | None = None,
           guardrail_version: str = "DRAFT", trace: bool = True,
           max_tokens: int = 256) -> dict:
    """Non-streaming invoke. Returns {ok, http_status, body, trace, latency_ms, exception}."""
    kwargs = {
        "modelId": model,
        "contentType": "application/json",
        "accept": "application/json",
        "body": build_body(prompt, max_tokens),
    }
    if guardrail_id:
        kwargs["guardrailIdentifier"] = guardrail_id
        kwargs["guardrailVersion"] = guardrail_version
        if trace:
            kwargs["trace"] = "ENABLED"
    t0 = time.time()
    try:
        resp = _runtime.invoke_model(**kwargs)
        body = json.loads(resp["body"].read())
        latency_ms = int((time.time() - t0) * 1000)
        return {
            "ok": True,
            "http_status": resp["ResponseMetadata"]["HTTPStatusCode"],
            "body": body,
            "guardrail_action": resp.get("guardrailIntervention"),
            "trace": body.get("amazon-bedrock-trace") or body.get("trace"),
            "latency_ms": latency_ms,
        }
    except ClientError as e:
        return {
            "ok": False,
            "exception": str(e),
            "error_code": e.response.get("Error", {}).get("Code"),
            "latency_ms": int((time.time() - t0) * 1000),
        }


def invoke_stream(model: str, prompt: str, *, guardrail_id: str | None = None,
                  guardrail_version: str = "DRAFT", max_tokens: int = 256) -> dict:
    """Streaming invoke. Captures every event in order with relative timestamps."""
    kwargs = {
        "modelId": model,
        "contentType": "application/json",
        "accept": "application/json",
        "body": build_body(prompt, max_tokens),
    }
    if guardrail_id:
        kwargs["guardrailIdentifier"] = guardrail_id
        kwargs["guardrailVersion"] = guardrail_version
        kwargs["trace"] = "ENABLED"

    t0 = time.time()
    events = []
    try:
        resp = _runtime.invoke_model_with_response_stream(**kwargs)
        for ev in resp["body"]:
            elapsed_ms = int((time.time() - t0) * 1000)
            if "chunk" in ev:
                chunk = json.loads(ev["chunk"]["bytes"])
                events.append({"t_ms": elapsed_ms, "kind": chunk.get("type"), "chunk": chunk})
            else:
                # internalServerException / modelStreamErrorException / etc.
                events.append({"t_ms": elapsed_ms, "kind": "stream_error", "raw": str(ev)})
        return {"ok": True, "events": events,
                "total_ms": int((time.time() - t0) * 1000),
                "event_count": len(events)}
    except ClientError as e:
        return {
            "ok": False,
            "exception": str(e),
            "error_code": e.response.get("Error", {}).get("Code"),
            "events_before_error": events,
            "latency_ms": int((time.time() - t0) * 1000),
        }


def pretty(o):
    print(json.dumps(o, indent=2, default=str))


if __name__ == "__main__":
    # quick smoke
    r = invoke(DEFAULT_MODEL, "Say PONG")
    pretty(r)
