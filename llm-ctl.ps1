<#
.SYNOPSIS
  Controls the local LLM server (llama-server, Vulkan backend) on this machine.

.DESCRIPTION
  Models are mutually exclusive on the GPU: starting one always frees the port
  first. Each model block below defines its own exe, arguments and port.
  Adding a new model is just adding one entry to $Models.

  The error log is written via llama-server's own --log-file flag, not via
  shell "2>" redirection: when its stderr is redirected through cmd.exe to a
  file, the process's C runtime fully buffers it and the file stays at 0
  bytes until the process exits, which defeats the FAILED diagnostic below.
  --log-file is flushed by the process itself and stays readable while it runs.

.PARAMETER Action
  Either the name of a model to start (see $Models.Keys), or "status", or "stop".
#>
param(
  [Parameter(Mandatory=$true)][string]$Action
)

$ErrorActionPreference = "Stop"
$RootDir = if ($env:LLM_ROOT_DIR) { $env:LLM_ROOT_DIR } else { "D:\LLM-Setup" }
$StateFile = Join-Path $RootDir "llm-state.json"

# Shared by every model block below. Without it, any web page open on any
# machine of the LAN can query this server behind its user's back: a firewall
# does not protect against that case, because the request originates from
# inside the network. Combined with --cors-origins "" it closes the browser
# path entirely.
#
# Read from the environment so it never lands in version control. Generate one
# with: openssl rand -base64 24
# The same value must be set on every client that talks to this server.
$ApiKey = $env:LLM_API_KEY

$Models = @{
  "qwen3vl4b" = @{
    Exe     = Join-Path $RootDir "llama-cpp-vulkan\llama-server.exe"
    WorkDir = $RootDir
    Port    = 8080
    Args    = @(
      "-m", "D:\models\qwen3-vl-4b\Qwen3VL-4B-Instruct-Q4_K_M.gguf",
      "--mmproj", "D:\models\qwen3-vl-4b\mmproj-Qwen3VL-4B-Instruct-F16.gguf",
      "-ngl", "99",
      "-c", "81920",
      "-b", "2048",
      "-ub", "512",
      "--cache-type-k", "q4_0",
      "--cache-type-v", "q4_0",
      "--no-mmap",
      "--mlock",
      "--chat-template-file", "D:\models\qwen3-vl-4b\chat-template-system-anywhere.jinja",
      "--host", "0.0.0.0",
      "--port", "8080",
      "--log-colors", "off",
      "--api-key", $ApiKey,
      "--cors-origins", ""
    )
  }
  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Reasoning model: add "chat_template_kwargs": {"enable_thinking": false} to
  # the /v1/messages request to get usable short-dialogue latency, otherwise it
  # spends its whole budget thinking before answering.
  "qwen38distill" = @{
    Exe     = Join-Path $RootDir "llama-cpp-vulkan\llama-server.exe"
    WorkDir = $RootDir
    Port    = 8080
    Args    = @(
      "-m", "D:\models\qwen38-4b-distill\Qwen3.8-4B-Distill.i1-Q4_K_M.gguf",
      "--mmproj", "D:\models\qwen38-4b-distill\Qwen3.8-4B-Distill.mmproj-f16.gguf",
      "-ngl", "99",
      "-c", "262144",
      "-b", "2048",
      "-ub", "512",
      "--cache-type-k", "q4_0",
      "--cache-type-v", "q4_0",
      "--no-mmap",
      "--mlock",
      "--chat-template-file", "D:\models\qwen38-4b-distill\chat-template-system-anywhere.jinja",
      "--host", "0.0.0.0",
      "--port", "8080",
      "--log-colors", "off",
      "--api-key", $ApiKey,
      "--cors-origins", ""
    )
  }
  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Exact little brother of qwen3vl4b: same family, same patched chat template.
  "qwen3vl2b" = @{
    Exe     = Join-Path $RootDir "llama-cpp-vulkan\llama-server.exe"
    WorkDir = $RootDir
    Port    = 8080
    Args    = @(
      "-m", "D:\models\qwen3-vl-2b\Qwen3-VL-2B-Instruct-Q4_K_M.gguf",
      "--mmproj", "D:\models\qwen3-vl-2b\mmproj-F16.gguf",
      "-ngl", "99",
      "-c", "114688",
      "-b", "2048",
      "-ub", "512",
      "--cache-type-k", "q4_0",
      "--cache-type-v", "q4_0",
      "--no-mmap",
      "--mlock",
      "--chat-template-file", "D:\models\qwen3-vl-2b\chat-template-system-anywhere.jinja",
      "--host", "0.0.0.0",
      "--port", "8080",
      "--log-colors", "off",
      "--api-key", $ApiKey,
      "--cors-origins", ""
    )
  }
  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Its native chat template is already correct: a late system message is
  # rendered as an ordinary turn by construction, so no --chat-template-file is
  # needed here, unlike every Qwen model on this box.
  "lfm16" = @{
    Exe     = Join-Path $RootDir "llama-cpp-vulkan\llama-server.exe"
    WorkDir = $RootDir
    Port    = 8080
    Args    = @(
      "-m", "D:\models\lfm2.5-vl-1.6b\LFM2.5-VL-1.6B-F16.gguf",
      "--mmproj", "D:\models\lfm2.5-vl-1.6b\mmproj-LFM2.5-VL-1.6b-F16.gguf",
      "-ngl", "99",
      "-c", "128000",
      "-b", "2048",
      "-ub", "512",
      "--cache-type-k", "q4_0",
      "--cache-type-v", "q4_0",
      "--no-mmap",
      "--mlock",
      "--host", "0.0.0.0",
      "--port", "8080",
      "--log-colors", "off",
      "--api-key", $ApiKey,
      "--cors-origins", ""
    )
  }
  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Unquantised F16 weights: here the context ceiling is set by the size of the
  # weights themselves, not by the marginal cost of the KV cache.
  "lfm3b" = @{
    Exe     = Join-Path $RootDir "llama-cpp-vulkan\llama-server.exe"
    WorkDir = $RootDir
    Port    = 8080
    Args    = @(
      "-m", "D:\models\lfm2.5-vl-3b\LFM2.5-VL-3B-F16.gguf",
      "--mmproj", "D:\models\lfm2.5-vl-3b\mmproj-LFM2.5-VL-3B-F16.gguf",
      "-ngl", "99",
      "-c", "49152",
      "-b", "2048",
      "-ub", "512",
      "--cache-type-k", "q4_0",
      "--cache-type-v", "q4_0",
      "--no-mmap",
      "--mlock",
      "--host", "0.0.0.0",
      "--port", "8080",
      "--log-colors", "off",
      "--api-key", $ApiKey,
      "--cors-origins", ""
    )
  }
}

function Get-TrackedProcess {
  if (-not (Test-Path $StateFile)) { return $null }
  try {
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid) AND Name='llama-server.exe'" -ErrorAction SilentlyContinue
  if ($proc) {
    return [PSCustomObject]@{ Name = $state.name; Pid = $state.pid; Port = $state.port; Process = $proc }
  }
  return $null
}

function Stop-CurrentServer {
  $tracked = Get-TrackedProcess
  if ($tracked) {
    Stop-Process -Id $tracked.Pid -Force -ErrorAction SilentlyContinue
  }
  # Also free the port from any untracked llama-server.exe instance.
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Remove-Item $StateFile -ErrorAction SilentlyContinue
}

switch ($Action) {

  "status" {
    $tracked = Get-TrackedProcess
    if ($tracked) {
      Write-Host "RUNNING name=$($tracked.Name) pid=$($tracked.Pid) port=$($tracked.Port)"
    } else {
      Write-Host "STOPPED"
    }
    break
  }

  "stop" {
    Stop-CurrentServer
    Write-Host "STOPPED"
    break
  }

  default {
    $modelName = $Action
    if (-not $Models.ContainsKey($modelName)) {
      Write-Host "FAILED: unknown model '$modelName'. Known models: $($Models.Keys -join ', ')"
      exit 1
    }
    $model = $Models[$modelName]

    Stop-CurrentServer

    $outLog = Join-Path $RootDir "llm-out-$modelName.log"
    $errLog = Join-Path $RootDir "llm-err-$modelName.log"
    Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

    $fullArgs = $model.Args + @("--log-file", $errLog)
    # Quote whitespace-containing args, and an empty string too (an empty arg
    # left unquoted vanishes from the joined command line instead of being
    # passed through, which silently corrupts the preceding flag's value).
    $quoted = ($fullArgs | ForEach-Object { if ($_ -match '\s' -or $_ -eq '') { "`"$_`"" } else { $_ } }) -join ' '
    $inner = "cd /d `"$($model.WorkDir)`" && `"$($model.Exe)`" $quoted > `"$outLog`""
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
      CommandLine     = "cmd.exe /c $inner"
      CurrentDirectory = $model.WorkDir
    }
    if ($r.ReturnValue -ne 0) {
      Write-Host "FAILED: Win32_Process.Create returned $($r.ReturnValue)"
      exit 1
    }

    # Resolve the real llama-server.exe PID (cmd.exe is just the launcher).
    $real = $null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 500
      $real = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.ProcessId) AND Name='llama-server.exe'"
      if ($real) { break }
    }
    if (-not $real) {
      Write-Host "FAILED: llama-server.exe did not start"
      Write-Host "---"
      Get-Content $errLog -Tail 20 -ErrorAction SilentlyContinue
      exit 1
    }

    # Wait for the HTTP health endpoint before declaring success.
    $ready = $false
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
      try {
        $h = Invoke-WebRequest -Uri "http://127.0.0.1:$($model.Port)/health" -UseBasicParsing -TimeoutSec 3
        if ($h.StatusCode -eq 200) { $ready = $true; break }
      } catch {}
      Start-Sleep -Seconds 1
    }
    if (-not $ready) {
      Write-Host "FAILED: health check timeout"
      Write-Host "---"
      Get-Content $errLog -Tail 30 -ErrorAction SilentlyContinue
      exit 1
    }

    @{ name = $modelName; pid = $real.ProcessId; port = $model.Port } | ConvertTo-Json | Set-Content $StateFile
    Write-Host "STARTED name=$modelName pid=$($real.ProcessId) port=$($model.Port)"
  }
}

