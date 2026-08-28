# Qwen3-VL-4B-Instruct

The model retained on this box after a five-candidate comparison. Vision-language
model, Q4_K_M, served by the Vulkan backend on an 8 GB card.

```powershell
.\llm-ctl.ps1 qwen3vl4b
```

| | |
|---|---|
| Weights | `Qwen3VL-4B-Instruct-Q4_K_M.gguf` |
| Vision projector | `mmproj-Qwen3VL-4B-Instruct-F16.gguf` |
| Context | 81,920 |
| KV cache | `q4_0` (both K and V) |
| Batch | `-b 2048 -ub 512` |
| Chat template | patched, see below |

## The chat template has to be patched

Same blocker as every Qwen model on the [CUDA box](../../../llm-station-cuda/models/qwen3.8-27b/):
the embedded template raises `System message must be at the beginning` as soon as
a system message arrives after a user message, which agentic clients do
mid-session.

The symptom is misleading: `/v1/chat/completions` works in every manual test
while the agentic client fails on the very first turn.

Fix: `chat-template-system-anywhere.jinja`, a copy of the embedded template with
one line changed, loaded with `--chat-template-file`.

Note that one of the candidates below, `lfm16`, needs no patch at all: its native
template renders a late system message as an ordinary turn by construction. Worth
checking before assuming every model has this defect.

## Four candidates measured and not retained

All four stay configured in `llm-ctl.ps1`. Keeping them costs nothing and makes
a re-run possible without rebuilding the profiles.

| Action | Model | Context | Why not retained |
|---|---|---|---|
| `qwen3vl2b` | Qwen3-VL-2B-Instruct Q4_K_M | 114,688 | Exact little brother of the retained model. Larger window, weaker behaviour. |
| `qwen38distill` | Qwen3.8-4B-Distill Q4_K_M | 262,144 | Reasoning model. Fast only at the cost of cutting its own thinking, which degrades instruction following. |
| `lfm16` | LFM2.5-VL-1.6B F16 | 128,000 | Different publisher, unquantised weights. Triggers tool calls correctly only about half the time. |
| `lfm3b` | LFM2.5-VL-3B F16 | 49,152 | Unquantised F16: the context ceiling is set by weight size, not by KV cache cost. |

The two LFM candidates were served at full precision on purpose. Both answer in
French without being asked, which none of the other three guaranteed.

### The distilled model needs its thinking switched off

`qwen38distill` is a reasoning model. Without intervention it spends its whole
budget thinking before answering, which is unusable for short dialogue. The lever
that works:

```json
{"chat_template_kwargs": {"enable_thinking": false}}
```

Verified: 0 characters of reasoning with `enable_thinking: false`. Note this is
the Qwen key. The Muse family uses `reasoning_strength` instead, and using the
wrong key raises **no error at all**, the parameter is simply ignored.

## Two models are barred on this box

An earlier 9B model **froze the entire machine** during a measurement campaign,
and only a physical power cycle recovered it. On an 8 GB card, a model that does
not fit does not always fail cleanly: it can take the host down with it.

The launcher matches `model_path` against `qwen3vl-4b` specifically, rather than
a loose substring, so a barred model cannot be reached by accident.

## Sending an image costs 38 to 47 seconds

Measured on this card, full-screen capture. Since the server handles one request
at a time, that turns into an outage of whatever request comes next. See the main
[README](../../README.md) for the full chain, including why it was first
misdiagnosed as a cache eviction.

If your workload mixes vision and short dialogue, either accept the queue or run
vision on a second server.
