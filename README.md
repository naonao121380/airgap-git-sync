# airgap-git-sync

**让 Git 在断网的环境中继续工作。**

> Keep Git working across air-gapped machines — with nothing but a USB stick.
> No SSH, no VPN, no shared network, no extra server.

一句话：**代码在三个网络互不相通的环境之间流转，靠 U 盘和 `git bundle` 完成，两边都能改，历史不丢。**

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   A 开发机   │   ✕     │   B 测试机   │   ✕     │   C 生产机   │
│  通公网      │ ──U盘──▶│  内网隔离     │ ──U盘──▶│  JupyterLab │
│             │ ◀──U盘──│             │         │  无 terminal │
└─────────────┘         └─────────────┘         └─────────────┘
      双向                   双向                    单向进
```

本仓库就是为这个拓扑写的，包含**两个独立功能**，可以只用其中一个：

| 功能 | 方向 | 用到的文件 |
|---|---|---|
| **一、两台断网机器之间双向同步** | A ↔ B | `scripts/sync.sh` |
| **二、单向更新到 Jupyter 环境** | A → C | `scripts/make-update-package.sh` + `notebook/C-update.ipynb` |

---

# 功能一 · 两个网络不通的地方，双向同步代码

## 它解决什么

A 和 B 都有完整仓库，都能改代码，但两台机器之间没有一个能通的端口。既不能用 `clone`/`fetch`，也不能 `rsync`/`scp`。

于是：**把提交打包成一个文件，U 盘搬过去，当远程仓库用。**

```bash
# A 端：打包（一个文件，含完整历史）
~/sync.sh pack /media/usb/toB

# B 端：导入（快进到最新，历史完整）
~/sync.sh load /media/usb/toB
```

`git bundle` 是关键 —— 它是 git 内置能力，产出的文件可以直接当 remote 用，能 fetch、能校验、能快进、带完整提交历史。**不需要在两端装任何东西。**

## 双向怎么保证不打架

这是整套方案里唯一需要设计的地方。如果两端都执行 `merge`，会各自生成一个内容相同但 **sha 不同**的合并提交，历史永久分叉：

```
A: dev → M1(sha=aaa)     内容一致
B: dev → M2(sha=bbb)     sha 不一致  ← 从此对不上
```

所以强制一条规则：**合并只在 A 端发生，B 端只能开提案分支。**

```
B 端改代码：
  ~/sync.sh branch 1030-fix        # 开 b/1030-fix，不在 dev 上直接改
  git add -A && git commit -m "修了 xxx"
  ~/sync.sh pack /media/usb/toA

A 端合并：
  ~/sync.sh load /media/usb/toA
  ~/sync.sh merge b/1030-fix       # --no-ff 合并 + 推送
  ~/sync.sh pack /media/usb/toB

B 端收结果：
  ~/sync.sh load /media/usb/toB
```

脚本带护栏：B 端如果在 `dev` 上有本地提交，`status` 报警、`export` 直接拒绝并给出搬运命令。

## 六条命令

| 命令 | 在哪跑 | 作用 |
|---|---|---|
| `sync.sh pack [目录]` | 两端 | 打包当前仓库到 U 盘 |
| `sync.sh load [包或目录]` | 两端 | 从 U 盘导入，自动选最新包 |
| `sync.sh branch <名字>` | B 端 | 开 `b/<名字>` 提案分支 |
| `sync.sh merge <分支>` | **只能 A 端** | 合并进 `dev` 并推送 |
| `sync.sh status` | 两端 | 看分支、远端、权限状态 |
| `sync.sh fixperm` | 两端 | 单独把仓库权限刷成 777 |

每次搬运都做三件事：**校验 sha256 → 快进/导入 → 刷权限**。

细节见 [docs/02-two-way-sync.md](docs/02-two-way-sync.md)。

---

# 功能二 · 同步进 Jupyter 环境（没有 terminal）

## 它解决什么

目标环境（下图 C）是一个**禁用了 terminal 的 JupyterLab**：不能开命令行、不能装 git、不能 `chmod`、不能解压。能做的只有三件事：

1. 通过网页上传文件
2. 打开 notebook
3. 运行单元格

这种情况下，`git` 完全用不上，`sync.sh` 也跑不起来。所以换一条路：**A 端打一个只含代码的 tar.gz，C 端用一个 notebook 解压覆盖。**

```
   A 端                                   C 端 JupyterLab
   make-update-package.sh  ──tar.gz──▶   上传两个文件
   （git archive 导出代码）                打开 C-update.ipynb
                                         Run All Cells
                                         Restart Kernel
```

## 两边的用法

```bash
# A 端出包（不用 cd 进仓库）
./scripts/make-update-package.sh -r /srv/project -o ~/Desktop
# → c-update-20261030-a1b2c3d.tar.gz
# → c-update-20261030-a1b2c3d.tar.gz.sha256
```

C 端：两个文件拖进 JupyterLab → 打开 `C-update.ipynb` → `Run All Cells` → 看到「更新完成」→ `Kernel → Restart Kernel`。

## 为什么这个 notebook 要自己写 tar 解析器

这类受限环境往往把常用库也禁掉。这个 notebook 踩过的清单：

| 库 | 状态 | 替代方案 |
|---|---|---|
| `pathlib` | ❌ 被禁 | 全部换 `os.path` |
| `tarfile` | ❌ 被禁 | 自己按 512 字节块解析 tar |
| `shutil` | ❌ 被禁 | 自写 `_copy_file` / `_rmtree` |
| `glob` | ❌ 被禁 | `os.listdir` + 前后缀匹配 |
| `gzip` | ⚠️ 可选 | 缺失时用 `zlib` 手解 gzip 头 |
| `hashlib` | ⚠️ 可选 | 缺失时跳过 sha256 校验（不影响更新） |

**实际只依赖 `os` 和 `zlib`。** 手写的 tar 解析器支持三种长文件名写法：ustar 前缀、pax 扩展头、GNU 长名 —— 150 字节以上的深路径也能正确还原。

## 除了解压，它还做了这些

- **sha256 校验**：上传损坏直接拦下，不会解出残缺代码
- **`../` 路径穿越拦截**：包里有跳出目标目录的路径就中止
- **覆盖前自动备份**：被替换的文件进 `_backup_<时间戳>/`，想回退直接拷回去
- **只覆盖不删除**：C 端独有的文件、数据文件、日志一个都不动
- **清 `__pycache__`**：不清会出现"代码更新了但结果还是旧的"
- **递归 777**：适配容器权限

细节见 [docs/03-air-gapped-update.md](docs/03-air-gapped-update.md)。

---

## 为什么不用别的方式

| 方案 | 在隔离环境里为什么不行 |
|---|---|
| `git clone` / `fetch` | 需要网络可达 |
| `rsync` / `scp` | 需要网络可达 |
| 直接拷整个目录 | 会带上 `.git` 锁文件、脏工作区、几十 GB 缓存；无校验，拷坏了不知道 |
| 两端各自 `merge` | 生成两个不同 sha 的合并提交，历史永久分叉 |
| 手动 diff + 复制文件 | 分支、提交信息、作者、时间全丢 |

---

## 其它设计决策

**未跟踪文件冲突自动让路。** A 提交了新文件，B 本地恰好有同名但未跟踪的文件（配置、数据），快进会被 git 拒绝。`sync.sh load` 会先把 B 的文件改名成 `xxx.preload-<时间戳>` 再放行，不删任何东西。

**777 权限与 `core.filemode`。** 容器固定 uid、SMB 共享时常常只能全刷 777，这会让 git 把每个文件标成 `mode change 100644 => 100755`。脚本每次执行都设 `core.filemode false`，权限位彻底退出 diff，`git status` 保持干净。

**`.git` 应该放在哪一层。** 容器挂载、SMB、Windows 客户端混用时，`.git` 放错位置会导致 refs 被写成全零（极难定位）。结论和取舍见 [docs/01-architecture.md](docs/01-architecture.md)。

---

## 实测范围

不是设计文档，是跑通过的东西：

- **A ↔ B 完整闭环**：A 改 → B 快进 → B 开分支改 → A 导入 → A `--no-ff` 合并推送 → 再打包 → B 快进。两端 `dev` 指向同一 sha，文件逐字节一致
- **C 端更新**：用真实 `git archive` 产物测试，覆盖深层目录、150+ 字节长路径、中文文件名、可执行脚本；12 项验收全通过
- **边界**：sha256 不符、非 gzip 文件、`../` 路径穿越、目标目录不存在、包内有符号链接 —— 全部正确拦截或跳过
- **C 端独有文件**：故意放数据文件、日志、本地配置，更新后全部保留

可重跑的测试：

```bash
python tools/build_notebook.py      # 从源码重新生成 ipynb
python tools/test_notebook.py       # 模拟 C 端环境实测
```

---

## 三条铁律

1. **同一时刻只允许一个写入者。** 不要一边用 Windows 图形客户端、一边在服务器上操作同一个仓库。SMB 上的并发写入能把 refs 写成全零，事后极难定位。
2. **合并只在 A 端做。** B 端只开提案分支。
3. **每次搬运都带 sha256 校验。** 别直接拷文件夹，别信"应该没坏"。

---

## 目录

| 路径 | 说明 |
|---|---|
| `scripts/sync.sh` | 功能一：A ↔ B 双向同步 |
| `scripts/make-update-package.sh` | 功能二：生成 C 端更新包 |
| `notebook/C-update.ipynb` | 功能二：C 端执行的 notebook |
| `docs/01-architecture.md` | `.git` 该放在哪一层（Docker / SMB / 挂载） |
| `docs/02-two-way-sync.md` | 功能一完整手册 |
| `docs/03-air-gapped-update.md` | 功能二完整手册 |
| `docs/04-bootstrap-checklist.md` | 从零上线清单（Gitea 初始化 → 导入 → 装脚本） |
| `docs/05-git-cheatsheet.md` | 按场景组织的命令速查 |
| `tools/` | notebook 生成器 + 端到端测试 |

---

## 环境要求

- 两端都有 `git`（≥ 2.20，用到 `git switch` 和 `bundle`）
- 一个能被两端读写的介质：U 盘、移动硬盘，或任何文件传输通道
- Linux / macOS / WSL 直接可用；Windows 建议在 Git Bash 里跑（`scripts/` 是 bash）

## 已知限制

- **只同步一条主线**（默认 `dev`）。要多条就改 `SYNC_BRANCH` 或扩展 `pack` 的 refspec
- **不搬数据文件**。更新包只含 git 提交过的代码，几 GB 数据集请单独用移动硬盘拷
- **不搬 stash / reflog**。`bundle` 只带提交和引用
- **C 端的改动回不来**。没有 git 就没有回流路径，别让 C 端当开发环境
- **真冲突需要人工解决**。`merge` 遇到真冲突会停下并列出冲突文件

## License

MIT。
