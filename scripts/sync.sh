#!/usr/bin/env bash
# ============================================================
#  sync.sh — 不通网的两台机器之间「整仓镜像」同步（U 盘摆渡）
#
#  和旧版最大的不同：不再分 A 端 / B 端，也没有 cherry-pick。
#  两端跑同一份脚本、同一套命令，谁都能改代码，谁都能打包。
#
#  模型（四句话）：
#    1. 每次运行先把本地和【自己的 origin】对齐：
#         落后     → 自动快进（等于 pull）
#         领先     → 停下等人处理（提交还没进远端，直接搬会把远端搞乱）
#         已分叉   → 停下等人处理
#    2. pack：只打包【远端存在的】分支 + 标签
#         本地有、远端没有的分支不进包（要先 push 上去）
#         远端有、本地没有的分支会先拉下来，再一起打包
#    3. load：把包里所有分支逐个对到本地，能快进就快进，分叉就停
#    4. 结束时停回你运行前所在的分支；env 里设了 SYNC_BRANCH 就停在它上面
#
#  仓库怎么找（脚本放哪都行，不用一定在仓库里）：
#       -r /path/to/repo   →   SYNC_REPO=...   →   从当前目录往上找 .git
#  配置文件永远跟着脚本走：<脚本所在目录>/.sync.env
#
#  用法：
#      sync.sh pack  /media/usb/toB     # 打包给对面（只含远端存在的分支）
#      sync.sh load  /media/usb/toB     # 收下对面的包
#      sync.sh status                   # 看状态（只读，不改任何东西）
#      sync.sh branch 1103-修bug         # 开工作分支 b/1103-修bug
#      sync.sh fixperm                  # 把仓库刷成 777
# ============================================================

set -uo pipefail

# ---------- 找自己、读配置（配置永远在脚本旁边，脚本搬到哪配置跟到哪）----------
_self="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
    _tmp=$(readlink -f "$_self" 2>/dev/null) || _tmp=""
    [ -n "$_tmp" ] && _self="$_tmp"
    unset _tmp
fi
SCRIPT_DIR=$(cd "$(dirname "$_self")" 2>/dev/null && pwd) || SCRIPT_DIR="$(pwd)"
unset _self

ENV_FILE="$SCRIPT_DIR/.sync.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# 变量名漏了 SYNC_ 前缀（写成 BRANCH=dev）时，source 不报错、脚本也读不到，
# 会静默按默认值跑——这是最难查的一类配置问题，先挑出来。
ENV_TYPOS=""
for _k in BRANCH MEDIA PERM REPO REMOTE PUSH_TIMEOUT ALLOW_LOCAL_AHEAD SKIP_REMOTE; do
    _bad="$_k"; _good="SYNC_$_k"
    if [ -n "${!_bad:-}" ] && [ -z "${!_good:-}" ]; then
        ENV_TYPOS="$ENV_TYPOS  $_bad=${!_bad}"
    fi
done
unset _k _bad _good

# 旧模型（A/B 角色 + 合并落点）的变量，新版不再读取，提示一次即可
ENV_DEPRECATED=""
for _k in SYNC_ROLE SYNC_MERGE_INTO SYNC_ALLOW_MERGE_TO_RELEASE; do
    [ -n "${!_k:-}" ] && ENV_DEPRECATED="$ENV_DEPRECATED $_k"
done
unset _k

# ---------- 默认值 ----------
: "${SYNC_MEDIA:=/media/usb}"
: "${SYNC_REMOTE:=origin}"
: "${SYNC_PUSH_TIMEOUT:=30}"
: "${SYNC_ALLOW_LOCAL_AHEAD:=0}"
: "${SYNC_SKIP_REMOTE:=0}"
# SYNC_PERM 要区分两种"空"：
#   没写这一行     → 默认 777
#   写成 SYNC_PERM= → 空串，表示不处理权限
# set -u 下不能用 ${VAR-default}（只取默认值、不赋值，下一行读就报 unbound），
# 所以用 +x 判断"到底设置过没有"
if [ -z "${SYNC_PERM+x}" ]; then
    SYNC_PERM=777
fi

MEDIA="$SYNC_MEDIA"
REMOTE="$SYNC_REMOTE"
PERM="$SYNC_PERM"
BRANCH="${SYNC_BRANCH:-}"      # 空 = 停回运行前的分支
PEER="peer"
ME=$(basename "$0")
STEP=0
FAILED_BRANCHES=""             # load 时推回远端失败的分支

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
nxt()  { STEP=$((STEP+1)); sec "$STEP. $*"; }

warn_env_notes() {
    if [ ! -f "$ENV_FILE" ] && [ -f "$HOME/.sync.env" ]; then
        warn "配置还在老位置 $HOME/.sync.env，本版只读脚本目录的 $ENV_FILE"
        info "搬一下就好： mv $HOME/.sync.env $ENV_FILE"
        echo
    fi
    if [ -n "$ENV_TYPOS" ]; then
        warn "$ENV_FILE 里有变量名漏了 SYNC_ 前缀，脚本读不到："
        info "$ENV_TYPOS"
        info "要写成 SYNC_xxx=... 才生效，本次按默认值跑"
        echo
    fi
    if [ -n "$ENV_DEPRECATED" ]; then
        warn "$ENV_FILE 里还有旧模型的变量，新版不读了，可以删掉："
        info "$ENV_DEPRECATED"
        info "新模式不分 A/B，只同步远端存在的分支，不需要角色和合并落点"
        echo
    fi
}

# ---------- 定位仓库 ----------
OPT_REPO=""

# 静默从当前目录往上找 .git：找到就设 REPO，返回 0
locate() {
    local d="$PWD"
    while :; do
        if [ -d "$d/.git" ] || [ -f "$d/.git" ]; then REPO="$d"; return 0; fi
        [ "$d" = "/" ] && break
        d=$(dirname "$d")
    done
    return 1
}

resolve_repo() {
    local d
    if [ -n "$OPT_REPO" ]; then
        d=$(abspath "${OPT_REPO%/}")
        [ -d "$d/.git" ] || [ -f "$d/.git" ] || die "指定的目录不是 git 仓库：$OPT_REPO"
        REPO="$d"; return 0
    fi
    if [ -n "${SYNC_REPO:-}" ]; then
        d=$(abspath "${SYNC_REPO%/}")
        [ -d "$d/.git" ] || [ -f "$d/.git" ] || die "SYNC_REPO 不是 git 仓库：$SYNC_REPO
  改 $ENV_FILE 里那一行，或者直接传 -r /path/to/repo"
        REPO="$d"; return 0
    fi
    locate && return 0
    die "找不到 git 仓库：当前目录 $PWD 往上没有 .git
  三种办法（任选一个）：
    cd 到仓库目录再执行
    $ME -r /path/to/repo <子命令>
    在 $ENV_FILE 里写 SYNC_REPO=/path/to/repo"
}

# ---------- git 小工具 ----------
# 脚本会 cd 进仓库，所以用户敲的相对路径必须在 cd 之前就变成绝对路径，
# 否则 "sync.sh pack ./usb" 这种写法会在仓库目录里找 ./usb
ORIG_PWD="$PWD"
abspath() {
    case "$1" in
        "")        printf '\n' ;;
        /*)        printf '%s\n' "$1" ;;                       # Unix 绝对路径
        [A-Za-z]:[\\/]*) printf '%s\n' "$1" ;;                 # Windows 盘符（Git Bash）
        *)         printf '%s/%s\n' "${ORIG_PWD%/}" "$1" ;;
    esac
}

# 当前分支名；空仓库（还没有提交）时 HEAD 是"未诞生分支"，这里也返回它的名字
current_branch() { git symbolic-ref --short HEAD 2>/dev/null || true; }
has_commit()     { git rev-parse --verify --quiet HEAD >/dev/null 2>&1; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Git Bash 里可能没有 timeout，缺了就裸跑（push 卡住时用户能 Ctrl-C）
run_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

# 返回 same / behind / ahead / diverged / local-only
branch_state() {
    local b="$1" r="refs/remotes/$REMOTE/$b" ahead behind
    git rev-parse --verify --quiet "$r" >/dev/null || { printf 'local-only\n'; return 0; }
    read -r ahead behind < <(git rev-list --left-right --count "refs/heads/$b...$r" 2>/dev/null)
    ahead=${ahead:-0}; behind=${behind:-0}
    if   [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then printf 'same\n'
    elif [ "$behind" -eq 0 ]; then printf 'ahead\n'
    elif [ "$ahead" -eq 0 ];  then printf 'behind\n'
    else printf 'diverged\n'; fi
}

local_branches() { git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null; }

# 远端有哪些分支（剥掉 refs/remotes/<remote>/ 前缀，去掉 HEAD）
remote_branches() {
    git for-each-ref --format='%(refname)' "refs/remotes/$REMOTE" 2>/dev/null \
        | sed "s|^refs/remotes/$REMOTE/||" | grep -v '^HEAD$' || true
}

has_remote() { git remote get-url "$REMOTE" >/dev/null 2>&1; }

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
    [ -n "$(git config user.name 2>/dev/null)" ] || {
        warn "还没配提交身份，合并/提交会失败。执行："
        info "git config --global user.name  \"你的名字\""
    }
    [ -n "$(git config user.email 2>/dev/null)" ] || {
        warn "还没配邮箱，合并/提交会失败。执行："
        info "git config --global user.email \"你的邮箱\""
    }
}

ensure_clean() {
    local n
    n=$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
    if [ "${n:-0}" -ne 0 ]; then
        git status --porcelain | grep -v '^??' | head -10 | sed 's/^/      /'
        die "有 $n 个已跟踪文件改了但没提交，不能更新工作区。
  先提交：git add -A && git commit -m \"说明\"
  或丢弃：git checkout -- ."
    fi
}

# rebase / merge / cherry-pick 做到一半时不能同步，否则会踩翻现场
ensure_no_operation() {
    local g f
    g=$(git rev-parse --git-dir 2>/dev/null) || return 0
    for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
        [ -e "$g/$f" ] || continue
        warn "仓库里有个没做完的操作（$g/$f）"
        info "先收尾或撤掉，再跑同步："
        info "  git status              # 看还剩什么"
        info "  git rebase --continue   # 或 --abort"
        info "  git merge  --continue   # 或 --abort"
        echo
        die "上一个操作还没结束，已停下"
    done
}

# 要写进工作区的文件（NUL 分隔，直接喂给 while read）
list_incoming() {
    local target="$1"
    if has_commit; then
        git diff --name-only -z "$target" HEAD 2>/dev/null
    else
        git ls-tree -r --name-only -z "$target" 2>/dev/null
    fi
}

# 更新前：把"会被新版本覆盖、但本地还没纳管"的文件改名备份（不删除）
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
    done < <(list_incoming "$target")
    [ "$n" -eq 0 ] || ok "共备份 $n 个冲突文件（后缀 .preload-时间）"
}

# ============================================================
#  与远端对齐（每个命令开头都跑）
# ============================================================
ORIG_BRANCH=""
TARGET=""

# 决定"同步结束后停在哪个分支"
decide_target() {
    local t="$BRANCH"
    if [ -n "$t" ]; then printf '%s\n' "$t"; return 0; fi
    # 空仓库里 HEAD 指向的是一个"还没诞生的分支"（master/main），
    # 它并不真的存在，不能拿去 checkout，否则导入完就卡在这
    if [ -n "$ORIG_BRANCH" ] \
       && git rev-parse --verify --quiet "refs/heads/$ORIG_BRANCH" >/dev/null; then
        printf '%s\n' "$ORIG_BRANCH"
    fi
}

switch_to() {
    local t="$1"
    [ -n "$t" ] || return 0
    [ "$t" = "$(current_branch)" ] && return 0
    if git rev-parse --verify --quiet "refs/heads/$t" >/dev/null; then
        git checkout "$t" >/dev/null 2>&1 || die "切不到分支 $t（工作区有冲突文件？）"
        info "已切到 $t"
    elif git rev-parse --verify --quiet "refs/remotes/$REMOTE/$t" >/dev/null; then
        git checkout -b "$t" "$REMOTE/$t" >/dev/null 2>&1 \
            || die "从 $REMOTE/$t 建本地分支失败（工作区有冲突文件？）"
        ok "本地没有 $t，已从 $REMOTE 建出来"
    else
        die "本地和 $REMOTE 都没有分支 $t（SYNC_BRANCH 写错了？）"
    fi
}

sync_remote() {
    ORIG_BRANCH=$(current_branch)
    TARGET=$(decide_target)

    if ! has_commit; then
        info "仓库里还没有提交，先跳过与远端的对齐（导入后再管）"
        return 0
    fi
    if [ "$SYNC_SKIP_REMOTE" = "1" ]; then
        info "已跳过与远端的对齐（SYNC_SKIP_REMOTE=1）"
        return 0
    fi
    if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
        warn "没有名为 $REMOTE 的远端，跳过对齐"
        switch_to "$TARGET"
        return 0
    fi

    nxt "与远端 $REMOTE 对齐"

    if ! git fetch "$REMOTE" --prune --tags >/tmp/sync-fetch.err 2>&1; then
        warn "拉取远端失败，这次跳过对齐（本地状态未改动）："
        sed 's/^/      /' /tmp/sync-fetch.err | head -5
        info "远端起来后重跑；确实连不上就在 $ENV_FILE 写 SYNC_SKIP_REMOTE=1"
        switch_to "$TARGET"
        return 0
    fi
    ok "已拉取远端引用"

    # 远端是唯一真相源：远端有、本地没有的分支，全部建成本地同名分支（跟远端一样新）
    # 这样后面打包时，本地分支集合 ⊇ 远端分支集合，包里的内容永远等于远端的样子
    local b st adopted=()
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        git rev-parse --verify --quiet "refs/heads/$b" >/dev/null && continue
        if git branch --track "$b" "$REMOTE/$b" >/dev/null 2>&1 \
           || git update-ref "refs/heads/$b" "refs/remotes/$REMOTE/$b" 2>/dev/null; then
            adopted+=("$b")
        fi
    done < <(remote_branches)
    if [ ${#adopted[@]} -gt 0 ]; then
        ok "远端有、本地没有的分支，已拉下来：${adopted[*]}"
    fi

    local behind_list=() ahead_list=() diverged_list=() lonely_list=()
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        st=$(branch_state "$b")
        case "$st" in
            behind)     behind_list+=("$b") ;;
            ahead)      ahead_list+=("$b") ;;
            diverged)   diverged_list+=("$b") ;;
            local-only) lonely_list+=("$b") ;;
        esac
    done < <(local_branches)

    # --- 分叉：两边都有对方没有的提交，不能自动处理 ---
    if [ ${#diverged_list[@]} -gt 0 ]; then
        warn "这些分支在本机和 $REMOTE 上都有对方没有的提交（已分叉）："
        for b in "${diverged_list[@]}"; do
            info "$b  本地 +$(git rev-list --count "refs/remotes/$REMOTE/$b..refs/heads/$b")  远端 +$(git rev-list --count "refs/heads/$b..refs/remotes/$REMOTE/$b")"
        done
        echo
        info "自己决定怎么合（脚本不替你选），在仓库里执行："
        info "  git checkout <分支>"
        info "  git rebase $REMOTE/<分支>                    # 把自己的提交接到远端后面"
        info "  git push --force-with-lease $REMOTE <分支>    # rebase 改写过历史，必须 force"
        info "想保留合并记录就这样："
        info "  git merge $REMOTE/<分支> && git push $REMOTE <分支>"
        info "处理完再跑一次本命令。"
        echo
        die "有分支已分叉，已停下（没有改动任何东西）"
    fi

    # --- 领先：本地有还没进远端的提交 ---
    if [ ${#ahead_list[@]} -gt 0 ] && [ "$SYNC_ALLOW_LOCAL_AHEAD" != "1" ]; then
        warn "这些分支比 $REMOTE 多出本地提交（还没推送）："
        for b in "${ahead_list[@]}"; do
            info "$b  +$(git rev-list --count "refs/remotes/$REMOTE/$b..refs/heads/$b") 个提交"
            git log --oneline "refs/remotes/$REMOTE/$b..refs/heads/$b" | head -3 | sed 's/^/        /'
        done
        echo
        info "本地和远端不一致，直接搬包会把远端的状态带乱，所以先停下。两条路："
        info "  ① 推到本机 Gitea，让两边一致（推荐）"
        info "     git push $REMOTE <分支>"
        info "  ② 就是要带着这些提交去对面（对面收下后也会带回来）"
        info "     SYNC_ALLOW_LOCAL_AHEAD=1 $ME ${CMDNAME:-pack} ..."
        info "也写进配置长期生效：在 $ENV_FILE 加一行 SYNC_ALLOW_LOCAL_AHEAD=1"
        echo
        die "本地领先远端，已停下（没有改动任何东西）"
    elif [ ${#ahead_list[@]} -gt 0 ]; then
        warn "本地有未推送提交，按 SYNC_ALLOW_LOCAL_AHEAD=1 放行："
        for b in "${ahead_list[@]}"; do
            info "$b  +$(git rev-list --count "refs/remotes/$REMOTE/$b..refs/heads/$b") 个提交（会一起进包）"
        done
    fi

    if [ ${#lonely_list[@]} -gt 0 ]; then
        info "本地有、远端没有的分支（不会进包）：${lonely_list[*]}"
        info "要让对面拿到，先推上去：git push $REMOTE <分支>"
        for b in "${lonely_list[@]}"; do
            [ "$b" = "$(current_branch)" ] || continue
            echo
            warn "你现在就在 $b 上，它远端没有 → 这个分支上的提交这次不会被打包"
            info "先推：git push $REMOTE $b    （推完重跑，它就会进包）"
        done
    fi

    # --- 落后：自动快进 ---
    if [ ${#behind_list[@]} -gt 0 ]; then
        info "落后的分支：${behind_list[*]}"
        # 只有"要动工作区"时才要求干净
        local touch_wt=0
        for b in "${behind_list[@]}"; do
            [ "$b" = "$TARGET" ] && touch_wt=1
        done
        [ "$TARGET" != "$ORIG_BRANCH" ] && touch_wt=1
        [ "$touch_wt" = "1" ] && ensure_clean

        # 不在工作区上的分支，直接挪指针（不切分支、不动文件）
        for b in "${behind_list[@]}"; do
            [ "$b" = "$TARGET" ] && continue
            git update-ref "refs/heads/$b" "refs/remotes/$REMOTE/$b" \
                || die "更新分支 $b 失败"
            ok "$b 已快进 → $(git rev-parse --short "refs/heads/$b")"
        done

        # 目标分支：先切过去再快进，工作区才会跟着更新
        if [ "$TARGET" != "$(current_branch)" ]; then
            switch_to "$TARGET"
        fi
        for b in "${behind_list[@]}"; do
            [ "$b" = "$(current_branch)" ] || continue
            git merge --ff-only "refs/remotes/$REMOTE/$b" >/dev/null 2>&1 \
                || die "快进 $b 失败，把上面的 git 报错贴出来"
            ok "$b 已快进 → $(git rev-parse --short "$b")"
        done
    else
        ok "本地与 $REMOTE 一致，无需更新"
    fi

    # 回到该停的分支
    switch_to "$TARGET"
}

# ============================================================
#  pack
# ============================================================
cmd_pack() {
    local dir; dir=$(abspath "${1:-$MEDIA}")
    [ -d "$dir" ] || die "目录不存在：$dir
  U 盘没挂上？或者传一个目录：$ME pack /path/to/dir"
    [ -w "$dir" ] || die "目录不可写：$dir"

    ensure_config
    ensure_no_operation
    sync_remote

    nxt "确定打包范围"
    # 打包范围 = 远端存在的分支（远端是唯一真相源）
    #   本地有、远端没有 → 不打包（那是本机私货，推上去才能出去）
    #   远端有、本地没有 → sync_remote 已经把它建成同名本地分支了，正常打包
    local -a pack_refs=() skipped=()
    local b
    if has_remote && [ "$SYNC_SKIP_REMOTE" != "1" ]; then
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            git rev-parse --verify --quiet "refs/heads/$b" >/dev/null \
                && pack_refs+=("refs/heads/$b")
        done < <(remote_branches)
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            git rev-parse --verify --quiet "refs/remotes/$REMOTE/$b" >/dev/null \
                || skipped+=("$b")
        done < <(local_branches)
    else
        warn "没有可用的 $REMOTE（或设了 SYNC_SKIP_REMOTE=1），只能打本地全部分支"
        while IFS= read -r b; do
            [ -n "$b" ] || continue
            pack_refs+=("refs/heads/$b")
        done < <(local_branches)
    fi

    [ ${#pack_refs[@]} -gt 0 ] || die "远端一个分支都没有，没东西可打包
  先推一个分支上去：git push $REMOTE <分支>"

    info "进包分支 ${#pack_refs[@]} 条、标签 $(git for-each-ref refs/tags/ | wc -l | tr -d ' ') 个："
    for b in "${pack_refs[@]}"; do
        printf '        %-28s %s\n' "${b#refs/heads/}" "$(git rev-parse --short "$b")"
    done
    if [ ${#skipped[@]} -gt 0 ]; then
        echo
        warn "这些分支远端没有，本次不打包：${skipped[*]}"
        info "要一起带走就先推：git push $REMOTE <分支>"
    fi

    nxt "打包"
    local stamp host out
    stamp=$(date +%Y%m%d-%H%M%S)
    host=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-')
    [ -n "$host" ] || host="machine"
    out="$dir/sync-${host}-${stamp}.bundle"
    [ -e "$out" ] && die "文件已存在：$out"

    git bundle create "$out" "${pack_refs[@]}" --tags >/dev/null 2>&1 \
        || die "打包失败（bundle create）"
    git bundle verify "$out" >/dev/null 2>&1 || die "包自校验失败，磁盘可能有问题：$out"

    # 校验文件固定写成 "hash  文件名"（两个空格），跨平台一致
    printf '%s  %s\n' "$(sha256_of "$out")" "$(basename "$out")" \
        > "$dir/$(basename "$out").sha256"

    ok "已生成 $(basename "$out")  $(du -h "$out" | awk '{print $1}')"
    info "sha256: $(cat "$out.sha256")"

    nxt "把这两个文件带到对面"
    info "$(basename "$out")"
    info "$(basename "$out").sha256"
    echo
    info "对面执行：$ME load <拷贝到的目录或那个 .bundle>"
    echo

    fixperm
}

# ============================================================
#  load
# ============================================================
# 注意：本函数在 $(...) 里跑，不能调 die（die 只会退掉子 shell，主流程会带着空路径继续）
resolve_pkg() {
    local src; src=$(abspath "$1")
    local p
    if [ -d "$src" ]; then
        # 包名末尾自带 YYYYMMDD-HHMMSS，按它排序比 mtime 可靠：
        # 同一秒连打两个包时 mtime 会打平，ls -t 的顺序就不确定了
        p=$(ls -1 "$src"/sync-*.bundle 2>/dev/null \
            | awk -F'-' '{print $(NF-1)"-"$NF" "$0}' \
            | sort | tail -1 | cut -d' ' -f2-)
        [ -n "$p" ] || p=$(ls -t "$src"/sync-*.bundle 2>/dev/null | head -1)
        if [ -z "$p" ]; then
            printf '[错误] 目录里没有 sync-*.bundle：%s\n' "$src" >&2
            printf '        U 盘没挂上？或者包放错目录了\n' >&2
            return 1
        fi
        # 提示必须走 stderr，否则会被 $(...) 当成路径的一部分
        printf '      自动选中最新包：%s\n' "$(basename "$p")" >&2
    elif [ -f "$src" ]; then
        p="$src"
    else
        printf '[错误] 找不到：%s\n' "$src" >&2
        return 1
    fi
    printf '%s\n' "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
}

cmd_load() {
    local bundle
    bundle=$(resolve_pkg "${1:-$MEDIA}") || die "没拿到包，已停下"

    ensure_no_operation

    nxt "校验文件"
    if [ -f "$bundle.sha256" ]; then
        if ( cd "$(dirname "$bundle")" && sha256sum -c "$(basename "$bundle").sha256" >/dev/null 2>&1 ); then
            ok "sha256 校验通过"
        else
            die "sha256 不匹配，文件在拷贝中损坏。重新拷，不要继续"
        fi
    else
        warn "没找到 .sha256，跳过校验"
    fi
    git bundle verify "$bundle" >/dev/null 2>&1 \
        || die "包损坏，或者不是这个仓库的包"

    ensure_config
    sync_remote

    nxt "读入包里的分支"
    # --prune：让 refs/remotes/peer/* 严格等于包里的分支集合。
    # 不加的话，对面删掉或不再打包的分支会一直挂着旧引用，
    # 既占空间，也会让"包里到底有什么"的判断失真。
    git fetch --prune "$bundle" "+refs/heads/*:refs/remotes/$PEER/*" "+refs/tags/*:refs/tags/*" >/dev/null 2>&1 \
        || die "从包里取引用失败"
    local pkg_list
    # %(refname:short) 会带上远端名（peer/dev），这里剥掉前缀只留分支名
    pkg_list=$(git for-each-ref --format='%(refname)' "refs/remotes/$PEER" \
        | sed "s|^refs/remotes/$PEER/||" | grep -v '^HEAD$' || true)
    [ -n "$pkg_list" ] || die "包里没有分支"
    info "包里有：$(printf '%s' "$pkg_list" | tr '\n' ' ')"

    nxt "把每个分支对到本地"
    local cur; cur=$(current_branch)
    local b r
    local to_create=() to_ff=() same_list=() conflicts=()

    while IFS= read -r b; do
        [ -n "$b" ] || continue
        r="refs/remotes/$PEER/$b"
        if ! git rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
            to_create+=("$b")
        elif git merge-base --is-ancestor "$r" "refs/heads/$b" 2>/dev/null; then
            same_list+=("$b")
        elif git merge-base --is-ancestor "refs/heads/$b" "$r" 2>/dev/null; then
            to_ff+=("$b")
        else
            conflicts+=("$b")
        fi
    done < <(printf '%s\n' "$pkg_list")

    # 先把结论说清楚，有问题一个字节都不动
    [ ${#same_list[@]} -gt 0 ] && info "已是最新：${same_list[*]}"
    [ ${#to_create[@]}  -gt 0 ] && info "本地没有，将新建：${to_create[*]}"
    [ ${#to_ff[@]}      -gt 0 ] && info "落后，将快进：${to_ff[*]}"

    if [ ${#conflicts[@]} -gt 0 ]; then
        warn "这些分支本机和包里都有对方没有的提交（分叉），脚本不替你合："
        for b in "${conflicts[@]}"; do
            info "$b  本地 +$(git rev-list --count "refs/remotes/$PEER/$b..refs/heads/$b")  包里 +$(git rev-list --count "refs/heads/$b..refs/remotes/$PEER/$b")"
        done
        echo
        info "自己合完再重跑本命令："
        info "  git checkout <分支> && git rebase $PEER/<分支>"
        echo
        die "有分支分叉，已停下（没有改动任何东西）"
    fi

    # 当前分支要被快进 → 工作区必须干净
    local need_clean=0
    for b in "${to_ff[@]}"; do [ "$b" = "$cur" ] && need_clean=1; done
    [ ${#to_create[@]} -gt 0 ] && [ "$need_clean" = "0" ] && [ -z "$(current_branch)" ] && need_clean=1
    [ "$need_clean" = "1" ] && ensure_clean

    # 1) 新建分支
    if [ ${#to_create[@]} -gt 0 ]; then
        for b in "${to_create[@]}"; do
            if ! has_commit; then
                # 空仓库：第一个建出来的分支要 checkout，工作区才会有文件
                backup_untracked_conflicts "refs/remotes/$PEER/$b"
                git checkout -b "$b" "refs/remotes/$PEER/$b" >/dev/null 2>&1 \
                    || die "从包里新建分支 $b 失败（工作区可能有冲突文件）"
                ok "已新建 $b（并切过去）= $(git log -1 --format='%h %s' "$b")"
            else
                git update-ref "refs/heads/$b" "refs/remotes/$PEER/$b" \
                    || die "新建分支 $b 失败"
                ok "已新建 $b = $(git rev-parse --short "$b")"
            fi
        done
    fi

    # 2) 非当前分支：直接挪指针，不动工作区
    for b in "${to_ff[@]}"; do
        [ "$b" = "$(current_branch)" ] && continue
        git update-ref "refs/heads/$b" "refs/remotes/$PEER/$b" || die "更新分支 $b 失败"
        ok "$b 已快进 → $(git rev-parse --short "$b")"
    done

    # 3) 当前分支：快进（工作区跟着变）
    for b in "${to_ff[@]}"; do
        [ "$b" = "$(current_branch)" ] || continue
        backup_untracked_conflicts "refs/remotes/$PEER/$b"
        if ! git merge --ff-only "refs/remotes/$PEER/$b" >/tmp/sync-merge.err 2>&1; then
            sed 's/^/      /' /tmp/sync-merge.err
            die "快进 $b 失败，上面是 git 的原话"
        fi
        ok "$b 已快进 → $(git rev-parse --short "$b")"
    done

    # 4) 停到该停的分支
    switch_to "$TARGET"
    # 人在工作分支上、被更新的又是别的分支时，给一句跟进提示
    case "$(current_branch)" in
        b/*)
            for b in "${to_ff[@]}"; do
                [ "$b" = "$(current_branch)" ] && continue
                info "$b 有新代码，要合进当前分支：git rebase $b"
            done
            ;;
    esac

    nxt "同步到本机 Gitea"
    if git remote get-url "$REMOTE" >/dev/null 2>&1; then
        local pushed=0 failed=0
        for b in "${to_create[@]}" "${to_ff[@]}"; do
            [ -n "$b" ] || continue
            if run_timeout "$SYNC_PUSH_TIMEOUT" git push "$REMOTE" "refs/heads/$b:refs/heads/$b" >/dev/null 2>&1; then
                pushed=$((pushed+1))
            else
                failed=$((failed+1)); FAILED_BRANCHES="$FAILED_BRANCHES $b"
            fi
        done
        if [ "$pushed" -gt 0 ]; then
            ok "已推送 $pushed 个分支到 $REMOTE"
        fi
        if [ "$failed" -gt 0 ]; then
            warn "$failed 个分支推送失败：$FAILED_BRANCHES"
            info "本机 Gitea 没起来 / 账号没权限，稍后手动：git push $REMOTE --all"
        fi
    else
        info "没有 $REMOTE，跳过推送"
    fi

    echo
    ok "完成，当前分支 $(current_branch) = $(git rev-parse --short HEAD 2>/dev/null)"
    fixperm
}

# ============================================================
#  branch（开工作分支）
# ============================================================
cmd_branch() {
    local name="${1:-}"
    [ -n "$name" ] || die "用法：$ME branch <名字>
  例：$ME branch 1103-修bug   → 会建 b/1103-修bug"
    case "$name" in
        b/*) ;;
        *)   name="b/$name" ;;
    esac
    ensure_config
    ensure_no_operation
    sync_remote

    git rev-parse --verify --quiet "refs/heads/$name" >/dev/null \
        && die "分支 $name 已存在，换个名字，或直接：git checkout $name"

    local base; base=$(current_branch)
    [ -n "$base" ] && [ "$base" = "$TARGET" ] || base="$TARGET"

    # 已经在工作分支上就接着往下开，不跳回主分支，免得丢上下文
    case "$(current_branch)" in
        b/*) base="$(current_branch)"; info "接着当前的 $base 往下开（已含它上面的提交）" ;;
    esac

    [ "$(current_branch)" = "$base" ] || { ensure_clean; git checkout "$base" >/dev/null 2>&1 || die "切不到 $base"; }
    git checkout -b "$name" >/dev/null 2>&1 || die "建分支失败"
    ok "已切到 $name（基于 $base）"
    info "改完：git add -A && git commit -m \"说明\""
    info "推上去（不推不会进包）：git push $REMOTE $name"
    info "然后：$ME pack <U 盘目录>"
    info "下次运行本脚本会自动回到 $TARGET；要留在这个分支上就设 SYNC_BRANCH=$name"
    fixperm
}

# ============================================================
#  status（只读）
# ============================================================
cmd_status() {
    ORIG_BRANCH=$(current_branch)
    TARGET=$(decide_target)

    sec "仓库"
    info "路径 : $REPO"
    info "分支 : ${ORIG_BRANCH:-（还没有提交）}"
    info "提交 : $(git log -1 --format='%h %s' 2>/dev/null)"
    info "远端 : $(git remote get-url "$REMOTE" 2>/dev/null || echo "（没有 $REMOTE）")"
    if [ -f "$ENV_FILE" ]; then
        info "配置 : $ENV_FILE"
    else
        info "配置 : $ENV_FILE（不存在，全部用默认值）"
    fi
    info "停留 : ${TARGET:-（未定）}${BRANCH:+  ← SYNC_BRANCH 指定}"
    info "权限 : ${PERM:-（不处理）}    filemode=$(git config core.filemode || echo '未设')"

    # 只 fetch 不改分支，让下面的 ahead/behind 是新的
    local fetched=0
    if has_commit && [ "$SYNC_SKIP_REMOTE" != "1" ] && git remote get-url "$REMOTE" >/dev/null 2>&1; then
        git fetch "$REMOTE" --prune --tags >/dev/null 2>&1 && fetched=1
    fi

    sec "分支与远端"
    local b st any=0
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        any=1
        st=$(branch_state "$b")
        case "$st" in
            same)       printf '  %-28s %s  与远端一致\n' "$b" "$(git rev-parse --short "refs/heads/$b")" ;;
            behind)     printf '  %-28s %s  落后 %s 个提交（运行任一命令会自动快进）\n' \
                            "$b" "$(git rev-parse --short "refs/heads/$b")" \
                            "$(git rev-list --count "refs/heads/$b..refs/remotes/$REMOTE/$b")" ;;
            ahead)      printf '  %-28s %s  领先 %s 个提交（未推送）\n' \
                            "$b" "$(git rev-parse --short "refs/heads/$b")" \
                            "$(git rev-list --count "refs/remotes/$REMOTE/$b..refs/heads/$b")" ;;
            diverged)   printf '  %-28s %s  已分叉（需要手工处理）\n' "$b" "$(git rev-parse --short "refs/heads/$b")" ;;
            local-only) printf '  %-28s %s  远端没有（不会进包，先 git push）\n' "$b" "$(git rev-parse --short "refs/heads/$b")" ;;
        esac
    done < <(local_branches)
    [ "$any" = "1" ] || info "（还没有任何分支）"
    [ "$fetched" = "1" ] || info "（远端状态未刷新）"

    # 远端有、本地还没有的分支：pack/load/branch 任意一个命令跑下去就会自动建出来
    local rb shown_r=0
    while IFS= read -r rb; do
        [ -n "$rb" ] || continue
        git rev-parse --verify --quiet "refs/heads/$rb" >/dev/null && continue
        if [ "$shown_r" = "0" ]; then
            info "远端有、本地还没有（运行任一命令会自动拉下来）："
            shown_r=1
        fi
        printf '  %-28s %s\n' "$rb" "$(git rev-parse --short "refs/remotes/$REMOTE/$rb")"
    done < <(remote_branches)

    sec "工作区"
    local n u
    n=$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
    if [ "${n:-0}" -eq 0 ]; then ok "没有未提交的改动"
    else warn "$n 个已跟踪文件有改动（不影响打包，但不在任何分支里）"; fi
    u=$(git status --porcelain 2>/dev/null | grep -c '^??' || true)
    info "未跟踪文件：${u:-0} 个（数据/配置一般在这里，不会被同步影响）"

    local pany=0
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        if [ "$pany" = "0" ]; then sec "上次从包里收到的分支"; pany=1; fi
        printf '  %-28s %s\n' "$b" "$(git rev-parse --short "refs/remotes/$PEER/$b")"
    done < <(git for-each-ref --format='%(refname)' "refs/remotes/$PEER" 2>/dev/null \
                | sed "s|^refs/remotes/$PEER/||" | grep -v '^HEAD$' || true)
    echo
}

# ============================================================
#  usage
# ============================================================
usage() {
    local head="" fixline
    [ -z "${REPO:-}" ] && locate
    [ -z "${TARGET:-}" ] && [ -n "$BRANCH" ] && TARGET="$BRANCH"
    [ -n "${REPO:-}" ]   && head="$head
  仓库：$REPO"
    [ -n "${TARGET:-}" ] && head="$head
  停留：$TARGET$([ -n "$BRANCH" ] && printf '   ← SYNC_BRANCH 指定')"
    head="$head
  配置：$ENV_FILE"
    if [ -n "$PERM" ]; then
        fixline="把整个仓库权限刷成 $PERM"
    else
        fixline="按 SYNC_PERM 刷权限（当前配置为不处理）"
    fi

    cat <<EOF
$ME — 不通网的两台机器之间同步整个仓库（不分 A/B，两端平等）
$head

命令（都可以在任何目录执行，仓库自动找）：
  $ME pack   [目录]       打包「远端存在的」分支和标签（默认 $MEDIA）
  $ME load   [包或目录]    收下对面的包，逐分支快进（默认从 $MEDIA 找最新包）
  $ME status              看状态（只读）
  $ME branch <名字>        开工作分支 b/<名字> 并切过去
  $ME fixperm             $fixline
  $ME -r <仓库> <命令>      临时指定仓库目录

每次运行都会先和 $REMOTE 对齐：落后自动快进，领先/分叉停下等人处理；
远端有、本地没有的分支自动拉下来，本地有、远端没有的分支不会进包。
结束时停回你运行前所在的分支；env 里写 SYNC_BRANCH=xxx 就停在它上面。

日常一圈（谁改都一样，没有先后之分）：
  改代码的一端：  git add -A && git commit -m "说明" && git push $REMOTE <分支>
                  →   $ME pack /media/usb/toB
  收包的一端：    $ME load /media/usb/toB

配置（$ENV_FILE）：
  SYNC_BRANCH=dev            同步完停在这个分支（不写就停回原分支）
  SYNC_MEDIA=/media/usb      U 盘挂载点默认值
  SYNC_PERM=777              每次操作后刷成的权限；写成空串则跳过
  SYNC_REPO=/path/to/repo    仓库路径（脚本不在仓库里时用）
  SYNC_REMOTE=origin         远端名
  SYNC_ALLOW_LOCAL_AHEAD=1   本地领先远端也照常继续（默认停下）
  SYNC_SKIP_REMOTE=1         完全不碰远端（纯离线）
EOF
}

# ============================================================
#  入口
# ============================================================
warn_env_notes

# 全局选项：-r/--repo 指定仓库
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--repo) OPT_REPO="${2:-}"; [ -n "$OPT_REPO" ] || die "-r 后面要跟仓库路径"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

CMDNAME="${1:-}"
if [ "$CMDNAME" = "-h" ] || [ "$CMDNAME" = "--help" ] || [ "$CMDNAME" = "help" ]; then
    usage; exit 0
fi

resolve_repo
cd "$REPO" || die "进不去仓库目录：$REPO"

# 脚本被放进仓库里时提醒一句：它会随包一起走，覆盖对面的副本
case "$SCRIPT_DIR/" in
    "$REPO"/*)
        if git ls-files --error-unmatch -- "sync.sh" >/dev/null 2>&1 \
           || git ls-files --error-unmatch -- ".sync.env" >/dev/null 2>&1; then
            warn "脚本或配置放在仓库里了（$SCRIPT_DIR）"
            info "它们会随包同步、覆盖对面的副本，建议挪到仓库外面"
            echo
        fi
        ;;
esac

case "$CMDNAME" in
    pack|p)     shift; cmd_pack   "$@" ;;
    load|l)     shift; cmd_load   "$@" ;;
    branch)     shift; cmd_branch "$@" ;;
    status|s)   cmd_status ;;
    fixperm|f)  fixperm ;;
    "")         usage ;;
    merge|m)
        die "新版不再需要 merge：所有分支一起同步，直接合就行
  想合并分支：git checkout dev && git merge b/xxx && git push
  然后正常打包：$ME pack <U 盘目录>" ;;
    *) printf '未知命令：%s\n\n' "$CMDNAME"; usage; exit 1 ;;
esac
