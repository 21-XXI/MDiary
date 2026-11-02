# MDiary 提交前校验：analyze -> test -> build（任一失败即中止）
param(
    [switch]$SkipBuild,
    [switch]$SkipTest
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

    if (-not $SkipBuild) {
        Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Release 构建失败" }
        $exe = Join-Path $app 'build\windows\x64\runner\Release\mdiary.exe'
        if (-not (Test-Path $exe)) { throw "未找到产物: $exe" }
        Write-Host "==> 产物: $exe" -ForegroundColor Green
    }

    Write-Host "==> 全部通过" -ForegroundColor Green
}
finally {
    Pop-Location
}
