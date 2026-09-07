# Prerequisites

## Server side, Windows

### Hardware

| | Used here |
|---|---|
| GPU | AMD Radeon RX 5700 XT, 8 GB, driver 32.0.21045.5002 |
| OS | Windows 11 |

Any Vulkan-capable GPU works. The 8 GB budget is what dictates the model sizes
below: at Q4_K_M a 4B model with a vision projector and a `q4_0` KV cache fits an
81,920-token window with room to spare, and that is roughly the ceiling here.

### Software

**No build toolchain.** This box runs the official prebuilt `llama.cpp` Vulkan
release, `b10603`, unzipped into `llama-cpp-vulkan`. On an 8 GB card a custom
build buys nothing, and Vulkan needs neither CUDA nor Visual Studio.

That is the practical difference with the [CUDA sibling](../../llm-station-cuda),
where three separate builds are needed and one of them is mandatory. If you are
starting out, start here.

You need:

- A recent AMD (or other Vulkan-capable) driver. A driver update fixed a blocking
  defect on this machine, so update before diagnosing anything else.
- The prebuilt Vulkan release of `llama.cpp`.
- PowerShell 5.1 or later, present by default.

### Model weights

GGUF format, from the usual public repositories. Nothing here downloads weights
for you.

## Client side, macOS

- Claude Code
- An SSH key authorised on the Windows box, non-interactive
- `curl`

## Configuration

Two environment variables on the server, both optional:

| Variable | Purpose | Default |
|---|---|---|
| `LLM_ROOT_DIR` | Where the binaries, logs and instance files live | `D:\LLM-Setup` |
| `LLM_MODELS_DIR` | Where the GGUF weights live | `D:\models` |

Set neither and the defaults above apply. No key is involved: the server runs
without `--api-key`, and the client needs no credential. See the security section
of the [main README](../README.md) for what that leaves open and how to put a key
back if your network calls for one.

The script tracks what it started under `$LLM_ROOT_DIR\instances\`, one JSON file
per running instance, created on start and removed on stop. Nothing else reads
those files, so deleting one by hand only loses the tracking, never the process:
`-Action stop` without `-Name` still kills every `llama-server` it finds.

## One thing to check before benchmarking

Two 9B models are barred on this box in the comments of `llm-ctl.ps1`. One of
them **froze the entire machine** during a measurement campaign, and only a
physical power cycle recovered it. On a card this size, a model that does not fit
does not always fail cleanly.
