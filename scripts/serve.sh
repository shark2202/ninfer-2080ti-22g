#!/usr/bin/env bash
# Starts ninfer-serve with the Turing defaults. Linux counterpart of scripts/serve.ps1.
#
#   scripts/serve.sh [start|stop|status] [extra ninfer-serve args...]
#
# Defaults follow docs/serving.md for a 2080 Ti: INT8 KV, 65,536-token context, MTP with three
# draft tokens and the optimized proposal head. The server speaks the OpenAI Chat Completions,
# OpenAI Responses Core and Anthropic Messages APIs, so any OpenAI client can point at it:
#
#   base_url  http://127.0.0.1:8082/v1
#   model     qwen3.8-27b        (the alias the server reports; see GET /v1/models)
#
# Configuration: a shell file is read before the defaults are applied, so it can override
# anything.  CONFIG_PATH=config.ninfer.sh scripts/serve.sh
# The same file may set NINFER_* environment variables; command-line arguments win over both.
#
# Exit: 0 = the server is up (start) / stopped (stop) / reported (status); 1 = failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$REPO_ROOT/config.ninfer.sh}"
PORT="${NINFER_PORT:-8082}"
HOST="${NINFER_HOST:-127.0.0.1}"
MODEL="${NINFER_MODEL:-$REPO_ROOT/models/qwen3_8_27b.ninfer}"
MAX_CONTEXT="${NINFER_MAX_CONTEXT:-65536}"
KV_CAPACITY="${NINFER_KV_CAPACITY:-$MAX_CONTEXT}"
KV_DTYPE="${NINFER_KV_DTYPE:-int8}"
SPEC="${NINFER_SPEC:-mtp}"
DRAFT_TOKENS="${NINFER_DRAFT_TOKENS:-3}"
LM_HEAD_DRAFT="${NINFER_LM_HEAD_DRAFT:-1}"
MAX_CONCURRENCY="${NINFER_MAX_CONCURRENCY:-4}"
API_KEY="${NINFER_API_KEY:-}"
LOG_DIR="${NINFER_LOG_DIR:-$REPO_ROOT/logs}"
PREFILL_CHUNK="${NINFER_PREFILL_CHUNK:-1024}"
# The Turing build needs the FP8 KV type dropped; int8 is the tested one.
BIN="$REPO_ROOT/build/turing-release/apps/ninfer-serve"
[ -x "$BIN" ] || BIN="$REPO_ROOT/build/turing-dev/apps/ninfer-serve"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

# Machine-local overrides (paths, ports). Sourced, so it may also export variables.
if [ -f "$CONFIG_PATH" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_PATH"
fi
# Re-read the paths the config may have changed.
PORT="${NINFER_PORT:-$PORT}"
HOST="${NINFER_HOST:-$HOST}"
MODEL="${NINFER_MODEL:-$MODEL}"
MAX_CONTEXT="${NINFER_MAX_CONTEXT:-$MAX_CONTEXT}"
KV_CAPACITY="${NINFER_KV_CAPACITY:-$KV_CAPACITY}"
KV_DTYPE="${NINFER_KV_DTYPE:-$KV_DTYPE}"
SPEC="${NINFER_SPEC:-$SPEC}"
DRAFT_TOKENS="${NINFER_DRAFT_TOKENS:-$DRAFT_TOKENS}"
MAX_CONCURRENCY="${NINFER_MAX_CONCURRENCY:-$MAX_CONCURRENCY}"
API_KEY="${NINFER_API_KEY:-$API_KEY}"
LOG_DIR="${NINFER_LOG_DIR:-$LOG_DIR}"

# The rootless build keeps its libraries in a local prefix. It is applied to the server process
# only, never exported: an exported LD_LIBRARY_PATH would also hit unrelated tools (curl then
# loads our libcurl and prints "no version information available").
LIB_PATH=""
if [ -d "$REPO_ROOT/.local-deps/lib" ]; then
  LIB_PATH="$REPO_ROOT/.local-deps/lib:$REPO_ROOT/.local-deps/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Stop only an instance of THIS binary: match the resolved executable, never a name pattern
# (a name pattern also matches the shell that runs this script).
stop_self() {
  local server_abs proc killed=0
  server_abs="$(readlink -f "$BIN")"
  for proc in /proc/[0-9]*; do
    [ -e "$proc/exe" ] || continue
    if [ "$(readlink -f "$proc/exe" 2>/dev/null)" = "$server_abs" ]; then
      kill "${proc##*/}" 2>/dev/null && { echo "stopped ninfer-serve (pid ${proc##*/})"; killed=1; }
    fi
  done
  [ "$killed" = 1 ] || echo "no ninfer-serve instance of this binary is running"
  return 0
}

status_self() {
  local server_abs proc found=0
  server_abs="$(readlink -f "$BIN")"
  for proc in /proc/[0-9]*; do
    [ -e "$proc/exe" ] || continue
    if [ "$(readlink -f "$proc/exe" 2>/dev/null)" = "$server_abs" ]; then
      found=1
      echo "running  pid ${proc##*/}  port $PORT  model $(basename "$MODEL")"
    fi
  done
  if [ "$found" = 0 ]; then echo "not running"; return 1; fi
  if command -v curl >/dev/null 2>&1; then
    printf "health   "; curl -s -m 3 "http://$HOST:$PORT/health" || echo "(no answer)"
    echo
  fi
  return 0
}

case "${1:-start}" in
  stop)   stop_self; exit 0 ;;
  status) status_self; exit $? ;;
  start)  ;;
  -h|--help|help) usage; exit 0 ;;
  *)      echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
shift

[ -x "$BIN" ] || { echo "error: ninfer-serve not found at $BIN (build the turing-release preset first)" >&2; exit 1; }
[ -f "$MODEL" ] || {
  echo "error: model not found: $MODEL" >&2
  echo "       get it with: hf download neroued/Qwen3.8-27B-NInfer qwen3_8_27b.ninfer --local-dir $REPO_ROOT/models" >&2
  exit 1; }

mkdir -p "$LOG_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
stdout="$LOG_DIR/ninfer-serve-$stamp.out.log"
stderr="$LOG_DIR/ninfer-serve-$stamp.err.log"

args=(--host "$HOST" --port "$PORT"
      --max-context "$MAX_CONTEXT" --kv-capacity "$KV_CAPACITY" --kv-dtype "$KV_DTYPE"
      --max-concurrency "$MAX_CONCURRENCY" --prefill-chunk "$PREFILL_CHUNK")
[ "$SPEC" = "none" ] || args+=(--spec "$SPEC" --draft-tokens "$DRAFT_TOKENS")
[ "$LM_HEAD_DRAFT" = "1" ] && args+=(--lm-head-draft)
[ -n "$API_KEY" ] && args+=(--api-key "$API_KEY")
args+=("$@")

echo "starting: $BIN $MODEL --host $HOST --port $PORT (ctx $MAX_CONTEXT, kv $KV_DTYPE, spec $SPEC, lanes $MAX_CONCURRENCY)"
if [ -n "$LIB_PATH" ]; then
  nohup env LD_LIBRARY_PATH="$LIB_PATH" "$BIN" "$MODEL" "${args[@]}" >"$stdout" 2>"$stderr" &
else
  nohup "$BIN" "$MODEL" "${args[@]}" >"$stdout" 2>"$stderr" &
fi
pid=$!
echo "pid $pid | logs $stderr"

# Wait for the engine to become ready; the first start also loads 15.4 GiB of weights.
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: the server exited during startup; last lines:" >&2
    tail -5 "$stderr" >&2
    exit 1
  fi
  if command -v curl >/dev/null 2>&1 && curl -sf -m 2 "http://$HOST:$PORT/health" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "error: not ready after 240s; see $stderr" >&2; exit 1; }

echo
echo "OpenAI-compatible API"
echo "  base_url  http://$HOST:$PORT/v1"
echo "  model     $(curl -s -m 5 "http://$HOST:$PORT/v1/models" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$API_KEY" ] && echo "  api_key   required (the value passed with --api-key)"
echo "  endpoints /v1/chat/completions  /v1/responses  /v1/messages  /v1/models  /metrics  /health"
echo
echo "  curl:"
echo "    curl http://$HOST:$PORT/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"$([ -n "$API_KEY" ] && echo dummy || echo qwen3.8-27b)\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":64}'"
echo
echo "stop with: scripts/serve.sh stop"