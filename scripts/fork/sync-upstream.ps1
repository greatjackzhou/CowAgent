#Requires -Version 5.1
<#
.SYNOPSIS
    CowAgent fork · 上游同步脚本（Windows / PowerShell 版）

.DESCRIPTION
    把上游 zhayujie/CowAgent 的更新安全并入本 fork：
      1) master 只做 fast-forward，始终保持「上游纯镜像」；
      2) 工作分支 rebase 到最新 master（保持线性历史，冲突面最小）；
      3) 跑 pytest 确认自有改动没有被上游语义改动破坏。

.PARAMETER Branch
    要同步的工作分支，默认 develop。别名 -b

.PARAMETER Check
    只检查上游是否有更新，不做任何改动。别名 -c

.PARAMETER NoTest
    跳过 pytest。别名 -n

.PARAMETER Push
    rebase 成功后用 --force-with-lease 推送工作分支（默认不推）。别名 -p

.PARAMETER UpstreamUrl
    上游仓库地址，默认 https://github.com/zhayujie/CowAgent.git

.PARAMETER Origin
    origin 远端名，默认 origin

.EXAMPLE
    .\scripts\fork\sync-upstream.ps1
    .\scripts\fork\sync-upstream.ps1 -c
    .\scripts\fork\sync-upstream.ps1 -Branch develop -Push

.NOTES
    退出码：0 = 成功（含「上游无新提交」）；1 = 需要人工介入。
    安全约定：
      · 永不自动解决冲突——冲突时中止 rebase 并列出冲突文件，交给人工处理。
      · 永不 force push——除非显式传 -Push（且用的是 --force-with-lease）。
      · master 上永不产生提交——一旦发现 master 领先上游，立即报错退出。
#>
param(
    [Alias("b")]
    [string]$Branch = "develop",

    [Alias("c")]
    [switch]$Check,

    [Alias("n")]
    [switch]$NoTest,

    [Alias("p")]
    [switch]$Push,

    [string]$UpstreamUrl = "https://github.com/zhayujie/CowAgent.git",

    [string]$Origin = "origin",

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ── UTF-8：否则中文在 Windows PowerShell 5.1 下会变乱码 ────────────────
try { chcp 65001 | Out-Null } catch {}
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
} catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

# ── 常量 ──────────────────────────────────────────────────────────────
$MirrorBranch = "master"
$UpstreamRemote = "upstream"

# ── 输出 ──────────────────────────────────────────────────────────────
function Write-Info { param([string]$M) Write-Host ">  $M" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "OK $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "!! $M" -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "XX $M" -ForegroundColor Red }
function Write-Rule { Write-Host ("-" * 64) -ForegroundColor DarkGray }
function Fail {
    param([string]$M)
    Write-Err $M
    exit 1
}

function Show-Usage {
    Write-Host ""
    Write-Host "CowAgent fork · 上游同步脚本" -ForegroundColor Cyan
    Write-Rule
    Write-Host "用法："
    Write-Host "  .\scripts\fork\sync-upstream.ps1 [-Branch <name>] [-Check] [-NoTest] [-Push]"
    Write-Host ""
    Write-Host "选项："
    Write-Host "  -b, -Branch <name>   要同步的工作分支（默认 develop）"
    Write-Host "  -c, -Check           只检查上游是否有更新，不做任何改动"
    Write-Host "  -n, -NoTest          跳过 pytest"
    Write-Host "  -p, -Push            rebase 成功后 --force-with-lease 推送工作分支"
    Write-Host "      -UpstreamUrl <u> 上游地址（默认 $UpstreamUrl）"
    Write-Host "      -Origin <name>   origin 远端名（默认 origin）"
    Write-Host "  -h, -Help            显示本帮助"
    Write-Host ""
    Write-Host "退出码：0 = 成功；1 = 需要人工介入（master 被污染 / 有冲突 / 测试失败）"
    Write-Host ""
}

if ($Help) { Show-Usage; exit 0 }

# ── git 调用封装 ──────────────────────────────────────────────────────
# 运行 git 并捕获输出（不打印），结果放在 $script:GitExit
function Invoke-GitCapture {
    param([string[]]$GitArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        $out = & git @GitArgs 2>&1
        $script:GitExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($null -eq $out) { return "" }
    return (($out | ForEach-Object { "$_" }) -join "`n")
}

# 运行 git 并实时打印输出，返回退出码
function Invoke-GitLive {
    param([string[]]$GitArgs)
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & git @GitArgs 2>&1 | ForEach-Object { Write-Host $_ }
        $script:GitExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    return $script:GitExit
}

function Get-GitCount {
    param([string]$Range)
    $s = Invoke-GitCapture @("rev-list", "--count", $Range)
    $n = 0
    if ([int]::TryParse($s.Trim(), [ref]$n)) { return $n }
    return -1
}

# ── 定位仓库根目录（脚本位于 scripts/fork/ 下）────────────────────────
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Root = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
Set-Location $Root

if (-not (Test-Path (Join-Path $Root ".git"))) { Fail "$Root 不是 git 仓库" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "未找到 git，请先安装 Git for Windows" }

$Mode = if ($Check) { "check" } else { "sync" }

Write-Rule
Write-Host "CowAgent fork · 上游同步   模式=$Mode  仓库=$Root" -ForegroundColor White
Write-Host "  镜像分支=$MirrorBranch  工作分支=$Branch  源=$UpstreamRemote"
Write-Rule

# ── 1. 确保 upstream 远端存在 ─────────────────────────────────────────
$upUrl = Invoke-GitCapture @("remote", "get-url", $UpstreamRemote)
if ($script:GitExit -eq 0 -and $upUrl.Trim()) {
    Write-Ok "upstream 远端已存在：$($upUrl.Trim())"
} else {
    Write-Info "添加 upstream 远端：$UpstreamUrl"
    $null = Invoke-GitLive @("remote", "add", $UpstreamRemote, $UpstreamUrl)
    if ($script:GitExit -ne 0) { Fail "添加 upstream 远端失败" }
    Write-Ok "upstream 远端已添加"
}

# ── 2. 拉取上游 ───────────────────────────────────────────────────────
Write-Info "拉取上游引用（fetch --tags --prune）..."
$null = Invoke-GitCapture @("fetch", $UpstreamRemote, "--tags", "--prune")
if ($script:GitExit -ne 0) {
    Fail "拉取上游失败，请检查网络（国内网络可试 https://gitee.com/zhayujie/CowAgent.git）"
}
Write-Ok "上游引用已更新"

$upRef = "$UpstreamRemote/$MirrorBranch"
$null = Invoke-GitCapture @("rev-parse", "--verify", "--quiet", $upRef)
if ($script:GitExit -ne 0) { Fail "上游不存在 $upRef" }

# ── 3. 校验 master 仍是「上游纯镜像」──────────────────────────────────
$localOnly = Get-GitCount "$upRef..$MirrorBranch"      # 本地领先上游的提交数 → 必须为 0
$behind    = Get-GitCount "$MirrorBranch..$upRef"      # 落后上游的提交数
if ($localOnly -lt 0 -or $behind -lt 0) {
    Fail "无法比较 $MirrorBranch 与 $upRef"
}

if ($localOnly -gt 0) {
    Write-Host ""
    Write-Err "$MirrorBranch 上有 $localOnly 个提交不在上游——镜像已被污染！"
    Write-Err "本脚本拒绝继续。请先把这些提交挪到 $Branch 或 feature 分支："
    Write-Host ""
    Write-Host (Invoke-GitCapture @("log", "--oneline", "--no-merges", "$upRef..$MirrorBranch"))
    Write-Host ""
    Write-Err "参考修复：git checkout $Branch ; git cherry-pick <这些提交> ; git checkout $MirrorBranch ; git reset --hard $upRef"
    exit 1
}
Write-Ok "$MirrorBranch 是上游纯镜像（领先 0 个提交）"

# ── 4. 上游是否有新提交 ───────────────────────────────────────────────
if ($behind -eq 0) {
    Write-Host ""
    $shortUp = (Invoke-GitCapture @("rev-parse", "--short", $upRef)).Trim()
    Write-Ok "上游无新提交，$MirrorBranch 已是最新（$shortUp）"
    Write-Host ""
    Write-Rule
    Write-Host "结论：无需同步。"
    Write-Rule
    exit 0
}

Write-Host ""
Write-Info "上游有 $behind 个新提交："
$logLines = Invoke-GitCapture @("log", "--oneline", "--no-merges", "--date=short", "--pretty=%h %ad %s", "$MirrorBranch..$upRef")
@($logLines -split "`n") | Select-Object -First 40 | ForEach-Object { if ($_.Trim()) { Write-Host "   $($_.Trim())" } }
if ($behind -gt 40) { Write-Host "   ...（仅显示前 40 条）" }
Write-Host ""

if ($Mode -eq "check") {
    Write-Rule
    Write-Host "检查模式：未做任何改动。"
    Write-Host "执行同步： .\scripts\fork\sync-upstream.ps1 -Branch $Branch"
    Write-Rule
    exit 0
}

# ── 5. 前置检查：工作区必须干净 ───────────────────────────────────────
$dirty = Invoke-GitCapture @("status", "--porcelain")
if ($dirty.Trim()) {
    Write-Host ""
    Write-Err "工作区有未提交的改动，rebase 会失败。请先提交或暂存（git stash）："
    Write-Host ""
    @((Invoke-GitCapture @("status", "--short")) -split "`n") | Select-Object -First 30 | ForEach-Object { Write-Host $_ }
    Write-Host ""
    exit 1
}
Write-Ok "工作区干净"

$currentBranch = (Invoke-GitCapture @("rev-parse", "--abbrev-ref", "HEAD")).Trim()
$null = Invoke-GitCapture @("rev-parse", "--verify", "--quiet", $Branch)
if ($script:GitExit -ne 0) { Fail "工作分支 $Branch 不存在" }

$oldMirror = (Invoke-GitCapture @("rev-parse", "--short", $MirrorBranch)).Trim()
$oldWork   = (Invoke-GitCapture @("rev-parse", "--short", $Branch)).Trim()

# ── 6. 快进 master 并推送 ─────────────────────────────────────────────
Write-Host ""
Write-Info "切换到 $MirrorBranch 并快进到上游..."
$null = Invoke-GitCapture @("checkout", $MirrorBranch)
if ($script:GitExit -ne 0) { Fail "切换到 $MirrorBranch 失败" }

$null = Invoke-GitCapture @("merge", "--ff-only", $upRef)
if ($script:GitExit -ne 0) {
    $null = Invoke-GitCapture @("checkout", $currentBranch)
    Fail "fast-forward 失败——$MirrorBranch 可能已被污染，请人工检查"
}
$newMirror = (Invoke-GitCapture @("rev-parse", "--short", $MirrorBranch)).Trim()
Write-Ok "$MirrorBranch ：$oldMirror -> $newMirror"

$null = Invoke-GitCapture @("push", $Origin, $MirrorBranch)
if ($script:GitExit -eq 0) {
    Write-Ok "已推送 $MirrorBranch 到 $Origin"
} else {
    Write-Warn "推送 $MirrorBranch 到 $Origin 失败（远端可能已受保护或网络问题），请手动推送"
}

# ── 7. rebase 工作分支 ────────────────────────────────────────────────
Write-Host ""
Write-Info "rebase $Branch 到 $MirrorBranch ..."
$null = Invoke-GitCapture @("checkout", $Branch)
if ($script:GitExit -ne 0) { Fail "切换到 $Branch 失败" }

$workLocal = Get-GitCount "$MirrorBranch..$Branch"
if ($workLocal -gt 0) {
    Write-Info "$Branch 上有 $workLocal 个自有提交需要被 rebase 到新基线"
} else {
    Write-Info "$Branch 无自有提交，将直接跟上游对齐"
}

# rebase 需要实时看到进度，所以用 Live 形式；冲突信息随后再取
$old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    & git rebase $MirrorBranch 2>&1 | ForEach-Object { Write-Host $_ }
    $rebaseRc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $old
}

if ($rebaseRc -ne 0) {
    Write-Host ""
    Write-Err "rebase 冲突或被拒绝，本脚本不会自动解决。"

    $conflicts = Invoke-GitCapture @("diff", "--name-only", "--diff-filter=U")
    if ($conflicts.Trim()) {
        Write-Host ""
        Write-Err "冲突文件："
        @($conflicts -split "`n") | ForEach-Object { if ($_.Trim()) { Write-Host "   $($_.Trim())" } }
    }

    # 还原现场：中止 rebase，保证仓库回到可预期状态
    $null = Invoke-GitCapture @("rebase", "--abort")
    Write-Host ""
    Write-Info "已中止 rebase 以还原现场（git rebase --abort）。手工同步步骤："
    Write-Host "   1) .\scripts\fork\sync-upstream.ps1 -c                      # 确认上游更新"
    Write-Host "   2) git checkout $MirrorBranch ; git merge --ff-only $upRef"
    Write-Host "   3) git checkout $Branch ; git rebase $MirrorBranch          # 手工解冲突"
    Write-Host "   4) git rebase --continue ; .\scripts\fork\sync-upstream.ps1 -NoTest"
    Write-Host ""
    Write-Rule
    Write-Host "结论：需要人工介入（冲突）" -ForegroundColor Red
    Write-Rule
    exit 1
}

$newWork = (Invoke-GitCapture @("rev-parse", "--short", $Branch)).Trim()
Write-Ok "$Branch ：$oldWork -> $newWork"

# ── 8. 推送工作分支（可选）────────────────────────────────────────────
if ($Push) {
    Write-Info "推送 $Branch 到 $Origin（--force-with-lease）..."
    $rc = Invoke-GitLive @("push", "--force-with-lease", $Origin, $Branch)
    if ($rc -eq 0) { Write-Ok "已推送 $Branch" } else { Write-Warn "推送 $Branch 失败，请人工检查" }
} else {
    Write-Warn "未推送 $Branch（rebase 改写了历史）。确认无误后执行："
    Write-Host "   git push --force-with-lease $Origin $Branch"
}

# ── 9. 跑测试 ─────────────────────────────────────────────────────────
$testRc = 0
if (-not $NoTest) {
    Write-Host ""
    $py = $null
    foreach ($c in @("python3", "python", "py")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { $py = $c; break }
    }
    if (-not $py) {
        Write-Warn "未找到 Python，跳过测试（请手工运行 pytest tests/ -q）"
    } else {
        $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { & $py -m pytest --version *> $null; $hasPytest = ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $old }

        if (-not $hasPytest) {
            Write-Warn "未安装 pytest，跳过测试（安装：$py -m pip install pytest）"
        } else {
            Write-Info "运行测试：$py -m pytest tests/ -q"
            $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try {
                & $py -m pytest tests/ -q
                $testRc = $LASTEXITCODE
            } finally { $ErrorActionPreference = $old }

            if ($testRc -eq 0) {
                Write-Ok "测试全部通过"
            } else {
                Write-Err "测试失败（退出码 $testRc）——自有改动很可能与上游语义撞了。"
                Write-Info "排查思路：git range-diff $MirrorBranch...$Branch 看补丁是否被上游改写"
            }
        }
    }
}

# ── 10. 汇总 ──────────────────────────────────────────────────────────
$mBehind = Get-GitCount "$Branch..$upRef"
$mAhead  = Get-GitCount "$upRef..$Branch"

Write-Host ""
Write-Rule
Write-Host "同步汇总" -ForegroundColor White
Write-Host "  $MirrorBranch : $oldMirror -> $newMirror   （跟随上游 $behind 个提交）"
Write-Host "  $Branch : $oldWork -> $newWork"
Write-Host "  与上游差距 : $mBehind 落后 / $mAhead 领先"
if (-not $NoTest) {
    if ($testRc -eq 0) { Write-Host "  测试 : 通过" -ForegroundColor Green }
    else { Write-Host "  测试 : 失败" -ForegroundColor Red }
}
Write-Rule

if ($testRc -ne 0) {
    Write-Host "结论：同步已完成，但测试未通过，请人工处理。" -ForegroundColor Red
    exit 1
}
Write-Host "结论：同步成功。" -ForegroundColor Green
exit 0
