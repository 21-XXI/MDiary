# 测量本地 Ollama 模型（默认 qwen3:8b）的推理与 embedding 性能
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -Model qwen3:4b -Runs 5
#   powershell -ExecutionPolicy Bypass -File scripts\bench-ollama.ps1 -SkipEmbed
#
# 输出：控制台表格 + bench-ollama.json（同目录）
param(
    [string]$Model = 'qwen3:8b',
    [string]$EmbedModel = 'bge-m3',
    [int]$Runs = 3,
    [switch]$SkipEmbed,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
$baseUrl = 'http://127.0.0.1:11434'

function Get-OllamaModels {
    try {
        $tags = Invoke-RestMethod -Uri "$baseUrl/api/tags" -TimeoutSec 5
        return @($tags.models | ForEach-Object { $_.name })
    } catch {
        return @()
    }
}

function Wait-Ollama([int]$seconds = 60) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-OllamaModels).Count -gt 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Ensure-Model([string]$name) {
    $models = Get-OllamaModels
    $match = $models | Where-Object { $_ -eq $name -or $_ -like "$name*" }
    if ($match) { return $true }
    Write-Host "==> 拉取模型 $name（首次会比较久）" -ForegroundColor Cyan
    & ollama pull $name
    return $LASTEXITCODE -eq 0
}

function Invoke-Chat([string]$prompt, [string]$model) {
    $body = @{
        model    = $model
        stream   = $false
        messages = @(@{ role = 'user'; content = $prompt })
        options  = @{ temperature = 0.3; num_predict = 256 }
    } | ConvertTo-Json -Depth 6
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/chat" `
        -Body $body -ContentType 'application/json' -TimeoutSec 900
    $watch.Stop()
    $wall = $watch.Elapsed.TotalSeconds
    $evalSeconds = [math]::Max($response.eval_duration / 1e9, 0.0001)
    $promptSeconds = [math]::Max($response.prompt_eval_duration / 1e9, 0.0001)
    return [pscustomobject]@{
        wall_s        = [math]::Round($wall, 2)
        load_s        = [math]::Round($response.load_duration / 1e9, 2)
        prompt_tokens = [int]$response.prompt_eval_count
        out_tokens    = [int]$response.eval_count
        tok_per_s     = [math]::Round($response.eval_count / $evalSeconds, 2)
        prefill_tok_s = [math]::Round($response.prompt_eval_count / $promptSeconds, 2)
        text_chars    = ($response.message.content | Measure-Object -Character).Characters
    }
}

function Invoke-ChatStream([string]$prompt, [string]$model) {
    $body = @{
        model    = $model
        stream   = $true
        messages = @(@{ role = 'user'; content = $prompt })
        options  = @{ temperature = 0.3; num_predict = 256 }
    } | ConvertTo-Json -Depth 6
    $request = [System.Net.HttpWebRequest]::Create("$baseUrl/api/chat")
    $request.Method = 'POST'
    $request.ContentType = 'application/json'
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $request.ContentLength = $bytes.Length
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $stream = $request.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $response = $request.GetResponse()
    $reader = New-Object IO.StreamReader($response.GetResponseStream())
    $firstToken = $null
    $chunks = 0
    while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $chunks++
        if ($null -eq $firstToken) { $firstToken = $watch.Elapsed.TotalSeconds }
    }
    $watch.Stop()
    $reader.Close()
    $response.Close()
    $ttft = if ($null -eq $firstToken) { $null } else { [math]::Round($firstToken, 2) }
    return [pscustomobject]@{
        ttft_s   = $ttft
        total_s  = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        chunks   = $chunks
    }
}

function Invoke-Embed([string]$model, [string[]]$texts) {
    $body = @{ model = $model; input = $texts } | ConvertTo-Json -Depth 4
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/embed" `
        -Body $body -ContentType 'application/json' -TimeoutSec 300
    $watch.Stop()
    $seconds = [math]::Max($watch.Elapsed.TotalSeconds, 0.001)
    $dim = if ($response.embeddings.Count -gt 0) { $response.embeddings[0].Count } else { 0 }
    return [pscustomobject]@{
        count     = $texts.Count
        dim       = $dim
        total_s   = [math]::Round($seconds, 2)
        per_text  = [math]::Round($seconds / $texts.Count, 3)
        texts_s   = [math]::Round($texts.Count / $seconds, 2)
    }
}

# ── 环境信息 ─────────────────────────────────────────────
Write-Host "==> 环境" -ForegroundColor Cyan
$cpu = (Get-CimInstance Win32_Processor).Name
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$gpu = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null
Write-Host "    CPU: $cpu"
Write-Host "    RAM: $ram GB"
Write-Host "    GPU: $gpu"
$ollamaVersion = (& ollama --version 2>&1 | Out-String).Trim()
Write-Host "    Ollama: $ollamaVersion"

if (-not (Wait-Ollama 30)) {
    Write-Host "==> Ollama 没在运行，尝试启动 serve" -ForegroundColor Yellow
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    if (-not (Wait-Ollama 60)) { throw 'Ollama 服务启动失败' }
}

if (-not (Ensure-Model $Model)) { throw "模型 $Model 拉取失败" }

# 预热（第一次包含加载模型，单独记录）
Write-Host "==> 预热与加载" -ForegroundColor Cyan
$warmup = Invoke-Chat '用一句话介绍你自己。' $Model
Write-Host ("    首次调用：{0}s（其中加载 {1}s），{2} tok/s" -f $warmup.wall_s, $warmup.load_s, $warmup.tok_per_s)

$ps = (& ollama ps 2>&1 | Out-String).Trim()
Write-Host "    ollama ps:"
$ps -split "`n" | ForEach-Object { Write-Host "      $_" }

$gpuMem = (& nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>$null)

# ── 推理基准 ─────────────────────────────────────────────
$prompts = @(
    '用三句话总结：今天整理了旧照片，发现 2019 年在杭州的照片，想起那次出差。',
    '把下面这段日记改写成 3 条待办：明天要交周报、给妈妈打电话、买猫粮、预约牙医。',
    '根据这些片段写一段 80 字的中文日记：下雨、没带伞、路边桂花很香、回家煮了面。'
)

$rows = @()
Write-Host "==> 推理基准（$Model，$Runs 轮）" -ForegroundColor Cyan
for ($i = 0; $i -lt $Runs; $i++) {
    foreach ($prompt in $prompts) {
        $row = Invoke-Chat $prompt $Model
        $row | Add-Member -NotePropertyName prompt -NotePropertyValue $prompt.Substring(0, [math]::Min(18, $prompt.Length))
        $rows += $row
        Write-Host ("    [{0}] {1} tok/s · 总 {2}s · 输出 {3} tok" -f $row.prompt, $row.tok_per_s, $row.wall_s, $row.out_tokens)
    }
}

$avgTok = [math]::Round(($rows | Measure-Object tok_per_s -Average).Average, 2)
$avgWall = [math]::Round(($rows | Measure-Object wall_s -Average).Average, 2)
$avgOut = [math]::Round(($rows | Measure-Object out_tokens -Average).Average, 1)

Write-Host "==> 流式首 token（TTFT）" -ForegroundColor Cyan
$stream = Invoke-ChatStream '用两句话介绍一下日记应用的价值。' $Model
Write-Host ("    TTFT {0}s · 总 {1}s · {2} 个分片" -f $stream.ttft_s, $stream.total_s, $stream.chunks)

# ── Embedding ────────────────────────────────────────────
$embed = $null
if (-not $SkipEmbed -and (Ensure-Model $EmbedModel)) {
    Write-Host "==> Embedding 基准（$EmbedModel）" -ForegroundColor Cyan
    $texts = @(
        '今天去了西湖，风很大。',
        '把发票整理好了，住宿费 380 元。',
        '明天要交周报、给妈妈打电话、买猫粮。',
        '下雨、没带伞、路边桂花很香。',
        '读完《长安的荔枝》，想起职场里的那些事。',
        '周末煮了咖啡，阳光很好。',
        '体检报告出来了，指标都正常。',
        '车票订好了，周五出发。'
    )
    $embed = Invoke-Embed $EmbedModel $texts
    Write-Host ("    {0} 条 / {1}s · {2} 条/s · 维度 {3}" -f $embed.count, $embed.total_s, $embed.texts_s, $embed.dim)
}

# ── 汇总 ─────────────────────────────────────────────────
$summary = [pscustomobject]@{
    time          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    model         = $Model
    cpu           = $cpu
    ram_gb        = $ram
    gpu           = $gpu
    ollama        = $ollamaVersion
    ollama_ps     = $ps
    gpu_mem_used  = $gpuMem
    load_seconds  = $warmup.load_s
    avg_tok_s     = $avgTok
    avg_wall_s    = $avgWall
    avg_out_tok   = $avgOut
    ttft_s        = $stream.ttft_s
    runs          = $rows
    embed         = $embed
}

Write-Host "==> 汇总" -ForegroundColor Green
Write-Host ("    {0}：平均 {1} tok/s，平均 {2}s/次，TTFT {3}s" -f $Model, $avgTok, $avgWall, $stream.ttft_s)
if ($embed) {
    Write-Host ("    {0}：{1} 条/s，维度 {2}" -f $EmbedModel, $embed.texts_s, $embed.dim)
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'bench-ollama.json'
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "    结果已写入 $OutFile"
