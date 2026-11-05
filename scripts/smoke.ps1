# MDiary 冒烟测试：把验收清单里「自动可测」的启动项跑一遍
#
# 用法：powershell -ExecutionPolicy Bypass -File scripts\smoke.ps1 [-Exe <path>] [-KeepData]
# 默认用构建产物；检查：能启动、能建库（db\mdiary.sqlite）、单实例互斥生效。
param(
    [string]$Exe = '',
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Exe)) {
    $Exe = Join-Path $root 'apps\client_flutter\build\windows\x64\runner\Release\mdiary.exe'
}
if (-not (Test-Path $Exe)) {
    throw "找不到可执行文件：$Exe（先跑 scripts\build.ps1）"
}

$releasedDir = Split-Path -Parent $Exe
$dataDir = Join-Path $releasedDir 'MDiaryData'
$dbFile = Join-Path $dataDir 'db\mdiary.sqlite'
$failures = New-Object System.Collections.Generic.List[string]

function Stop-MDiary {
    Get-Process -Name 'mdiary' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
}

Write-Host "==> 冒烟测试: $Exe" -ForegroundColor Cyan
Stop-MDiary
if (-not $KeepData) {
    Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 1) 启动后能建库
$proc = Start-Process -FilePath $Exe -PassThru
$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline -and -not (Test-Path $dbFile)) {
    Start-Sleep -Milliseconds 400
}
if (Test-Path $dbFile) {
    Write-Host '    [OK] 启动并生成 db\mdiary.sqlite' -ForegroundColor Green
} else {
    $failures.Add('启动 40 秒内没有生成 db\mdiary.sqlite')
}

# 2) 单实例：第二个进程应立刻退出
$second = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 3
$running = @(Get-Process -Name 'mdiary' -ErrorAction SilentlyContinue)
if ($running.Count -eq 1) {
    Write-Host '    [OK] 单实例互斥（第二次启动已退出）' -ForegroundColor Green
} else {
    $failures.Add("单实例互斥失败：当前有 $($running.Count) 个 mdiary 进程")
}

Stop-MDiary
if (-not $KeepData) {
    Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host '==> 冒烟失败:' -ForegroundColor Red
    foreach ($item in $failures) { Write-Host "    - $item" -ForegroundColor Red }
    exit 1
}
Write-Host '==> 冒烟通过' -ForegroundColor Green
