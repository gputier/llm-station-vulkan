# llm-station-vulkan

A second self-hosted LLM box, this one on an **AMD card with the Vulkan
backend**, serving a small vision-language model to Claude Code and to other
local clients.

It is the sibling of [llm-station-cuda](../llm-station-cuda), and the contrast is
the point: same `llama.cpp`, same Windows host, same client pattern, but 8 GB of
VRAM instead of 32 and no CUDA at all. Everything that survives that change is
the part worth copying.

## Hardware and software this was proven on

| | |
|---|---|
| GPU | AMD Radeon RX 5700 XT, 8 GB, driver 32.0.21045.5002 |
| OS | Windows 11 |
| Backend | `llama.cpp` Vulkan build b10603, prebuilt binaries, no compilation |
| Client | macOS, Claude Code over SSH |

**No build step.** Unlike the CUDA box, this one runs the official prebuilt
Vulkan release. On an 8 GB card there is nothing to gain from a custom build,
and Vulkan needs no toolchain.

## Model served

```powershell
.\llm-ctl.ps1 -Action qwen3vl4b
```

| | |
|---|---|
| Model | Qwen3-VL-4B-Instruct, Q4_K_M |
| Vision projector | `mmproj-Qwen3VL-4B-Instruct-F16.gguf` |
| Context | 81,920 |
| KV cache | `q4_0` |

Four other candidates stay configured in `llm-ctl.ps1` and were measured before
this one was retained: `qwen38distill`, `qwen3vl2b`, `lfm16`, `lfm3b`. Keeping
them costs nothing and makes a re-run possible. See
[models/qwen3-vl-4b/README.md](models/qwen3-vl-4b/README.md).

Two models are **barred** on this box: an earlier 9B froze the whole machine
during a benchmark and only a physical power cycle brought it back.

## A second profile, for API work rather than dialogue

`vlthink` serves the **Thinking edition of the same Qwen3-VL-4B**, same quantiser
and same footprint, so a bench against `qwen3vl4b` isolates one variable. It
exists for a different job: reading mail over the API, deciding what deserves an
answer, calling a tool for a fact it does not have. Here the thinking phase is
the point, not a latency to work around.

```powershell
.\llm-ctl.ps1 -Action vlthink
```

Three flags none of the other five carry, and each earns its place:

| Flag | Why |
|---|---|
| `--jinja` | Without it llama.cpp ignores the model's own template: tool calls are never parsed and thinking tags never recognised |
| `--reasoning-format deepseek` | Thoughts go to `message.reasoning_content`, the answer stays alone in `message.content`. A caller wants the verdict, not the deliberation |
| `-cram 8192` | 8 GiB of host-side prompt cache. This is not the context, see the measurement below |

Window is 32,768, not the model's native 256K and not the 81,920 of the Instruct
profile. On this card prompt processing decays as the window fills, so window
size is the first performance setting, ahead of any sampling parameter.

Measured on the machine, 2026-09-02:

| | |
|---|---|
| VRAM | 5,696 MB of 8,192 |
| Generation | 73.6 tokens per second |
| Mail sorted against four imposed rules | 10.8 s, valid JSON, rules respected |
| Tool choice, two opposite cases | 2 of 2 |
| Field extraction from an invoice image | 7 of 7, 21.2 s |

The prompt cache is what makes the batch case viable. A stable 1,816-token system
prompt costs 7.93 s cold, 0.55 s replayed, and **0.82 s with a different mail
behind it**, 1,789 tokens reused. From one mail to the next the instructions are
not recomputed.


## Quick start

```powershell
.\llm-ctl.ps1 -Action qwen3vl4b   # start, returns once /health answers
.\llm-ctl.ps1 -Action status      # what is loaded, and whether it answers
.\llm-ctl.ps1 -Action logs        # follow the live log of the running instance
.\llm-ctl.ps1 -Action stop        # free the GPU
```

`-Action` takes a model name or one of `stop`, `status`, `logs`, and nothing
else: the set is closed by `ValidateSet`, so a typo is refused by name instead of
being read as an unknown model. `stop` and `logs` accept `-Name` to target one
instance, `logs` accepts `-Tail`.

From the macOS client:

```bash
export LLM_HOST=your-server-hostname-or-ip
export LLM_SSH_USER=your-ssh-user

./clients/vlthink
```

## What closes the browser path, and what no longer does

The server binds `0.0.0.0`. A firewall protects you from the network but **not
from the browser case**: any web page open on any machine of the LAN can issue
requests to a LAN-bound server behind its user's back. Any model handling content
you would not paste into a public form needs that path closed.

**`--cors-origins ""`**, empty, is what closes it here. No legitimate client of
this service is a browser, so the right value is not an origin to allow but none
at all. Verified by execution: the allow-origin header comes back empty, and the
legitimate call, which presents no origin, still works.

This box also ran with **`--api-key`** from 2026-08-25 to 2026-09-02. The flag
was dropped when `llm-ctl.ps1` was rebuilt on the CUDA sibling's model, which has
never had one. What that costs is worth stating plainly rather than glossing:
a key also stops a non-browser client on the LAN, a script or a curl, from
reaching the model. CORS does not. If your threat model includes anything on the
network besides browsers, put `--api-key` back in the shared argument block
rather than per model, so that a later experiment cannot silently reopen access.

`/health` and `/props` are both open. The launcher reads `model_path` from
`/props` to learn which model is loaded, and that probe needs no header.

## Five findings that generalise beyond this box

### An empty argument silently corrupts the preceding flag

Found while deploying `--cors-origins ""`. The command-line builder dropped empty
arguments outright, so the **next** argument slid into the empty one's place.
The hardening would have been deployed across every model block without
doing what we thought, and reported as done.

It was caught by reading the command line the process was **actually running**,
not by re-reading the script. The fix is one condition, now carried by the
`Quote` function every argument goes through:

```powershell
if ($s -eq '' -or $s -match '[\s"]') { return '"' + ($s -replace '"','\"') + '"' }
```

### Redirected stderr stays empty until the process exits

`llama-server` writes everything to stderr. Redirect it through `cmd.exe` to a
file and the C runtime **fully buffers** it: the file sits at 0 bytes while the
process runs, which defeats exactly the failure diagnostic you wanted it for.

Use llama.cpp's own `--log-file` flag instead. The process flushes it itself and
the file stays readable live. This script does that, and the CUDA one does not,
which is why the CUDA one has an explicit note telling you which log file is the
real one.

### The GPU counter you need is in Windows, not in the vendor's tool

Relaunching a model too soon after stopping one lands on a card that has not
finished handing its memory back: `Stop-Process` returns as soon as the process
is marked dead, but the driver frees device memory asynchronously. The CUDA
sibling waits for the reading to settle by polling `nvidia-smi`. There is no AMD
equivalent on Windows, and ROCm does not cover this card at all, RDNA1 having
been dropped from its support list.

The reading exists anyway, one level down. WDDM publishes it as a performance
counter, so it is there for **any** graphics card:

```powershell
(Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage').CounterSamples
```

Two details make it usable. The counter names stay **English on a non-English
Windows**, verified here on `fr-FR`, so no culture-dependent lookup is needed.
And the set returns one instance per adapter, of which only one is the discrete
card, so the samples have to be summed rather than picked; the idle adapters
report zero.

> When a vendor tool has no counterpart on the other vendor, look for the same
> figure in the operating system before concluding the feature cannot be ported.

### A prefix cache is destroyed by one changed character at the top

Four near-identical requests against a 4,000-token system prompt:

| Request | Duration | Tokens reused from cache |
|---|---|---|
| First, cold cache | 25.8 s | 0 |
| Same prompt replayed | 0.28 s | 4,045 |
| **One line changed at the top** | **25.9 s** | **0** |
| Replayed identically | 0.26 s | 4,045 |

The cache keeps only the common **beginning** of two requests. As soon as the
start differs, everything after it is recomputed, even when the rest is
rigorously identical.

The calling application put the current time, minutes included, in the first
quarter of its system prompt. Every passing minute therefore threw away all the
work already done. Ninety-fold difference, entirely from prompt ordering.

> A prefix cache gain is not observed, it is designed. Stable text placed after
> volatile text will never be cached.

### A single-slot server turns any heavy request into an outage of the next one

Measured while chasing something else: three consecutive exchanges took 15, 29
and 5 seconds. The cause was a full-screen image being sent to the model, which
costs 38 to 47 seconds on this card. The server handles one request at a time,
so the user's next question waited behind the image with nothing signalling it,
and the client's 30-second timeout was shorter than the call itself.

Worth checking before blaming the model: the image did **not** evict the text
prompt cache, which survived intact on both sides. Queue wait and cache eviction
look identical from the client and call for opposite fixes.

## Documentation

| File | What it covers |
|---|---|
| [docs/prerequisites.md](docs/prerequisites.md) | What to install, and why there is no build step |
| [docs/claude-code-integration.md](docs/claude-code-integration.md) | Pointing Claude Code at this server, and what an 8 GB window changes |
| [models/qwen3-vl-4b/README.md](models/qwen3-vl-4b/README.md) | The served model and the four measured candidates |
| [clients/](clients/) | The launcher script |

## License

MIT. `llama.cpp` is MIT; model weights carry their own licenses.
