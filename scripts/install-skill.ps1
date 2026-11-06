# 把 MDiary skill 安装到 agent 的 skills 目录（默认 DSH）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source skills\diary-segmenter
#   powershell -ExecutionPolicy Bypass -File scripts\install-skill.ps1 -Source <dir> -Target <skills 目录>
#
# 会校验 SKILL.md 的 YAML front matter（name + description），再整目录复制过去。
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Name = '',
    [string]$Target = ''
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Source)) { throw "找不到 skill 目录：$Source" }
$skillFile = Join-Path $Source 'SKILL.md'
if (-not (Test-Path $skillFile)) { throw "目录里没有 SKILL.md：$Source" }

$content = Get-Content $skillFile -Raw -Encoding UTF8
if ($content -notmatch '(?m)^---\s*$') {
    throw 'SKILL.md 缺少 YAML front matter（需要 --- name/description ---）'
}
$nameMatch = [regex]::Match($content, '(?m)^name:\s*(\S+)\s*$')
$descMatch = [regex]::Match($content, '(?m)^description:\s*\S')
if (-not $nameMatch.Success) { throw 'front matter 缺少 name' }
if (-not $descMatch.Success) { throw 'front matter 缺少 description' }

if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $nameMatch.Groups[1].Value }
if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = Join-Path $env:USERPROFILE '.dsh\skills'
}

New-Item -ItemType Directory -Path $Target -Force | Out-Null
$dest = Join-Path $Target $Name
if (Test-Path $dest) {
    Remove-Item $dest -Recurse -Force
}
Copy-Item $Source $dest -Recurse -Force

Write-Host "==> 已安装 skill" -ForegroundColor Green
Write-Host "    $dest"
Write-Host "    重启 agent（如 DSH）后，skill 目录里会多出「$Name」。" -ForegroundColor Cyan
