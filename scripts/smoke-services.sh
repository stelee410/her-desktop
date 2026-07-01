#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_JSON="$(ROOT="$ROOT" python3 - <<'PY'
import json
import os
from pathlib import Path

paths = []
override = os.environ.get("HER_CONFIG_PATH", "").strip()
if override:
    paths.append(Path(override).expanduser())
paths.append(Path(os.environ["ROOT"]) / "Config" / "her-desktop.local.json")
paths.append(Path.home() / "Library" / "Application Support" / "Her Desktop" / "config.json")
paths.append(Path.home() / ".her" / "desktop" / "config.json")

for path in paths:
    try:
        print(path.read_text())
        break
    except FileNotFoundError:
        continue
else:
    print("{}")
PY
)"

config_value() {
  python3 - "$CONFIG_JSON" "$1" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {}
value = data.get(sys.argv[2], "")
print(value if isinstance(value, str) else "")
PY
}

HER_AGENT_LLM_API_KEY="${HER_AGENT_LLM_API_KEY:-$(config_value agentLLMAPIKey)}"
HER_AGENT_MEM_API_KEY="${HER_AGENT_MEM_API_KEY:-$(config_value agentMemAPIKey)}"

: "${HER_AGENT_LLM_API_KEY:?Set HER_AGENT_LLM_API_KEY or configure agentLLMAPIKey}"
: "${HER_AGENT_MEM_API_KEY:?Set HER_AGENT_MEM_API_KEY or configure agentMemAPIKey}"

LLM_BASE="${HER_AGENT_LLM_BASE_URL:-$(config_value agentLLMBaseURL)}"
MEM_BASE="${HER_AGENT_MEM_BASE_URL:-$(config_value agentMemBaseURL)}"
LLM_MODEL="${HER_AGENT_LLM_MODEL:-$(config_value agentLLMModel)}"
AGENT_CODE="${HER_AGENT_CODE:-$(config_value agentCode)}"
USER_ID="${HER_USER_ID:-$(config_value userID)}"
LLM_BASE="${LLM_BASE:-https://agentllm.linkyun.co}"
MEM_BASE="${MEM_BASE:-https://agentmem.oyii.ai}"
LLM_MODEL="${LLM_MODEL:-linkyun-default}"
AGENT_CODE="${AGENT_CODE:-her-desktop}"
USER_ID="${USER_ID:-stelee}"
SMOKE_SESSION_ID="${HER_SMOKE_SESSION_ID:-her-desktop-smoke}"
CHAT_BODY="$(LLM_MODEL="$LLM_MODEL" python3 - <<'PY'
import json
import os
print(json.dumps({
    "model": os.environ["LLM_MODEL"],
    "messages": [
        {
            "role": "user",
            "content": "Say one short sentence confirming the Her Desktop smoke test reached the model.",
        }
    ],
    "stream": False,
}))
PY
)"
QUERY_BODY="$(AGENT_CODE="$AGENT_CODE" USER_ID="$USER_ID" SMOKE_SESSION_ID="$SMOKE_SESSION_ID" python3 - <<'PY'
import json
import os
print(json.dumps({
    "agent_code": os.environ["AGENT_CODE"],
    "user_id": os.environ["USER_ID"],
    "session_id": os.environ["SMOKE_SESSION_ID"],
    "query": "Her Desktop smoke test",
    "top_k": 1,
    "retrieval_policy": "balanced",
    "min_similarity": 0.08,
}))
PY
)"
LEGACY_QUERY_BODY="$(SMOKE_SESSION_ID="$SMOKE_SESSION_ID" python3 - <<'PY'
import json
import os
print(json.dumps({
    "session_id": os.environ["SMOKE_SESSION_ID"],
    "query": "Her Desktop smoke test",
    "top_k": 1,
    "retrieval_policy": "balanced",
    "min_similarity": 0.08,
}))
PY
)"
ADD_BODY="$(AGENT_CODE="$AGENT_CODE" USER_ID="$USER_ID" SMOKE_SESSION_ID="$SMOKE_SESSION_ID" python3 - <<'PY'
import json
import os
print(json.dumps({
    "agent_code": os.environ["AGENT_CODE"],
    "user_id": os.environ["USER_ID"],
    "session_id": os.environ["SMOKE_SESSION_ID"],
    "user_input": "Her Desktop live smoke test memory write.",
    "agent_response": "Her Desktop verified AgentMem writeback from smoke-services.sh.",
    "metadata": {
        "surface": "mac-smoke",
        "her_user_id": os.environ["USER_ID"],
        "her_agent_code": os.environ["AGENT_CODE"],
    },
}))
PY
)"
LEGACY_ADD_BODY="$(python3 - <<'PY'
import json
print(json.dumps({
    "user_input": "Her Desktop live smoke test memory write.",
    "agent_response": "Her Desktop verified AgentMem writeback from smoke-services.sh.",
}))
PY
)"

print_json_error_body() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text(errors="replace").strip()
print(body[:2000] if body else "<empty response body>")
PY
}

curl_retry() {
  local stderr_file
  stderr_file="$(mktemp)"
  if curl "$@" 2>"$stderr_file"; then
    rm -f "$stderr_file"
  else
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    return 1
  fi
}

is_legacy_schema_error() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path
try:
    body = json.loads(Path(sys.argv[1]).read_text(errors="replace"))
except Exception:
    raise SystemExit(1)
text = json.dumps(body, ensure_ascii=False)
if "extra_forbidden" in text and ("agent_code" in text or "user_id" in text):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "AgentLLM health"
curl_retry --http1.1 --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors --retry-delay 1 -fsS "$LLM_BASE/health"
echo

echo "AgentLLM chat"
curl_retry --http1.1 --connect-timeout 10 --max-time 45 --retry 3 --retry-all-errors --retry-delay 1 -fsS "$LLM_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $HER_AGENT_LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$CHAT_BODY" \
  | python3 -c 'import json,sys; text=json.load(sys.stdin)["choices"][0]["message"].get("content","").strip(); assert text, "empty model response"; print(text[:240])'

echo "AgentMem identity"
curl_retry --http1.1 --connect-timeout 10 --max-time 30 --retry 3 --retry-all-errors --retry-delay 1 -fsS "$MEM_BASE/v1/me" \
  -H "X-Memory-API-Key: $HER_AGENT_MEM_API_KEY" \
  -H "X-Agent-API-Key: $HER_AGENT_MEM_API_KEY" \
  | python3 -c 'import json,sys; j=json.load(sys.stdin); print({"known": j.get("known"), "display_name": j.get("display_name"), "memory_id": j.get("memory_id")})'

echo "AgentMem query"
query_body_file="$(mktemp)"
query_http_code="$(curl_retry --http1.1 --connect-timeout 10 --max-time 45 --retry 5 --retry-all-errors --retry-delay 2 -sS -o "$query_body_file" -w "%{http_code}" "$MEM_BASE/v1/memory/query" \
  -H "X-Memory-API-Key: $HER_AGENT_MEM_API_KEY" \
  -H "X-Agent-API-Key: $HER_AGENT_MEM_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$QUERY_BODY" || true)"
if [[ "$query_http_code" != 2* ]]; then
  if [[ "$query_http_code" == "422" ]] && is_legacy_schema_error "$query_body_file"; then
    echo "AgentMem query rejected scoped fields; retrying legacy key-bound payload."
    query_http_code="$(curl_retry --http1.1 --connect-timeout 10 --max-time 45 --retry 5 --retry-all-errors --retry-delay 2 -sS -o "$query_body_file" -w "%{http_code}" "$MEM_BASE/v1/memory/query" \
      -H "X-Memory-API-Key: $HER_AGENT_MEM_API_KEY" \
      -H "X-Agent-API-Key: $HER_AGENT_MEM_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$LEGACY_QUERY_BODY" || true)"
  fi
  if [[ "$query_http_code" != 2* ]]; then
    echo "AgentMem query failed: HTTP $query_http_code" >&2
    print_json_error_body "$query_body_file" >&2
    rm -f "$query_body_file"
    exit 1
  fi
fi
python3 -c 'import json,sys; j=json.load(sys.stdin); print({"count": len(j.get("retrieved_memories", [])), "timing_ms": j.get("timing_ms"), "context_prefix": j.get("injected_context", "")[:80]})' < "$query_body_file"
rm -f "$query_body_file"

if [[ "${HER_SMOKE_WRITE_MEMORY:-0}" == "1" ]]; then
  echo "AgentMem add"
  add_body_file="$(mktemp)"
  add_http_code="$(curl_retry --http1.1 --connect-timeout 10 --max-time 45 --retry 5 --retry-all-errors --retry-delay 2 -sS -o "$add_body_file" -w "%{http_code}" "$MEM_BASE/v1/memory/add" \
    -H "X-Memory-API-Key: $HER_AGENT_MEM_API_KEY" \
    -H "X-Agent-API-Key: $HER_AGENT_MEM_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: ${SMOKE_SESSION_ID}-agentmem-add" \
    -d "$ADD_BODY" || true)"
  if [[ "$add_http_code" != 2* ]]; then
    if [[ "$add_http_code" == "422" ]] && is_legacy_schema_error "$add_body_file"; then
      echo "AgentMem add rejected scoped fields; retrying legacy key-bound payload."
      add_http_code="$(curl_retry --http1.1 --connect-timeout 10 --max-time 45 --retry 5 --retry-all-errors --retry-delay 2 -sS -o "$add_body_file" -w "%{http_code}" "$MEM_BASE/v1/memory/add" \
        -H "X-Memory-API-Key: $HER_AGENT_MEM_API_KEY" \
        -H "X-Agent-API-Key: $HER_AGENT_MEM_API_KEY" \
        -H "Content-Type: application/json" \
        -H "Idempotency-Key: ${SMOKE_SESSION_ID}-agentmem-add" \
        -d "$LEGACY_ADD_BODY" || true)"
    fi
    if [[ "$add_http_code" != 2* ]]; then
      echo "AgentMem add failed: HTTP $add_http_code" >&2
      print_json_error_body "$add_body_file" >&2
      rm -f "$add_body_file"
      exit 1
    fi
  fi
  python3 -c 'import json,sys; j=json.load(sys.stdin); print({"status": j.get("status"), "task_id": j.get("task_id")})' < "$add_body_file"
  rm -f "$add_body_file"
fi
