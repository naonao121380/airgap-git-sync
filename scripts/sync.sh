#!/usr/bin/env bash
# ============================================================
#  sync.sh — 两台不通网的机器之间同步 git 仓库（U 盘摆渡）
#
#  背景：A、B 两台机器网络互不相通，但都要改同一份代码。
#        本脚本用 `git bundle` 把提交打成单文件，U 盘搬过去，
#        再导入对方的仓库。
#
#  设计要点：
#    · 只同步一条分支（默认 dev），包小、不会跑偏
#    · 合并只允许在 A 端做；B 端只能开 b/xxx 提案分支，
#      否则两端各生成一个 merge commit，历史永久分叉
#    · 每次搬运都校验 sha256
#    · 默认把仓库刷成 777 并关闭 filemode（适配容器/共享存储）
#
#  安装：把本脚本放在仓库【外面】，推荐 ~/sync.sh
#        （放进仓库里会被一起同步，然后覆盖对方的未跟踪副本）
#
#  用法：
#    cd <仓库目录> && ~/sync.sh <子命令> [参数]
#    或 export SYNC_REPO=/path/to/repo 后在任意目录执行
#
#  环境变量（可写进 ~/.sync.env）：
#    SYNC_BRANCH=dev        同步的分支
#    SYNC_MEDIA=/media/usb  U 盘挂载点默认值
#    SYNC_PERM=777          每次操作后把仓库权限刷成这个值；留空则跳过
# ============================================================

set -uo pipefail

# ---------- 配置 ----------
[ -f "$HOME/.sync.env" ] && . "$HOME/.sync.env"
: "${SYNC_BRANCH:=dev}"
: "${SYNC_MEDIA:=/media/usb}"
: "${SYNC_PERM:=777}"
: "${SYNC_PUSH_TIMEOUT:=30}"
BRANCH="$SYNC_BRANCH"
MEDIA="$SYNC_MEDIA"
PERM="$SYNC_PERM"
PEER="peer"
ME=$(basename "$0")

# ---------- 定位仓库（脚本本身不放进仓库，避免被同步覆盖）----------
resolve_repo() {
    if [ -n "${SYNC_REPO:-}" ]; then
        if [ ! -d "${SYNC_REPO%/}/.git" ]; then
            printf '[错误] SYNC_REPO 不是 git 仓库：%s\n' "$SYNC_REPO" >&2
            exit 1
        fi
        printf '%s\n' "${SYNC_REPO%/}"; return 0
    fi
    local r
    if r=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$r" ]; then
        printf '%s\n' "$r"; return 0
    fi
    printf '[错误] 当前目录不在 git 仓库里。\n  先 cd 到仓库目录再执行，或设 SYNC_REPO=/path/to/repo\n' >&2
    exit 1
}

REPO=$(resolve_repo) || exit 1
cd "$REPO" || exit 1

# ---------- 输出 ----------
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_NO=$'\033[33m'; C_ER=$'\033[31m'; C_0=$'\033[0m'
else
    C_OK=''; C_NO=''; C_ER=''; C_0=''
fi
ok()   { printf '%s[OK]%s %s\n'   "$C_OK" "$C_0" "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n'    "$C_NO" "$C_0" "$*"; }
die()  { printf '%s[停]%s %s\n'   "$C_ER" "$C_0" "$*"; echo; exit 1; }
hr()   { printf -- '------------------------------------------------------------\n'; }
sec()  { echo; hr; echo "  $*"; hr; }

# ---------- 权限：统一 777，并让 git 无视权限位 ----------
fixperm() {
    [ -n "$PERM" ] || { info "已跳过权限修正（SYNC_PERM 为空）"; return 0; }
    git config core.filemode false
    if chmod -R "$PERM" "$REPO" 2>/dev/null; then
        ok "权限已刷成 $PERM（git 已忽略权限位变化，不会产生假改动）"
    elif sudo -n chmod -R "$PERM" "$REPO" 2>/dev/null; then
        ok "权限已刷成 $PERM（sudo）"
    else
        warn "chmod 失败，手动执行一次：sudo chmod -R $PERM $REPO"
        return 1
    fi
}

# ---------- 基础检查 ----------
ensure_config() {
    git config core.filemode false
    [ -n "$(git config user.name  2>/dev/null)" ] || {
        warn "还没配提交身份，合并会失败。执行："
        info "git config --global user.name  \"你的名字\""
    }
    [ -n "$(git config user.email 2>/dev/null)" ] || {
        warn "还没配邮箱，合并会失败。执行："
        info "git config --global user.email \"你的邮箱\""
    }
}

ensure_branch() {
    git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
        || die "本地没有分支 $BRANCH（git branch -a 看一下）"
}

ensure_clean() {
    local n
    n=$(git status --porcelain | grep -v '^??' | wc -l | tr -d ' ')
    if [ "$n" -ne 0 ]; then
        git status --porcelain | grep -v '^??' | head -10 | sed 's/^/      /'
        die "有 $n 个文件改了但没提交。先提交，或丢弃，再同步：
    git add -A && git commit -m \"说明\"
  丢弃： git checkout -- ."
    fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# 快进前：把"会被新版本覆盖、但本地还没纳管"的文件改名备份（不删除）
backup_untracked_conflicts() {
    local target="$1" f n=0
    while IFS= read -r -d '' f; do
        [ -n "$f" ] || continue
        [ -e "$f" ] || continue
        if ! git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
            if mv -- "$f" "$f.preload-$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
                info "未跟踪文件将被覆盖，已改名备份：$f"
                n=$((n+1))
            fi
        fi
    done < <(git diff --name-only -z "$target" HEAD 2>/dev/null)
    [ "$n" -eq 0 ] || ok "共备份 $n 个冲突文件（后缀 .preload-时间）"
}

# 收集要打包的分支：dev + 所有 b/*
collect_refs() {
    REFS=("$BRANCH")
    local b
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        case "$b" in b/*) REFS+=("$b") ;; esac
    done < <(git for-each-ref --format='%(refname:short)' refs/heads)
}

# ================= pack =================
cmd_pack() {
    local dir="${1:-$MEDIA}"
    [ -d "$dir" ] || die "目录不存在：$dir
  U 盘没挂上？或者传一个目录：$ME pack /path/to/dir"
    [ -w "$dir" ] || die "目录不可写：$dir"

    sec "1. 检查"
    ensure_config
    ensure_branch
    ensure_clean
    local cur; cur=$(git rev-parse --abbrev-ref HEAD)
    case "$cur" in
        "$BRANCH"|b/*) ok "当前在 $cur，工作区干净" ;;
        *) die "当前在分支 $cur。打包只能在 $BRANCH 或 b/* 分支上做：
    git checkout $BRANCH" ;;
    esac

    sec "2. 打包"
    local stamp host out
    stamp=$(date +%Y%m%d-%H%M%S)
    host=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-')
    out="$dir/sync-${host}-${stamp}.bundle"
    [ -e "$out" ] && die "文件已存在，等一分钟或删掉：$out"

    collect_refs
    info "包含分支：${REFS[*]}"
    git bundle create "$out" "${REFS[@]}" >/dev/null 2>&1 \
        || die "打包失败（bundle create）"
    git bundle verify "$out" >/dev/null 2>&1 \
        || die "包自校验失败，磁盘可能有问题：$out"

    # 校验文件固定写成 "hash  文件名"（两个空格），跨平台一致
    printf '%s  %s\n' "$(sha256_of "$out")" "$(basename "$out")" \
        > "$dir/$(basename "$out").sha256"

    ok "已生成 $(basename "$out")  $(du -h "$out" | awk '{print $1}')"
    info "sha256: $(cat "$out.sha256")"

    sec "3. 带上这两个文件去对面"
    info "$(basename "$out")"
    info "$(basename "$out").sha256"
    echo
    info "对面执行：  $ME load <拷贝到的目录或那个 .bundle>"
    echo

    fixperm
}

# ================= load =================
resolve_pkg() {
    local src="${1:-$MEDIA}" p
    if [ -d "$src" ]; then
        p=$(ls -t "$src"/sync-*.bundle 2>/dev/null | head -1)
        [ -n "$p" ] || die "目录里没有 sync-*.bundle：$src"
        # 提示必须走 stderr，否则会被 $(...) 当成路径的一部分
        printf '      自动选中最新包：%s\n' "$(basename "$p")" >&2
    elif [ -f "$src" ]; then
        p="$src"
    else
        die "找不到：$src"
    fi
    printf '%s\n' "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
}

cmd_load() {
    local bundle; bundle=$(resolve_pkg "${1:-}")

    sec "1. 校验文件"
    if [ -f "$bundle.sha256" ]; then
        if ( cd "$(dirname "$bundle")" && sha256sum -c "$(basename "$bundle").sha256" >/dev/null 2>&1 ); then
            ok "sha256 校验通过"
        else
            die "sha256 不匹配，文件在拷贝中损坏，重新拷，不要继续"
        fi
    else
        warn "没找到 .sha256，跳过校验"
    fi
    git bundle verify "$bundle" >/dev/null 2>&1 \
        || die "包损坏，或者不是这个仓库的包"

    sec "2. 检查本地"
    ensure_config
    ensure_branch
    ensure_clean
    local cur; cur=$(git rev-parse --abbrev-ref HEAD)
    [ "$cur" = "$BRANCH" ] || { git checkout "$BRANCH" >/dev/null 2>&1 || die "切不到 $BRANCH"; }
    ok "当前在 $BRANCH，工作区干净"

    sec "3. 读入包里的分支"
    git fetch "$bundle" "+refs/heads/*:refs/remotes/$PEER/*" "+refs/tags/*:refs/tags/*" >/dev/null 2>&1 \
        || die "从包里取引用失败"
    git for-each-ref --format='      %(refname:short)  %(objectname:short)' "refs/remotes/$PEER" \
        | grep -v '/HEAD' || true

    sec "4. 更新 $BRANCH"
    local rsrc="refs/remotes/$PEER/$BRANCH"
    if ! git rev-parse --verify --quiet "$rsrc" >/dev/null; then
        warn "包里没有 $BRANCH，跳过"
    elif git merge-base --is-ancestor "$rsrc" "refs/heads/$BRANCH"; then
        ok "本地 $BRANCH 已包含包里的全部提交，无需更新"
    elif git merge-base --is-ancestor "refs/heads/$BRANCH" "$rsrc"; then
        backup_untracked_conflicts "$rsrc"
        if ! git merge --ff-only "$rsrc" >/tmp/mars-merge.err 2>&1; then
            sed 's/^/      /' /tmp/mars-merge.err
            die "快进失败，上面是 git 的原话"
        fi
        ok "已快进到 $(git log -1 --format='%h %s' "$BRANCH")"
    else
        warn "两边都改过 $BRANCH，历史分叉了，不能自动处理"
        info "本地独有提交："
        git log --oneline "$rsrc..$BRANCH" | head -5 | sed 's/^/        /'
        info "对方独有提交："
        git log --oneline "$BRANCH..$rsrc" | head -5 | sed 's/^/        /'
        echo
        info "如果这些本地提交本该在分支上，先挪走再重跑："
        info "  $ME branch 暂存-$(date +%m%d)"
        info "  git reset --hard $PEER/$BRANCH"
        info "  $ME load"
        echo
        die "分叉未处理"
    fi

    sec "5. 推回本机 Gitea"
    if git remote get-url origin >/dev/null 2>&1; then
        if timeout "$SYNC_PUSH_TIMEOUT" git push origin "$BRANCH" >/dev/null 2>&1; then
            ok "已推送 origin/$BRANCH"
        else
            warn "推送超时或失败（本机 Gitea 没起来 / 网络不通，可忽略）"
        fi
    else
        info "没有 origin，跳过"
    fi

    echo
    ok "完成，现在 dev = $(git rev-parse --short "$BRANCH")"
    fixperm
}

# ================= branch（B 端改代码前用）=================
cmd_branch() {
    local name="${1:-}"
    [ -n "$name" ] || die "用法：$ME branch <名字>
  例：$ME branch 1030-修bug   → 会建 b/1030-修bug"
    case "$name" in
        b/*) ;;
        *)   name="b/$name" ;;
    esac
    ensure_config
    git rev-parse --verify --quiet "refs/heads/$name" >/dev/null \
        && die "分支 $name 已存在，换个名字，或直接：git checkout $name"
    git checkout "$BRANCH" >/dev/null 2>&1 || die "切不到 $BRANCH"
    git checkout -b "$name" >/dev/null 2>&1 || die "建分支失败"
    ok "已切到 $name，现在可以改代码"
    info "改完提交：git add -A && git commit -m \"说明\""
    info "然后打包：$ME pack"
    fixperm
}

# ================= merge（A 端合并 B 的分支）=================
cmd_merge() {
    local src="${1:-}"
    [ -n "$src" ] || die "用法：$ME merge <分支>
  例：$ME merge b/1030-修bug
  也可以：$ME merge $PEER/b/1030-修bug"
    ensure_config
    local ref=""
    if git rev-parse --verify --quiet "refs/heads/$src" >/dev/null; then
        ref="refs/heads/$src"
    elif git rev-parse --verify --quiet "refs/remotes/$PEER/$src" >/dev/null; then
        ref="refs/remotes/$PEER/$src"
    else
        die "找不到分支 $src（$ME status 看看有哪些）"
    fi

    git checkout "$BRANCH" >/dev/null 2>&1 || die "切不到 $BRANCH"
    ensure_clean

    sec "合并 $src → $BRANCH"
    if git merge --no-ff "$ref" -m "merge $src into $BRANCH" >/dev/null 2>&1; then
        ok "已合并：$(git log -1 --format='%h %s')"
    elif [ -n "$(git ls-files -u)" ]; then
        warn "有冲突，需要手工解决："
        git diff --name-only --diff-filter=U | sed 's/^/        /'
        echo
        info "用编辑器改完这些文件，然后："
        info "  git add -A"
        info "  git commit -m \"解决冲突\""
        info "  git push origin $BRANCH"
        echo
        die "先解决冲突"
    else
        die "合并失败（不是冲突导致），把上面的报错贴出来"
    fi

    if git remote get-url origin >/dev/null 2>&1; then
        if timeout "$SYNC_PUSH_TIMEOUT" git push origin "$BRANCH" >/dev/null 2>&1; then
            ok "已推送 origin/$BRANCH"
        else
            warn "推送超时或失败，可稍后手动 git push"
        fi
    fi

    echo
    info "下一步：$ME pack 打包给 B"
    echo
    fixperm
}

# ================= status =================
cmd_status() {
    sec "仓库"
    info "路径 : $REPO"
    info "分支 : $(git rev-parse --abbrev-ref HEAD)"
    info "提交 : $(git log -1 --format='%h %s' 2>/dev/null)"
    info "远端 : $(git remote get-url origin 2>/dev/null || echo '（无）')"
    info "权限 : ${PERM:-（不处理）}    filemode=$(git config core.filemode || echo '未设')"

    sec "本地分支"
    git for-each-ref --format='%(refname:short)|%(objectname:short)|%(committerdate:short)' refs/heads/ \
        | awk -F'|' '{printf "  %-24s %s  %s\n", $1, $2, $3}'

    sec "工作区"
    local n; n=$(git status --porcelain | grep -v '^??' | wc -l | tr -d ' ')
    [ "$n" -eq 0 ] && ok "没有未提交的改动" || warn "$n 个已跟踪文件有改动"
    local u; u=$(git status --porcelain | grep -c '^??' || true)
    info "未跟踪文件：${u:-0} 个（数据/配置通常在这里，不会被同步影响）"

    if git rev-parse --verify --quiet "refs/remotes/$PEER/$BRANCH" >/dev/null; then
        sec "与上次导入的对比"
        info "上次从包里收到的 $BRANCH = $(git rev-parse --short "refs/remotes/$PEER/$BRANCH")"
    fi
    echo
}

# ================= usage =================
usage() {
    cat <<EOF
$ME — A/B 双端代码同步（只同步 dev）

  $ME pack   [目录]      打包当前仓库到 U 盘（默认 /media/usb）
  $ME load   [包或目录]   从 U 盘导入，自动选最新包
  $ME branch <名字>       开工作分支 b/<名字>（B 端改代码前必做）
  $ME merge  <分支>       把 b/xxx 合进 dev（A 端做）
  $ME status              看当前状态
  $ME fixperm             把整个仓库权限刷成 777

日常：
  A 改完  → A: $ME pack   →  B: $ME load
  B 要改  → B: $ME branch 1030-fix → 改代码 → commit → $ME pack
          → A: $ME load → $ME merge b/1030-fix → $ME pack
          → B: $ME load
EOF
}

case "${1:-}" in
    pack|p)     shift; cmd_pack   "$@" ;;
    load|l)     shift; cmd_load   "$@" ;;
    branch)     shift; cmd_branch "$@" ;;
    merge|m)    shift; cmd_merge  "$@" ;;
    status|s)   cmd_status ;;
    fixperm|f)  fixperm ;;
    ""|-h|--help|help) usage ;;
    *) printf '未知命令：%s\n\n' "$1"; usage; exit 1 ;;
esac
