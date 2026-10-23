#!/usr/bin/env bash
# 找"上下文 × 通道 × 投机"能起来的最大组合（起不来就是 device budget 不够）。
# 用法：bash sweep_ctx.sh <ctx> <lanes> <spec>
set -u
cd /home/a/ai-work/ninfer-2080ti-22g
PREFIX=$PWD/.local-deps
M=models/qwen3_8_27b.ninfer
ctx=$1; lanes=$2; spec=$3
extra=()
[ "$spec" = "mtp" ] && extra=(--spec mtp --draft-tokens 3 --lm-head-draft)
log=/tmp/sweep-$$.log
env LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu" \
  ./build/turing-release/apps/ninfer-serve "$M" --host 127.0.0.1 --port 8099 \
  --max-context "$ctx" --kv-capacity "$ctx" --kv-dtype int8 --max-concurrency "$lanes" \
  --prefill-chunk 1024 "${extra[@]}" > "$log" 2>&1 &
pid=$!
for i in $(seq 1 120); do
  grep -qa "listening on" "$log" && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if grep -qa "listening on" "$log"; then
  plan=$(grep -aoE "weights [0-9.]+ GiB" "$log" | head -1)
  vram=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | awk -F', ' -v p=$pid '$1==p{print $2}')
  printf "  ctx=%-7s lanes=%-2s spec=%-4s ✅ 起来（%s，进程显存 %s MiB）\n" "$ctx" "$lanes" "$spec" "$plan" "${vram:-?}"
else
  printf "  ctx=%-7s lanes=%-2s spec=%-4s ❌ %s\n" "$ctx" "$lanes" "$spec" \
    "$(grep -aoE 'Device budget cannot hold|error: [a-z ]+' "$log" | head -1)"
fi
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
rm -f "$log"
sleep 3
