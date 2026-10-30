#!/usr/bin/env bash
# ============================================================
#  make-update-package.sh — 生成给「只读目标环境」的代码更新包
#
#  背景：目标环境（下文称 C 端）可能没有命令行、不能 git、不能 chmod，
#        只能通过网页上传文件 + 跑 notebook 来改文件。
#        所以这里用 `git archive` 导出一个 tar.gz，只含已提交的代码。
#
#  产物：
#     c-update-<日期>-<commit>.tar.gz
#     c-update-<日期>-<commit>.tar.gz.sha256
#
#  用法：
#     make-update-package.sh [-r 仓库目录] [-b 分支] [-o 输出目录]
#
#     -r, --repo     仓库目录；默认用当前目录所在的 git 仓库
#     -b, --branch   分支名；默认 dev
#     -o, --out      输出目录；默认当前目录
#     -h, --help     看帮助
#
#  也支持位置参数的老写法：
#     make-update-package.sh dev ~/Desktop
#     make-update-package.sh /path/to/myproject ~/Desktop
#     （第一个参数如果是仓库目录就当仓库，否则当分支）
# ============================================================
set -euo pipefail

ME=$(basename "$0")

die() { echo "[错误] $*" >&2; exit 1; }

usage() {
    cat <<EOF
$ME — 在 A 端生成给 C 端的更新包

用法:
  $ME [-r 仓库目录] [-b 分支] [-o 输出目录]

选项:
  -r, --repo    仓库目录（默认：当前目录所在的 git 仓库）
  -b, --branch  分支名（默认：dev）
  -o, --out     输出目录（默认：当前目录）
  -h, --help    显示本帮助

老写法（位置参数）也能用，第一个参数是仓库目录就当仓库，否则当分支：
  $ME dev ~/Desktop
  $ME /srv/project ~/Desktop

例:
  $ME -r /srv/project -o ~/Desktop
  $ME -b dev -o /tmp
EOF
}

# ---------- 解析参数 ----------
REPO_OPT=""
BRANCH_OPT=""
OUT_OPT=""
POS1=""
POS2=""
NPOS=0

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--repo)
            [ $# -ge 2 ] || die "$1 后面要跟仓库目录"
            REPO_OPT=$2; shift 2 ;;
        -b|--branch)
            [ $# -ge 2 ] || die "$1 后面要跟分支名"
            BRANCH_OPT=$2; shift 2 ;;
        -o|--out)
            [ $# -ge 2 ] || die "$1 后面要跟输出目录"
            OUT_OPT=$2; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            die "不认识的选项：$1（用 -h 看用法）" ;;
        *)
            case $NPOS in
                0) POS1=$1 ;;
                1) POS2=$1 ;;
                *) die "参数太多了：$1（用 -h 看用法）" ;;
            esac
            NPOS=$((NPOS + 1)); shift ;;
    esac
done

is_repo_dir() {
    [ -d "$1" ] && git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1
}

# ---------- 位置参数兜底（兼容老写法） ----------
if [ $NPOS -ge 1 ]; then
    if [ -z "$REPO_OPT" ] && is_repo_dir "$POS1"; then
        REPO_OPT=$POS1
        if [ $NPOS -ge 2 ] && [ -z "$OUT_OPT" ]; then OUT_OPT=$POS2; fi
    else
        if [ -z "$BRANCH_OPT" ]; then BRANCH_OPT=$POS1; fi
        if [ $NPOS -ge 2 ] && [ -z "$OUT_OPT" ]; then OUT_OPT=$POS2; fi
    fi
fi

BRANCH="${BRANCH_OPT:-dev}"
OUTDIR_RAW="${OUT_OPT:-.}"

# ---------- 展开 ~ ----------
case "$OUTDIR_RAW" in
    "~")     OUTDIR_RAW="$HOME" ;;
    "~/"*)   OUTDIR_RAW="$HOME/${OUTDIR_RAW#\~/}" ;;
esac

# ---------- 定位仓库 ----------
if [ -n "$REPO_OPT" ]; then
    [ -d "$REPO_OPT" ] || die "仓库目录不存在：$REPO_OPT"
    REPO=$(git -C "$REPO_OPT" rev-parse --show-toplevel 2>/dev/null) \
        || die "$REPO_OPT 不是 git 仓库（用 -r 指到仓库根目录）"
    # 给了 -r 却指到别人仓库的子目录时，git 会往上找到父仓库静默打包，
    # 那不是你想要的结果，直接拦下来并告诉他正确的路径
    if [ ! -e "$REPO_OPT/.git" ]; then
        if [ "$(cd "$REPO_OPT" && pwd -P)" != "$(cd "$REPO" && pwd -P)" ]; then
            die "$REPO_OPT 不是仓库根目录，它属于上层仓库：
       $REPO
       请把 -r 改成上面这个路径"
        fi
    fi
else
    REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
        || die "当前目录不在 git 仓库里，请用 -r 指定仓库目录"
    if [ "$(pwd -P)" != "$(cd "$REPO" && pwd -P)" ]; then
        echo "[提示] 你不在仓库根目录，实际使用的是：$REPO"
        echo
    fi
fi

# 输出目录转成绝对路径（必须在 cd 进仓库之前做，
# 否则相对路径会被解释成"相对仓库"，包就跑到别的地方去了）
mkdir -p "$OUTDIR_RAW" || die "无法创建输出目录：$OUTDIR_RAW"
OUTDIR=$(cd "$OUTDIR_RAW" && pwd)
[ -w "$OUTDIR" ] || die "输出目录不可写：$OUTDIR（换一个目录，或加 sudo）"

cd "$REPO"

# ---------- 校验分支 ----------
REF="$BRANCH"
if ! git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    if git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" >/dev/null; then
        REF="origin/$BRANCH"
        echo "[提示] 本地没有 $BRANCH 分支，改用 origin/$BRANCH 打包"
        echo "       （不是本机最新代码，本地改过的东西不会进包）"
        echo
    else
        echo "[错误] 仓库里没有分支 $BRANCH   仓库：$REPO" >&2
        echo "       现有本地分支：" >&2
        git for-each-ref --format='         %(refname:short)' refs/heads/ >&2
        exit 1
    fi
fi

# 未提交的改动不会进包，提醒一下
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
if [ -n "$DIRTY" ]; then
    echo "[提示] 工作区有未提交的改动，这些不会进包："
    printf '%s\n' "$DIRTY" | head -5 | sed 's/^/         /'
    echo
fi

# ---------- 出包 ----------
SHA=$(git rev-parse --short "$REF")
DATE=$(date +%Y%m%d)
BASE="c-update-$DATE-$SHA"
OUT="$OUTDIR/$BASE.tar.gz"

# 同一个 commit 同一天重复打包时，加时分秒后缀，不覆盖也不报错
if [ -e "$OUT" ]; then
    BASE="$BASE-$(date +%H%M%S)"
    OUT="$OUTDIR/$BASE.tar.gz"
fi

echo "仓库 : $REPO"
echo "分支 : $BRANCH"
echo "提交 : $(git log -1 --format='%h %s' "$REF")"
echo "输出 : $OUT"
echo

# 只导出 git 里登记过的文件，不带 .git、不带未跟踪的数据文件
if ! git archive --format=tar.gz "$REF" > "$OUT"; then
    rm -f "$OUT"
    die "导出失败（输出目录不可写、磁盘满，或文件被占用）"
fi

SIZE=$(du -h "$OUT" | awk '{print $1}')
HASH=$(sha256sum "$OUT" | awk '{print $1}')
printf '%s  %s\n' "$HASH" "$(basename "$OUT")" > "$OUT.sha256"

echo "[OK] 已生成：$(basename "$OUT")   $SIZE"
echo "     sha256：$HASH"
echo
echo "下一步："
echo "  1. 把这**两个**文件一起上传到 C 端 JupyterLab（放同一个目录）："
echo "       $(basename "$OUT")"
echo "       $(basename "$OUT").sha256"
echo "  2. 打开 C-update.ipynb → Run All Cells"
echo "  3. 看到「更新完成」后 → Kernel → Restart Kernel"
echo
echo "提醒：包里只有代码，不含 docs/ 下的数据文件；也还没同步到 B。"
