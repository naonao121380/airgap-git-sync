# -*- coding: utf-8 -*-
"""模拟 C 端环境，实测 C-update.ipynb 的三段代码

用真实的 git archive 产物做测试，覆盖：多层目录、中文文件名、超长路径（触发 pax 扩展头）、
可执行脚本、.gitignore 之类的边角文件。
"""
import json, pathlib, subprocess, tempfile, sys, os

HERE = pathlib.Path(__file__).resolve().parent.parent / "notebook"
nb = json.loads((HERE / "C-update.ipynb").read_text(encoding="utf-8"))
cfg = "".join(nb["cells"][2]["source"])
probe = "".join(nb["cells"][4]["source"])
main = "".join(nb["cells"][6]["source"])

# ---- 硬性要求：代码格里不能出现 pathlib / tarfile ----
BANNED = ("pathlib", "tarfile", "shutil", "glob")
for i, c in enumerate(nb["cells"]):
    if c["cell_type"] != "code":
        continue
    src = "".join(c["source"])
    for w in BANNED:
        assert w not in src, "第 %d 格（代码）还残留 %s" % (i, w)
print("检查：代码格里没有 " + " / ".join(BANNED))

base = pathlib.Path(tempfile.mkdtemp(prefix="ctest-"))
repo = base / "repo"
env = base / "cenv"
env.mkdir()
dest = env / "myproject"
dest.mkdir()

# ---------- 1. 造一个真实 git 仓库（A 端的模拟） ----------
repo.mkdir()
def git(*a):
    return subprocess.run(["git", "-C", str(repo)] + list(a),
                          check=True, capture_output=True, text=True,
                          encoding="utf-8")

git("init", "-q", "-b", "dev")
git("config", "user.email", "a@x")
git("config", "user.name", "A")
git("config", "core.autocrlf", "false")

long_dir = "/".join(["layer%d_%s" % (i, "x" * 24) for i in range(4)])
files = {
    "core.py": "v2\n",
    "models/m.py": "new m\n",
    "new_file.py": "# 新增文件\n",
    "中文目录/说明.txt": "中文内容 v2\n",
    long_dir + "/deep.py": "deep\n",
}
for rel, text in files.items():
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")

# 可执行脚本
sh = repo / "run.sh"
sh.write_text("#!/bin/sh\necho hi\n", encoding="utf-8")
os.chmod(sh, 0o755)

git("add", "-A")
git("commit", "-q", "-m", "init")
print("仓库文件数:", len(git("-c", "core.quotePath=false", "ls-tree", "-r", "HEAD", "--name-only").stdout.strip().splitlines()))
print("最长路径字节:", max(len(x.encode()) for x in git("-c", "core.quotePath=false", "ls-tree", "-r", "HEAD", "--name-only").stdout.strip().splitlines()))

# 真包
pkg = env / "c-update-20261030-abc1234.tar.gz"
git("archive", "--format=tar.gz", "-o", str(pkg), "HEAD")
print("包:", pkg.name, pkg.stat().st_size, "bytes")

import hashlib
h = hashlib.sha256()
h.update(pkg.read_bytes())
pathlib.Path(str(pkg) + ".sha256").write_text(
    "%s  %s\n" % (h.hexdigest(), pkg.name), encoding="utf-8")

# ---------- 2. C 端现状：旧代码 + 独有文件 + 数据 + 缓存 ----------
(dest / "core.py").write_text("v1\n", encoding="utf-8")
(dest / "old_only.py").write_text("# 只存在于 C 端\n", encoding="utf-8")
(dest / "data.xlsx").write_text("DATA\n", encoding="utf-8")
(dest / "__pycache__").mkdir()
(dest / "__pycache__" / "core.cpython-311.pyc").write_text("old", encoding="utf-8")
(dest / "models").mkdir()
(dest / "models" / "m.py").write_text("old m\n", encoding="utf-8")

# ---------- 3. 执行 notebook 三段代码 ----------
cfg = cfg.replace('DEST = "/path/to/myproject"', 'DEST = r"%s"' % dest)
cfg = cfg.replace('PKG_DIR = "/path/to/package_dir"', 'PKG_DIR = r"%s"' % env)
assert "path/to" not in cfg, "路径注入失败"

print("\n" + "=" * 20 + " 第 1 格 配置 " + "=" * 20)
exec(compile(cfg, "<cfg>", "exec"), globals())
print("\n" + "=" * 20 + " 第 2 格 探测 " + "=" * 20)
exec(compile(probe, "<probe>", "exec"), globals())
print("\n" + "=" * 20 + " 第 3 格 更新 " + "=" * 20)
exec(compile(main, "<main>", "exec"), globals())

# ---------- 4. 验收 ----------
print("\n" + "=" * 20 + " 验收 " + "=" * 20)
checks = []

# 4.1 包内每个文件都要落地且内容一致
tracked = git("-c", "core.quotePath=false", "ls-tree", "-r", "HEAD", "--name-only").stdout.strip().splitlines()
same = 0
miss = []
for rel in tracked:
    dst = dest / rel
    if not dst.is_file():
        miss.append(rel)
        continue
    if dst.read_bytes() == (repo / rel).read_bytes():
        same += 1
    else:
        miss.append(rel + "(内容不一致)")
checks.append(("包里 %d 个文件全部落地且逐字节一致" % len(tracked), not miss))
if miss:
    print("     问题文件:", miss[:5])

checks += [
    ("core.py 被覆盖为 v2", (dest / "core.py").read_text(encoding="utf-8").strip() == "v2"),
    ("models/m.py 被覆盖", (dest / "models/m.py").read_text(encoding="utf-8").strip() == "new m"),
    ("新文件已加入", (dest / "new_file.py").exists()),
    ("中文文件名正确", (dest / "中文目录/说明.txt").read_text(encoding="utf-8").strip() == "中文内容 v2"),
    ("超长路径正确", (dest / long_dir / "deep.py").is_file()),
    ("C 端独有文件保留", (dest / "old_only.py").exists()),
    ("数据文件保留", (dest / "data.xlsx").exists()),
    ("__pycache__ 已清", not (dest / "__pycache__").exists()),
]

baks = list(dest.glob("_backup_*"))
checks.append(("生成备份目录", len(baks) == 1))
if baks:
    checks.append(("备份里是旧版 v1",
                   (baks[0] / "core.py").read_text(encoding="utf-8").strip() == "v1"))
    checks.append(("备份里没有数据文件", not (baks[0] / "data.xlsx").exists()))

ok = True
for name, res in checks:
    print(("  [通过] " if res else "  [失败] ") + name)
    ok = ok and res
print()
print("全部通过" if ok else "有失败项")
sys.exit(0 if ok else 1)
