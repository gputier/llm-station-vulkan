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
.\llm-ctl.ps1 qwen3vl4b
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

## Quick start

```powershell
# Set the API key first: the script reads it from the environment.
$env:LLM_API_KEY = "..."

.\llm-ctl.ps1 qwen3vl4b   # start
.\llm-ctl.ps1 status      # what is loaded
.\llm-ctl.ps1 stop        # free the GPU
```

From the macOS client:

```bash
export LLM_HOST=your-server-hostname-or-ip
export LLM_SSH_USER=your-ssh-user
export LLM_API_KEY=the-same-key

./clients/aziz
```

Generate a key with `openssl rand -base64 24`. It is read from the environment
in both places so it never lands in version control.

## This box is locked down, and the CUDA one is not

That difference is deliberate and worth explaining, because the reasoning
generalises.

The server binds `0.0.0.0`. A firewall protects you from the network but **not
from the browser case**: any web page open on any machine of the LAN can issue
requests to a LAN-bound server behind its user's back. Any model handling content
you would not paste into a public form needs that path closed.

Two settings close it:

- **`--api-key`**, declared once at the top of the script and reused by all five
  model blocks, so that a future experiment cannot silently reopen access. Both
  `Authorization: Bearer` and `x-api-key` are accepted, which leaves client tools
  a choice. Verified by execution: a request without the key is refused, with it
  succeeds, and persistence survived three real reboots.
- **`--cors-origins ""`**, empty. No legitimate client of this service is a
  browser, so the right value is not an origin to allow but none at all.
  Verified independently: the allow-origin header comes back empty, and the
  legitimate call, which presents no origin, still works.

`/health` stays open without a key on purpose: it is how tools learn the service
is up before authenticating, and it discloses nothing.

## Three findings that generalise beyond this box

### An empty argument silently corrupts the preceding flag

Found while deploying `--cors-origins ""`. The command-line builder dropped empty
arguments outright, so the **next** argument slid into the empty one's place.
The hardening would have been deployed across all five model blocks without
doing what we thought, and reported as done.

It was caught by reading the command line the process was **actually running**,
not by re-reading the script. The fix is one condition:

```powershell
if ($_ -match '\s' -or $_ -eq '') { "`"$_`"" } else { $_ }
```

### Redirected stderr stays empty until the process exits

`llama-server` writes everything to stderr. Redirect it through `cmd.exe` to a
file and the C runtime **fully buffers** it: the file sits at 0 bytes while the
process runs, which defeats exactly the failure diagnostic you wanted it for.

Use llama.cpp's own `--log-file` flag instead. The process flushes it itself and
the file stays readable live. This script does that, and the CUDA one does not,
which is why the CUDA one has an explicit note telling you which log file is the
real one.

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
| [docs/claude-code-integration.md](docs/claude-code-integration.md) | Pointing Claude Code at this server, with an API key |
| [models/qwen3-vl-4b/README.md](models/qwen3-vl-4b/README.md) | The served model and the four measured candidates |
| [clients/](clients/) | The launcher script |

## License

MIT. `llama.cpp` is MIT; model weights carry their own licenses.
