# MDiary 提交前校验：analyze -> test -> build（任一失败即中止）
#
# 用法：powershell -ExecutionPolicy Bypass -File scripts\verify.ps1 [-SkipBuild] [-SkipTest] [-SkipSmoke]
param(
    [switch]$SkipBuild,
    [switch]$SkipTest,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'apps\client_flutter'

Write-Host "==> 工作区: $app" -ForegroundColor Cyan
Push-Location $app
try {
    Write-Host "==> flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "pub get 失败" }

    Write-Host "==> flutter analyze" -ForegroundColor Cyan
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw "analyze 未通过（要求 0 issue）" }

    if (-not $SkipTest) {
        Write-Host "==> flutter test" -ForegroundColor Cyan
        flutter test
        if ($LASTEXITCODE -ne 0) { throw "单元测试未通过" }
    }
}
finally {
    Pop-Location
}

if (-not $SkipBuild) {
    # 交给 build.ps1：由它处理「中文路径 -> ASCII 目录联接」的问题
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Release 构建失败" }
}

if (-not $SkipSmoke) {
    & (Join-Path $PSScriptRoot 'smoke.ps1')
    if ($LASTEXITCODE -ne 0) { throw "冒烟测试未通过" }
}

Write-Host "==> 全部通过" -ForegroundColor Green
