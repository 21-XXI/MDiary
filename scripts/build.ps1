# MDiary Windows Release 构建
#
# 背景：Flutter 的 Windows 构建链（CMake -> MSBuild）在处理含中文的工程路径时
# 会按 ANSI(GBK) 转码，导致 `Unable to read file ...\app.dill` 之类的失败。
# 因此当仓库路径含非 ASCII 字符时，本脚本自动建立一个 ASCII 目录联接（junction）
# 并从中构建；仓库本身的位置、Git 历史都不受影响。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$appRelative = 'apps\client_flutter'
$LinkPath = 'C:\mdiary_build'

$isAscii = $repo -match '^[\x20-\x7E]+$'
if ($isAscii) {
    $buildRoot = $repo
    Write-Host "==> 构建路径: $buildRoot" -ForegroundColor Cyan
}
else {
    $buildRoot = $LinkPath
    Write-Host "==> 仓库路径含非 ASCII 字符，使用联接: $LinkPath -> $repo" -ForegroundColor Yellow
    if (Test-Path $LinkPath) {
        $existing = (Get-Item $LinkPath).Target
        if ($existing -and ($existing -ne $repo)) {
            cmd /c "rmdir `"$LinkPath`"" | Out-Null
        }
    }
    if (-not (Test-Path $LinkPath)) {
        cmd /c "mklink /J `"$LinkPath`" `"$repo`"" | Out-Null
        if (-not (Test-Path $LinkPath)) { throw "创建目录联接失败: $LinkPath" }
    }
}

Push-Location (Join-Path $buildRoot $appRelative)
try {
    if ($Clean) {
        Write-Host "==> flutter clean" -ForegroundColor Cyan
        flutter clean
    }

    Write-Host "==> flutter pub get" -ForegroundColor Cyan
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败' }

    Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Release 构建失败' }

    $exe = Join-Path (Get-Location) 'build\windows\x64\runner\Release\mdiary.exe'
    if (-not (Test-Path $exe)) { throw "未找到产物: $exe" }

    $sizeMb = [math]::Round(((Get-ChildItem (Split-Path $exe) -File | Measure-Object Length -Sum).Sum / 1MB), 1)
    Write-Host "==> 构建成功" -ForegroundColor Green
    Write-Host "    程序: $exe"
    Write-Host "    目录大小: $sizeMb MB（含 data/ 与 flutter_windows.dll，需整体分发）"
}
finally {
    Pop-Location
}
