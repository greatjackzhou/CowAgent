#!/usr/bin/env bash
# =====================================================================
#  CowAgent fork · 上游同步脚本 (sync-upstream.sh)
# ---------------------------------------------------------------------
#  把上游 zhayujie/CowAgent 的更新安全并入本 fork：
#    1) master 只做 fast-forward，始终保持「上游纯镜像」；
#    2) 工作分支 rebase 到最新 master（保持线性历史，冲突面最小）；
#    3) 跑 pytest 确认自有改动没有被上游语义改动破坏。
#
#  用法：
#      bash scripts/fork/sync-upstream.sh            # 完整同步
#      bash scripts/fork/sync-upstream.sh -c         # 只检查，不改动
#      bash scripts/fork/sync-upstream.sh -b develop -p
#
#  选项：
#      -b, --branch <name>      要同步的工作分支（默认 develop）
#      -c, --check              只检查上游是否有更新，不做任何改动
#      -n, --no-test            跳过 pytest
#      -p, --push               rebase 成功后用 --force-with-lease 推送工作分支
#          --upstream-url <url> 上游地址（默认 https://github.com/zhayujie/CowAgent.git）
#          --origin <name>      origin 远端名（默认 origin）
#      -h, --help               显示本帮助
#
#  退出码：
#      0  成功（含「上游无新提交」这种情况）
#      1  需要人工介入（master 被污染 / 有冲突 / 测试失败 / 环境不满足）
#
#  安全约定：
#      · 永不自动解决冲突——冲突时中止 rebase 并列出冲突文件，交给人工处理。
#      · 永不 force push——除非显式传 -p（且用的是 --force-with-lease）。
#      · master 上永不产生提交——一旦发现 master 领先上游，立即报错退出。
# =====================================================================

set -uo pipefail

# ── 默认配置 ──────────────────────────────────────────────────────────
WORK_BRANCH="develop"
MIRROR_BRANCH="master"
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
UPSTREAM_URL="https://github.com/zhayujie/CowAgent.git"
MODE="sync"          # sync | check
RUN_TESTS=1
DO_PUSH=0

# ── 输出工具 ──────────────────────────────────────────────────────────
ESC=$(printf '\033')
if [ -t 1 ]; then
    RED="${ESC}[31m"; GRN="${ESC}[32m"; YEL="${ESC}[33m"
    CYA="${ESC}[36m"; BLD="${ESC}[1m"; OFF="${ESC}[0m"
else
    RED=""; GRN=""; YEL=""; CYA=""; BLD=""; OFF=""
fi

info() { printf '%s\n' "${CYA}>${OFF} $*"; }
ok()   { printf '%s\n' "${GRN}OK${OFF} $*"; }
warn() { printf '%s\n' "${YEL}!!${OFF} $*"; }
err()  { printf '%s\n' "${RED}XX${OFF} $*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "----------------------------------------------------------------"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

# ── 命令行解析 ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--branch)       WORK_BRANCH="${2:-}"; [ -n "$WORK_BRANCH" ] || die "-b 需要一个分支名"; shift 2 ;;
        -c|--check)        MODE="check"; shift ;;
        -n|--no-test)      RUN_TESTS=0; shift ;;
        -p|--push)         DO_PUSH=1; shift ;;
        --upstream-url)    UPSTREAM_URL="${2:-}"; [ -n "$UPSTREAM_URL" ] || die "--upstream-url 需要一个 URL"; shift 2 ;;
        --origin)          ORIGIN_REMOTE="${2:-}"; [ -n "$ORIGIN_REMOTE" ] || die "--origin 需要一个远端名"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "未知参数：$1（用 -h 查看帮助）" ;;
    esac
done

# ── 定位仓库根目录 ────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || die "无法定位脚本目录"
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd) || die "无法定位仓库根目录"
cd "$ROOT" || die "无法进入 $ROOT"

hr
printf '%s\n' "${BLD}CowAgent fork · 上游同步${OFF}   模式=${MODE}  仓库=${ROOT}"
printf '%s\n' "  镜像分支=${MIRROR_BRANCH}  工作分支=${WORK_BRANCH}  源=${UPSTREAM_REMOTE}"
hr

[ -d .git ] || die "$ROOT 不是 git 仓库"

# ── 1. 确保 upstream 远端存在 ─────────────────────────────────────────
if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    ok "upstream 远端已存在：$(git remote get-url "$UPSTREAM_REMOTE")"
else
    info "添加 upstream 远端：$UPSTREAM_URL"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL" || die "添加 upstream 远端失败"
    ok "upstream 远端已添加"
fi

# ── 2. 拉取上游 ───────────────────────────────────────────────────────
info "拉取上游引用（fetch --tags --prune）..."
if ! git fetch "$UPSTREAM_REMOTE" --tags --prune; then
    die "拉取上游失败，请检查网络（国内网络可试 https://gitee.com/zhayujie/CowAgent.git）"
fi
ok "上游引用已更新"

UP_REF="$UPSTREAM_REMOTE/$MIRROR_BRANCH"
git rev-parse --verify --quiet "$UP_REF" >/dev/null || die "上游不存在 $UP_REF"

# ── 3. 校验 master 仍是「上游纯镜像」 ─────────────────────────────────
LOCAL_ONLY=$(git rev-list --count "$UP_REF..$MIRROR_BRANCH" 2>/dev/null || echo "ERR")
BEHIND=$(git rev-list --count "$MIRROR_BRANCH..$UP_REF" 2>/dev/null || echo "ERR")
[ "$LOCAL_ONLY" = "ERR" ] && die "无法比较 $MIRROR_BRANCH 与 $UP_REF"
[ "$BEHIND" = "ERR" ] && die "无法比较 $MIRROR_BRANCH 与 $UP_REF"

if [ "$LOCAL_ONLY" -gt 0 ]; then
    err "$MIRROR_BRANCH 上有 $LOCAL_ONLY 个提交不在上游——镜像已被污染！"
    err "本脚本拒绝继续。请先把这些提交挪到 $WORK_BRANCH 或 feature 分支："
    printf '\n'
    git log --oneline --no-merges "$UP_REF..$MIRROR_BRANCH" | head -20
    printf '\n'
    err "参考修复：git checkout $WORK_BRANCH && git cherry-pick <这些提交> && git checkout $MIRROR_BRANCH && git reset --hard $UP_REF"
    exit 1
fi
ok "$MIRROR_BRANCH 是上游纯镜像（领先 0 个提交）"

# ── 4. 上游是否有新提交 ───────────────────────────────────────────────
if [ "$BEHIND" -eq 0 ]; then
    printf '\n'
    ok "上游无新提交，$MIRROR_BRANCH 已是最新（$(git rev-parse --short "$UP_REF")）"
    printf '\n'
    hr
    printf '%s\n' "结论：无需同步。"
    hr
    exit 0
fi

printf '\n'
info "上游有 ${BLD}${BEHIND}${OFF} 个新提交："
git log --oneline --no-merges --date=short --pretty='%h %ad %s' "$MIRROR_BRANCH..$UP_REF" | head -40 | sed 's/^/   /'
[ "$BEHIND" -gt 40 ] && printf '   ...（仅显示前 40 条）\n'
printf '\n'

if [ "$MODE" = "check" ]; then
    hr
    printf '%s\n' "检查模式：未做任何改动。"
    printf '%s\n' "执行同步： bash scripts/fork/sync-upstream.sh -b $WORK_BRANCH"
    hr
    exit 0
fi

# ── 5. 前置检查：工作区必须干净 ───────────────────────────────────────
if [ -n "$(git status --porcelain)" ]; then
    err "工作区有未提交的改动，rebase 会失败。请先提交或暂存（git stash）："
    printf '\n'
    git status --short | head -30
    printf '\n'
    exit 1
fi
ok "工作区干净"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git rev-parse --verify --quiet "$WORK_BRANCH" >/dev/null || die "工作分支 $WORK_BRANCH 不存在"
OLD_MIRROR=$(git rev-parse --short "$MIRROR_BRANCH")
OLD_WORK=$(git rev-parse --short "$WORK_BRANCH")

# ── 6. 快进 master 并推送 ─────────────────────────────────────────────
printf '\n'
info "切换到 $MIRROR_BRANCH 并快进到上游..."
git checkout "$MIRROR_BRANCH" >/dev/null 2>&1 || die "切换到 $MIRROR_BRANCH 失败"
if ! git merge --ff-only "$UP_REF" >/dev/null 2>&1; then
    git checkout "$CURRENT_BRANCH" >/dev/null 2>&1
    die "fast-forward 失败——$MIRROR_BRANCH 可能已被污染，请人工检查"
fi
NEW_MIRROR=$(git rev-parse --short "$MIRROR_BRANCH")
ok "$MIRROR_BRANCH：$OLD_MIRROR -> $NEW_MIRROR"

if git push "$ORIGIN_REMOTE" "$MIRROR_BRANCH" >/dev/null 2>&1; then
    ok "已推送 $MIRROR_BRANCH 到 $ORIGIN_REMOTE"
else
    warn "推送 $MIRROR_BRANCH 到 $ORIGIN_REMOTE 失败（远端可能已受保护或网络问题），请在本地提交后手动推送"
fi

# ── 7. rebase 工作分支 ────────────────────────────────────────────────
printf '\n'
info "rebase $WORK_BRANCH 到 $MIRROR_BRANCH ..."
git checkout "$WORK_BRANCH" >/dev/null 2>&1 || die "切换到 $WORK_BRANCH 失败"

WORK_LOCAL=$(git rev-list --count "$MIRROR_BRANCH..$WORK_BRANCH" 2>/dev/null || echo 0)
[ "$WORK_LOCAL" -gt 0 ] && info "$WORK_BRANCH 上有 $WORK_LOCAL 个自有提交需要被 rebase 到新基线" \
                        || info "$WORK_BRANCH 无自有提交，将直接跟上游对齐"

REBASE_LOG=$(git rebase "$MIRROR_BRANCH" 2>&1)
REBASE_RC=$?
if [ "$REBASE_RC" -ne 0 ]; then
    printf '\n'
    err "rebase 冲突或被拒绝，本脚本不会自动解决。"
    printf '\n'
    printf '%s\n' "$REBASE_LOG" | head -40
    printf '\n'
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [ -n "$CONFLICTS" ]; then
        err "冲突文件："
        printf '%s\n' "$CONFLICTS" | sed 's/^/   /'
    fi
    printf '\n'
    info "已中止 rebase 以还原现场（git rebase --abort）。手工同步步骤："
    printf '%s\n' "   1) bash scripts/fork/sync-upstream.sh -c        # 确认上游更新"
    printf '%s\n' "   2) git checkout $MIRROR_BRANCH && git merge --ff-only $UP_REF"
    printf '%s\n' "   3) git checkout $WORK_BRANCH && git rebase $MIRROR_BRANCH   # 手工解冲突"
    printf '%s\n' "   4) git rebase --continue && $0 -n"
    git rebase --abort >/dev/null 2>&1

    hr
    printf '%s\n' "${RED}结论：需要人工介入（冲突）${OFF}"
    hr
    exit 1
fi
NEW_WORK=$(git rev-parse --short "$WORK_BRANCH")
ok "$WORK_BRANCH：$OLD_WORK -> $NEW_WORK"

# ── 8. 推送工作分支（可选） ───────────────────────────────────────────
if [ "$DO_PUSH" -eq 1 ]; then
    info "推送 $WORK_BRANCH 到 $ORIGIN_REMOTE（--force-with-lease）..."
    if git push --force-with-lease "$ORIGIN_REMOTE" "$WORK_BRANCH"; then
        ok "已推送 $WORK_BRANCH"
    else
        warn "推送 $WORK_BRANCH 失败，请人工检查"
    fi
else
    warn "未推送 $WORK_BRANCH（rebase 改写了历史）。确认无误后执行："
    printf '%s\n' "   git push --force-with-lease $ORIGIN_REMOTE $WORK_BRANCH"
fi

# ── 9. 跑测试 ─────────────────────────────────────────────────────────
TEST_RC=0
if [ "$RUN_TESTS" -eq 1 ]; then
    printf '\n'
    PY=""
    for c in python3 python py; do
        if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
    done
    if [ -z "$PY" ]; then
        warn "未找到 Python，跳过测试（请手工运行 pytest tests/ -q）"
    elif ! "$PY" -m pytest --version >/dev/null 2>&1; then
        warn "未安装 pytest，跳过测试（安装：$PY -m pip install pytest）"
    else
        info "运行测试：$PY -m pytest tests/ -q"
        "$PY" -m pytest tests/ -q
        TEST_RC=$?
        if [ "$TEST_RC" -eq 0 ]; then
            ok "测试全部通过"
        else
            err "测试失败（退出码 $TEST_RC）——自有改动很可能与上游语义撞了。"
            info "排查思路：git range-diff $MIRROR_BRANCH...$WORK_BRANCH 看补丁是否被上游改写"
        fi
    fi
fi

# ── 10. 汇总 ──────────────────────────────────────────────────────────
printf '\n'
hr
printf '%s\n' "${BLD}同步汇总${OFF}"
printf '%s\n' "  $MIRROR_BRANCH : $OLD_MIRROR -> $NEW_MIRROR   （跟随上游 $BEHIND 个提交）"
printf '%s\n' "  $WORK_BRANCH : $OLD_WORK -> $NEW_WORK"
printf '%s\n' "  与上游差距 : $(git rev-list --count "$WORK_BRANCH..$UP_REF") 落后 / $(git rev-list --count "$UP_REF..$WORK_BRANCH") 领先"
if [ "$RUN_TESTS" -eq 1 ]; then
    [ "$TEST_RC" -eq 0 ] && printf '%s\n' "  测试 : 通过" || printf '%s\n' "  测试 : ${RED}失败${OFF}"
fi
hr

if [ "$TEST_RC" -ne 0 ]; then
    printf '%s\n' "${RED}结论：同步已完成，但测试未通过，请人工处理。${OFF}"
    exit 1
fi
printf '%s\n' "${GRN}结论：同步成功。${OFF}"
exit 0
