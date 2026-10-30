# -*- coding: utf-8 -*-
"""生成 C-update.ipynb（一次性构建脚本，不交付给用户）

注意：C 端禁用 pathlib 与 tarfile，所以 notebook 里：
  - 路径与文件操作只用 os / os.path
  - 解包不用 tarfile：gzip 解压 + 自己按 512 字节块解析 tar
"""
import json, pathlib

md_intro = """# C 端代码更新（A → C 单向）

C 端没有 terminal，所以不用 git、不用命令行，全靠这个 notebook 完成更新。

> 环境限制：本 notebook **只用 `os` 和 `zlib`/`gzip` 这几个基础模块**，
> 不使用 `pathlib`、`tarfile`、`shutil`、`glob`。
> 路径全部手填绝对路径；解包用 gzip 解压 + 自带的小解析器（只认普通文件和目录）。

## 怎么用

1. **上传包**：把 A 端生成的 `c-update-*.tar.gz` 拖进本 notebook 所在目录
2. **改路径**：「第 1 步」那一格，把 `DEST` 和 `PKG_DIR` 改成真实绝对路径（只改一次，之后不用再动）
3. **依次运行**：菜单 `Run` → `Run All Cells`
4. **重启内核**：菜单 `Kernel` → `Restart Kernel`，让新代码生效

## 绝对路径怎么拿

- 先跑「第 1 步」，它会把**当前目录**打印出来。notebook 默认就在自己所在目录，所以
  打印出来的路径通常就是你要填的路径，直接抄进去即可。
- 也可以在左侧文件浏览器里找到文件夹 → 右键 → `Copy Path`。

## 它做了什么

| 步骤 | 说明 |
|:--:|---|
| 1 | 在 `PKG_DIR` 里找最新的 `c-update-*.tar.gz` |
| 2 | 校验 sha256（有 `.sha256` 就校验） |
| 3 | 解 gzip，再把 tar 拆成文件清单 |
| 4 | 检查包内路径，防止写到目录外面 |
| 5 | 把「即将被覆盖」的旧文件复制到 `_backup_时间/` |
| 6 | 逐个写出文件（覆盖） |
| 7 | 清掉 `__pycache__`（避免旧字节码残留） |
| 8 | 全部权限刷成 777（jupyter 环境需要） |

## 安全边界

- **只覆盖，不删除**：C 端独有的文件（数据、日志、备份）一个都不会动
- **有备份**：被替换的旧文件在 `_backup_时间戳/` 里，随时能翻回去
- **不碰数据**：包里只有 git 里登记过的代码文件
- **只认普通文件和目录**：包里的符号链接、设备文件一律跳过，不会被写出去
"""

cfg_code = '''import os, sys

# ============ 配置：填绝对路径（必须改成你自己的）============
# 1) 代码要更新到哪个目录 —— C 端那份 myproject 的绝对路径
DEST = "/path/to/myproject"

# 2) 上传的 c-update-*.tar.gz 放在哪个目录 —— 一般和本 notebook 同一目录
PKG_DIR = "/path/to/package_dir"
# =============================================================

print("Python   :", sys.version.split()[0])
print("当前目录 :", os.getcwd())
print("目标目录 :", DEST)
print("包目录   :", PKG_DIR)
print()

_need = []
if not os.path.isdir(os.path.expanduser(DEST)):
    _need.append("DEST")
if not os.path.isdir(os.path.expanduser(PKG_DIR)):
    _need.append("PKG_DIR")

if _need:
    print("[要改] 这些路径还不能用：%s" % "、".join(_need))
    print("       如果当前目录就是你要的目录，把它照抄上去，例如：")
    print('         DEST    = r"%s"' % os.getcwd())
    print('         PKG_DIR = r"%s"' % os.getcwd())
    print("       改完重跑本格，再往下走。")
else:
    print("[OK] 两个目录都存在，可以往下跑了。")
'''

probe_code = '''import os

_d = os.path.abspath(os.path.expanduser(DEST))
_p = os.path.abspath(os.path.expanduser(PKG_DIR))

print("==== 目标目录：%s ====" % _d)
if os.path.isdir(_d):
    for _name in sorted(os.listdir(_d)):
        if _name.startswith("."):
            continue
        _full = os.path.join(_d, _name)
        print(("  [目录] " if os.path.isdir(_full) else "  [文件] ") + _name)
else:
    print("  [错误] 这个目录不存在，回到「第 1 步」把 DEST 改对")

print()
print("==== 包目录：%s ====" % _p)
_pkgs = []
if os.path.isdir(_p):
    for _nm in os.listdir(_p):
        if _nm.startswith("c-update-") and _nm.endswith(".tar.gz"):
            _full = os.path.join(_p, _nm)
            if os.path.isfile(_full):
                _pkgs.append(_full)
    _pkgs.sort(key=os.path.getmtime, reverse=True)
if _pkgs:
    print("找到 %d 个包，下面最上面那个就是这次要用的：" % len(_pkgs))
    for _f in _pkgs:
        _kb = os.path.getsize(_f) / 1024.0
        print("  %-46s %s" % (os.path.basename(_f),
                              ("%.0f KB" % _kb) if _kb >= 1 else "<1 KB"))
else:
    print("  [还没找到] 这里没有 c-update-*.tar.gz")
    print("  先把 A 端生成的包上传到该目录，再重跑本格")
    print("  如果包在别的目录，回到「第 1 步」把 PKG_DIR 改到那个目录")

print()
print("确认上面这两个目录都对了，再往下跑「第 3 步」。")
'''

main_code = '''import os, time, zlib

DEST = os.path.realpath(os.path.abspath(os.path.expanduser(DEST)))
PKG_DIR = os.path.realpath(os.path.abspath(os.path.expanduser(PKG_DIR)))

assert os.path.isdir(DEST), "目标目录不存在：%s\\n请回到「第 1 步」修改 DEST" % DEST


# ================= 工具函数（只用 os / zlib，不用解包和文件管理类库） =================
def _find_pkgs(d):
    """找出目录下所有 c-update-*.tar.gz，按修改时间从新到旧"""
    out = []
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for nm in names:
        if nm.startswith("c-update-") and nm.endswith(".tar.gz"):
            full = os.path.join(d, nm)
            if os.path.isfile(full):
                out.append(full)
    out.sort(key=os.path.getmtime, reverse=True)
    return out


def _copy_file(src, dst):
    """复制文件（保留时间戳），等价于 copy2"""
    with open(src, "rb") as fh:
        data = fh.read()
    with open(dst, "wb") as fh:
        fh.write(data)
    try:
        os.utime(dst, (os.path.getatime(src), os.path.getmtime(src)))
    except OSError:
        pass


def _rmtree(path):
    """递归删目录，遇到删不掉的就跳过，不抛异常"""
    for root, dirs, files in os.walk(path, topdown=False):
        for name in files:
            try:
                os.remove(os.path.join(root, name))
            except OSError:
                pass
        for name in dirs:
            full = os.path.join(root, name)
            try:
                os.rmdir(full)
            except OSError:
                try:
                    os.remove(full)
                except OSError:
                    pass
    try:
        os.rmdir(path)
    except OSError:
        pass


def _gunzip(path):
    """解 gzip。优先用 gzip 模块；万一被禁，退回 zlib 手解。"""
    try:
        import gzip
    except ImportError:
        gzip = None

    with open(path, "rb") as fh:
        head = fh.read(2)
    assert head == b"\\x1f\\x8b", (
        "不是 gzip 文件，可能传错了或没传完整：%s" % os.path.basename(path))

    if gzip is not None:
        try:
            with gzip.open(path, "rb") as fh:
                return fh.read()
        except Exception as e:
            raise AssertionError("解压失败，包可能已损坏：%s（%s: %s）"
                                 % (os.path.basename(path), type(e).__name__, e))

    raw = open(path, "rb").read()
    assert raw[:2] == b"\\x1f\\x8b", "不是 gzip 文件：%s" % path
    flg = raw[3]
    pos = 10
    if flg & 4:                      # FEXTRA
        xlen = raw[pos] | (raw[pos + 1] << 8)
        pos += 2 + xlen
    if flg & 8:                      # FNAME
        pos = raw.index(b"\\0", pos) + 1
    if flg & 16:                     # FCOMMENT
        pos = raw.index(b"\\0", pos) + 1
    if flg & 2:                      # FHCRC
        pos += 2
    d = zlib.decompressobj(-zlib.MAX_WBITS)
    return d.decompress(raw[pos:]) + d.flush()


def _oct(b):
    """tar 头的数字字段是八进制 ASCII，可能带空格/空字节"""
    b = b.split(b"\\0")[0].strip()
    if not b:
        return 0
    try:
        return int(b, 8)
    except ValueError:
        return 0


def _pax(data):
    """pax 扩展头记录格式：<长度> <key>=<value>\\\\n"""
    out = {}
    pos = 0
    n = len(data)
    while pos < n:
        sp = data.find(b" ", pos)
        if sp < 0:
            break
        try:
            ln = int(data[pos:sp])
        except ValueError:
            break
        if ln <= 0 or pos + ln > n:
            break
        body = data[sp + 1:pos + ln].rstrip(b"\\n")
        k, _, v = body.partition(b"=")
        out[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        pos += ln
    return out


def _read_tar(blob):
    """把 tar 内容拆成 [(kind, name, data)]，kind 只有 'f'(文件) 和 'd'(目录)"""
    out = []
    i = 0
    n = len(blob)
    longname = ""
    paxpath = ""
    while i + 512 <= n:
        h = blob[i:i + 512]
        if h == b"\\0" * 512:                  # 结束标记
            break
        name = h[0:100].split(b"\\0")[0].decode("utf-8", "replace")
        prefix = h[345:500].split(b"\\0")[0].decode("utf-8", "replace")
        typ = h[156:157]
        size = _oct(h[124:136])
        data = blob[i + 512:i + 512 + size]
        i += 512 + ((size + 511) // 512) * 512

        if typ == b"L":                        # GNU 超长文件名
            longname = data.split(b"\\0")[0].decode("utf-8", "replace").strip()
            continue
        if typ in (b"x", b"g"):                # pax 扩展头
            rec = _pax(data)
            if typ == b"x" and rec.get("path"):
                paxpath = rec["path"]
            continue

        if longname:                           # 名称优先取扩展头里的
            name = longname
            longname = ""
        elif paxpath:
            name = paxpath
            paxpath = ""
        elif prefix:
            name = prefix + "/" + name

        if typ in (b"0", b"\\0", b"7"):
            out.append(("f", name, data))
        elif typ == b"5":
            out.append(("d", name, b""))
        # 其它类型（符号链接、硬链接、设备文件）直接跳过
    return out
# ============================================================


# ---------- 1. 找最新的包 ----------
pkgs = _find_pkgs(PKG_DIR)
assert pkgs, "没找到 c-update-*.tar.gz\\n请先把 A 端生成的包上传到：%s" % PKG_DIR

pkg = pkgs[0]
_kb = os.path.getsize(pkg) / 1024.0
print("使用包  :", os.path.basename(pkg),
      "(%s)" % (("%.0f KB" % _kb) if _kb >= 1 else "<1 KB"))
if len(pkgs) > 1:
    print("         同目录另有 %d 个旧包，已忽略" % (len(pkgs) - 1))

# ---------- 1b. 校验 sha256（A 端把 .sha256 一起传上来时）----------
_shaf = pkg + ".sha256"
try:
    import hashlib
except ImportError:
    hashlib = None

if os.path.isfile(_shaf) and hashlib is not None:
    with open(_shaf, "r", encoding="utf-8") as fh:
        want = fh.read().split()[0].strip().lower()
    h = hashlib.sha256()
    with open(pkg, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    got = h.hexdigest()
    assert got == want, ("sha256 不匹配，包在传输中可能损坏，请重新上传\\n"
                         "  期望 %s\\n  实际 %s" % (want, got))
    print("sha256  : 校验通过")
elif os.path.isfile(_shaf):
    print("sha256  : 这个环境里没有 hashlib，只能跳过校验")
else:
    print("sha256  : 没找到 .sha256 文件，跳过校验（不影响更新）")

# ---------- 2. 解 gzip + 拆 tar ----------
print("解压中  : 正在读取 %s" % os.path.basename(pkg))
blob = _gunzip(pkg)
entries = _read_tar(blob)
assert entries, "包里没有文件，可能包损坏或不是本工具的产物"
print("包内条目:", len(entries))
del blob

# ---------- 3. 路径安全校验 ----------
base = DEST.rstrip(os.sep) + os.sep
plan = []
bad = []
for kind, name, data in entries:
    nm = name.replace("\\\\", "/").lstrip("/")
    while nm.startswith("./"):
        nm = nm[2:]
    if nm in ("", "."):
        continue
    full = os.path.realpath(os.path.join(DEST, nm))
    if full != DEST and not full.startswith(base):
        bad.append(name)
        continue
    plan.append((kind, nm, data, full))
assert not bad, "包内含指向目录外的路径，已中止：%s" % bad[:5]

# ---------- 4. 备份将被覆盖的旧文件 ----------
stamp = time.strftime("%Y%m%d-%H%M%S")
bakdir = os.path.join(DEST, "_backup_" + stamp)
n_bak = 0
for kind, nm, data, full in plan:
    if kind != "f" or not os.path.isfile(full):
        continue
    dst = os.path.join(bakdir, nm)
    _p = os.path.dirname(dst)
    if _p:
        os.makedirs(_p, exist_ok=True)
    _copy_file(full, dst)
    n_bak += 1
print("已备份 %d 个旧文件 → %s"
      % (n_bak, os.path.basename(bakdir) if n_bak else "（无同名文件）"))

# ---------- 5. 写出文件（覆盖） ----------
n_new = 0
for kind, nm, data, full in plan:
    _p = os.path.dirname(full)
    if kind == "d":
        os.makedirs(full, exist_ok=True)
        continue
    if _p:
        os.makedirs(_p, exist_ok=True)
    with open(full, "wb") as fh:
        fh.write(data)
    n_new += 1
print("解压完成:", n_new, "个文件")

# ---------- 6. 清 __pycache__ ----------
n_pyc = 0
for root, dirs, files in os.walk(DEST):
    dirs[:] = [d for d in dirs if not d.startswith("_backup_")]
    if "__pycache__" in dirs:
        _rmtree(os.path.join(root, "__pycache__"))
        dirs.remove("__pycache__")
        n_pyc += 1
print("清理 __pycache__:", n_pyc, "个")

# ---------- 7. 权限刷 777 ----------
n_perm = 0
for root, dirs, files in os.walk(DEST):
    dirs[:] = [d for d in dirs if not d.startswith("_backup_")]
    try:
        os.chmod(root, 0o777)
        n_perm += 1
    except OSError:
        pass
    for f in files:
        try:
            os.chmod(os.path.join(root, f), 0o777)
            n_perm += 1
        except OSError:
            pass
print("权限已刷 777:", n_perm, "个条目")

# ---------- 8. 结果 ----------
print()
print("=" * 48)
print("更新完成")
print("  包    :", os.path.basename(pkg))
print("  目录  :", DEST)
print("  文件数:", sum(len(f) for _, d, f in os.walk(DEST)))
print("  备份  :", os.path.basename(bakdir) if n_bak else "（无需备份）")
print("=" * 48)
print()
print("下一步：Kernel → Restart Kernel，让新代码生效。")
'''

md_tail = """## 更新完要做什么

1. **重启内核**（`Kernel` → `Restart Kernel`），旧模块才会被替换成新代码
2. 打开你平时用的那个 notebook，从头跑一遍，确认结果正常

## 出问题怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `[要改] 这些路径还不能用` | `DEST` / `PKG_DIR` 还是示例值 | 照第 1 格打印的当前目录填上去 |
| `没找到 c-update-*.tar.gz` | 包没上传，或传到了别的目录 | 确认包在 `PKG_DIR` 指的那个目录里 |
| `sha256 不匹配` | 上传过程文件损坏 | 删掉重传一次 |
| `不是 gzip 文件` | 包没传完整，或误传了别的文件 | 重新上传 `.tar.gz` 本体 |
| `包里没有文件` | 包损坏 | 重新从 A 端生成 |
| `目标目录不存在` | `DEST` 写错 | 回「第 1 步」改 |
| `包内含指向目录外的路径` | 包不对劲 | 回 A 端重新生成 |
| 跑完结果还是旧的 | 没重启内核 | `Kernel` → `Restart Kernel` |
| 想回退 | 需要旧版本 | 打开 `_backup_时间戳/` 目录，把文件拷回去 |

## 这个目录里会多出什么

- `_backup_20261030-153000/` 这类目录 —— 每次更新时被替换掉的旧文件
- 空间紧张时可以直接删掉旧的 `_backup_*`，不影响运行

## 万一 notebook 报「不支持的文件类型」

包里的符号链接会被跳过（不报错）。如果将来 A 端代码里加了软链接而 C 端需要它，
告诉我，另想办法传。
"""

def lines(t):
    return t.splitlines(keepends=True)

nb = {
    "cells": [
        {"cell_type": "markdown", "metadata": {}, "source": lines(md_intro)},
        {"cell_type": "markdown", "metadata": {}, "source": ["## 第 1 步 · 配置（改路径）\n"]},
        {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
         "source": lines(cfg_code)},
        {"cell_type": "markdown", "metadata": {}, "source": ["## 第 2 步 · 看看目录里有什么\n"]},
        {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
         "source": lines(probe_code)},
        {"cell_type": "markdown", "metadata": {}, "source": ["## 第 3 步 · 执行更新\n"]},
        {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [],
         "source": lines(main_code)},
        {"cell_type": "markdown", "metadata": {}, "source": lines(md_tail)},
    ],
    "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python", "version": "3.11.6",
                          "mimetype": "text/x-python", "file_extension": ".py",
                          "codemirror_mode": {"name": "ipython", "version": 3},
                          "pygments_lexer": "ipython3", "nbconvert_exporter": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 5,
}

out = pathlib.Path(__file__).resolve().parent.parent / "notebook" / "C-update.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("已生成:", out, out.stat().st_size, "bytes")
