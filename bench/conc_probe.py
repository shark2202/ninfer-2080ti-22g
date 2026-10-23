#!/usr/bin/env python3
"""NInfer 并发压测：N 路同时请求，测每路与聚合的 decode tok/s。

对标 vLLM-2080Ti-Definitive 的单卡矩阵（单流 47.2 / 并发 1-4 聚合 74.8-85.3 tok/s）。
口径与 vLLM 那侧一致：同一服务、同一 prompt 家族、并发数不同，逐路取服务端上报的
decode tok/s，聚合 = 各路 tok/s 之和（不是墙钟除以总 token）。

两个必须遵守的口径（否则量到的不是并发）：

1. **每路用不同的题面**。llama.cpp 的 ngram-mod 会在 n-gram 表里命中上一路的相同文本，
   接受长度从 3-6 飙到 18-22（同题面时 31-53），聚合虚高一倍以上。
2. **和没有 n-gram 的引擎比较时，要关掉 ngram-mod**。llama.cpp 侧用
   `--spec-type draft-dflash`（纯神经草稿），与 NInfer 的 MTP 同类。

    python3 conc_probe.py --port 8082 --clients 1 2 4 --api-key sk-...
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def one(base: str, model: str, prompt: str, max_tokens: int, api_key: str = "") -> dict:
    payload = {
        "model": model, "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(base + "/v1/chat/completions",
                                 data=json.dumps(payload).encode(),
                                 headers=headers, method="POST")
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as r:
        d = json.load(r)
    wall = time.time() - t0
    t = d.get("timings") or {}
    return {
        "decode_tps": t.get("predicted_per_second") or 0.0,
        "predicted_n": t.get("predicted_n"), "prompt_n": t.get("prompt_n"),
        "wall": wall, "prompt_ms": t.get("prompt_ms"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8082)
    ap.add_argument("--clients", type=int, nargs="+", default=[1, 2, 4])
    ap.add_argument("--prompt", default="写一个 Python 函数，把列表按元素出现次数从多到少排序，同次数按首次出现顺序。给出代码和简短说明。")
    ap.add_argument("--max-tokens", type=int, default=400)
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--api-key", default=os.environ.get("NINFER_API_KEY", ""),
                    help="服务开了 --api-key 时必填（或设 NINFER_API_KEY 环境变量）")
    a = ap.parse_args()
    base = f"http://127.0.0.1:{a.port}"

    print(f"{'并发':>4} {'每路 tok/s':>26} {'聚合 tok/s':>11} {'墙钟 s':>8} {'prompt ms':>10}")
    print("-" * 66)
    for c in a.clients:
        # 每路用**不同的**题面，避免 n-gram 缓存命中把聚合虚高。
        prompts = [f"{a.prompt}\n（这是第 {i+1} 个彼此独立的问题，请重新作答，答案不要重复前一个。）"
                   for i in range(c)]
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=c) as ex:
            rs = list(ex.map(lambda i: one(base, a.model, prompts[i], a.max_tokens, a.api_key), range(c)))
        wall = time.time() - t0
        per = [r["decode_tps"] for r in rs]
        agg = sum(per)
        if c <= 3:
            per_txt = " / ".join(f"{v:.1f}" for v in per)
        else:
            per_txt = f"min {min(per):.1f}  med {statistics.median(per):.1f}  max {max(per):.1f}"
        pms = statistics.mean([r["prompt_ms"] or 0 for r in rs])
        print(f"{c:>4} {per_txt:>26} {agg:>11.1f} {wall:>8.1f} {pms:>10.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
