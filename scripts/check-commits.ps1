# 提交规范检查：确认最近 N 条提交按 .gitmessage 模板写了审查意见
#
# 用法：powershell -ExecutionPolicy Bypass -File scripts\check-commits.ps1 [-Count 10]
# 退出码：0 全部合规；1 存在缺失段落的提交
#
# 实现说明：不用 `git log --format=%B` 再在 PowerShell 里做字符串匹配 ——
# Windows PowerShell 5.1 读原生命令输出时按控制台代码页解码，中文会变乱码，
# 导致「明明写了却匹配不到」。这里改用 `git log --grep`，让 Git 自己比对字节。
param(
    [int]$Count = 10
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$repo = Split-Path -Parent $PSScriptRoot
$required = @('改动', '原因', '风险', '验证', '回滚')

$hashes = & git -C $repo log -n $Count --format='%H'
if ($LASTEXITCODE -ne 0 -or -not $hashes) {
    Write-Host "读取 Git 历史失败：确认 $repo 是 Git 仓库" -ForegroundColor Red
    exit 1
}

$failed = 0
foreach ($hash in $hashes) {
    $short = $hash.Substring(0, 7)
    $subject = & git -C $repo log -1 --format='%s' $hash
    $missing = @()
    foreach ($section in $required) {
        $hit = & git -C $repo log -1 --format='%H' $hash --grep="$section"
        if (-not $hit) { $missing += $section }
    }
    if ($missing.Count -gt 0) {
        $failed++
        Write-Host ("FAIL {0} {1}" -f $short, $subject) -ForegroundColor Red
        Write-Host ("       缺少：{0}" -f ($missing -join '、')) -ForegroundColor Red
    }
    else {
        Write-Host ("OK   {0} {1}" -f $short, $subject) -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host ("{0}/{1} 条提交不符合模板，请按 .gitmessage 补齐后 amend" -f $failed, $hashes.Count) -ForegroundColor Red
    exit 1
}
Write-Host ("最近 {0} 条提交全部符合 .gitmessage 模板（改动/原因/风险/验证/回滚）" -f $hashes.Count) -ForegroundColor Green
