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

于是：**把整个仓库打包成一个文件，U 盘搬过去，当远程仓库用。**

```bash
# 一端：打包（一个文件，含远端存在的所有分支和标签）
sync.sh pack /media/usb/toB

# 另一端：导入（逐分支快进，历史完整）
sync.sh load /media/usb/toB
```

`git bundle` 是关键 —— 它是 git 内置能力，产出的文件可以直接当 remote 用，能 fetch、能校验、能快进、带完整提交历史。**不需要在两端装任何东西。**

## 设计：整仓镜像，两端完全对等

**没有 A 端 B 端，没有主从，没有提案分支和 cherry-pick。** 两端跑同一份脚本、同一套命令，谁都能改代码，谁都能打包。

一次搬运就是一次完整镜像：

```
一端                                             另一端
sync.sh pack                                     sync.sh load
  ├─ 先把自己的分支和 Gitea 对齐                    ├─ 校验 sha256 + bundle verify
  ├─ git bundle create <远端存在的分支> --tags       ├─ fetch 到 refs/remotes/peer/*
  │    （本地独有、没 push 的分支不进包）             ├─ 逐分支比较：能快进就快进
  └─ 生成 xxx.bundle + .sha256  ────U 盘───▶        └─ 分叉就停下，交给人处理
```

**包里有什么，只看远端。** 远端有的分支全进包（本地没有的会先拉下来），远端没有的分支一律不进包。
这样两台机器、两个 Gitea 的内容永远收敛到同一份，不会有人把本机私货悄悄搬过去。

**为什么不用「A 端合并、B 端开提案分支」那套？** 试过，问题是 `uat` 这类发布分支本来就落后 `dev`，B 在上面改的东西挑回 `dev` 时几乎必然冲突（同一个文件同一处两边都动过）；而两端角色只能靠配置约定，配错了不报错、静默走错路。整仓镜像把这些都省掉了：谁改都在自己的分支上改，包一搬，两边一模一样。

## 每次运行都先和本机 Gitea 对齐

空气隔离说的是 A 和 B 之间，不是每台机器和它自己的 Gitea。所以脚本在每个命令开头都会做一次对齐：

| 本地 vs `origin` | 脚本动作 |
|---|---|
| 落后 | **自动快进**（等价于 `git pull --ff-only`），工作区跟着更新 |
| 一致 | 什么都不做 |
| **领先**（有没推送的提交） | **停下**，列出来，给出两条出路（推送 / 显式放行） |
| **分叉**（两边都有对方没有的提交） | **停下**，给出 rebase / merge 的命令 |
| 远端连不上 | 提示一句后继续（离线也能用） |

这样"本地"永远等于"本机 Gitea"，包搬来搬去才不会把远端状态搞乱。

停下时**一个字节都不改**，提交都还在，不会丢东西。

## 哪些分支会进包

**远端是唯一标准。** 打包范围严格等于「本机 Gitea 上存在的分支」：

| 情况 | 脚本动作 |
|---|---|
| 远端有、本地有，一致 | 进包 |
| 远端有、本地落后 | 先快进，再进包 |
| **远端有、本地没有** | **先拉下来（建同名本地分支、跟远端一样新），再进包** |
| **本地有、远端没有** | **不进包**，只提示；要带走就 `git push origin <分支>` |

所以自己开的工作分支 `b/1103-fix` 要传给对面，必须先推到自己 Gitea：

```bash
git add -A && git commit -m "修了 xxx"
git push origin b/1103-fix      # ← 少了这步，这个分支不会进包
sync.sh pack /media/usb/toB
```

如果你正好停在一个远端没有的分支上打包，脚本会用 `[!]` 明确警告"这个分支上的提交这次不会被打包"，
不会让你以为搬过去了。

> 没有 `origin`（或设了 `SYNC_SKIP_REMOTE=1`）时无法判断"远端有哪些"，这时退化成打包本地全部分支，并提示一句。

## 跑完回到原来的分支

```bash
# 脚本在哪都行，仓库自动找：-r 参数 → SYNC_REPO → 从当前目录往上找 .git
cd /srv/project/models          # 甚至可以在子目录里跑
/opt/sync/sync.sh load /media/usb/toB
```

跑完停在哪个分支：

- **默认**：停回你运行前所在的分支（在 `b/1103-fix` 上跑，跑完还在 `b/1103-fix`，工作区不动）
- **`SYNC_BRANCH=dev`**：无论从哪跑，跑完都停到 `dev`

被更新的其他分支只挪指针（`git update-ref`），不碰工作区 —— 不会出现"我的改动看起来没了"。

## 命令

| 命令 | 作用 |
|---|---|
| `sync.sh pack [目录]` | 打包**远端存在的**分支和标签（默认 U 盘 `SYNC_MEDIA`） |
| `sync.sh load [包或目录]` | 收下包，逐分支快进（默认从 `SYNC_MEDIA` 找最新包） |
| `sync.sh status` | 看状态（只读，不改任何东西） |
| `sync.sh branch <名字>` | 开工作分支 `b/<名字>` 并切过去 |
| `sync.sh fixperm` | 单独把仓库权限刷成 `SYNC_PERM` |
| `sync.sh -r <仓库> <命令>` | 临时指定仓库目录 |

每个命令都自带对齐：`pack` 前先确认本地没落后/领先，`load` 前同理。搬运时**sha256 校验 → 逐分支对齐 → 刷权限**。

## 配置（`<脚本所在目录>/.sync.env`）

配置文件**跟着脚本走**，脚本放哪配置就在哪，不用 `cd` 到仓库：

```bash
SYNC_BRANCH=dev            # 同步完停在这个分支；不写就停回原分支
SYNC_MEDIA=/media/usb      # U 盘挂载点默认值
SYNC_PERM=777              # 每次操作后刷成的权限；写成空串则跳过
SYNC_REPO=/srv/project     # 仓库路径（脚本不在仓库里、又不想 cd 时用）
SYNC_REMOTE=origin         # 远端名
SYNC_ALLOW_LOCAL_AHEAD=1   # 本地领先也照常继续（默认停下）
SYNC_SKIP_REMOTE=1         # 完全不碰远端（纯离线）
```

变量名必须带 `SYNC_` 前缀。漏了（写成 `BRANCH=dev`）脚本读不到、又不会报错 —— 这是最难查的一类配置问题，
所以脚本启动时会扫一遍并直接点出来。旧版留下的 `SYNC_ROLE` / `SYNC_MERGE_INTO` 也会提示可以删掉。

改动细节见 [docs/02-two-way-sync.md](docs/02-two-way-sync.md)。

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
| 两端各自 `merge` 同一个文件 | 两边都生成合并提交，sha 不同，历史永久分叉 |
| 手动 diff + 复制文件 | 分支、提交信息、作者、时间全丢 |

---

## 其它设计决策

**两端都在同一个文件上改，怎么办？** `load` 会先比较每个分支：一方是另一方的祖先就快进，互不相容就**停下并列出双方各多几个提交**，给出 `git rebase peer/<分支>` 的命令。脚本不替你选边，也不会悄悄丢掉任何一边。

**未跟踪文件冲突自动让路。** 对方提交了新文件，本地恰好有同名但未跟踪的文件（配置、数据），快进会被 git 拒绝。`load` 会先把本地文件改名成 `xxx.preload-<时间戳>` 再放行，不删任何东西。

**rebase / merge 做到一半会被拦。** 仓库里有没做完的操作时（`.git/rebase-merge` 等），任何同步命令都会先停下，避免踩翻现场。

**777 权限与 `core.filemode`。** 容器固定 uid、SMB 共享时常常只能全刷 777，这会让 git 把每个文件标成 `mode change 100644 => 100755`。脚本每次执行都设 `core.filemode false`，权限位彻底退出 diff，`git status` 保持干净。

**`.git` 应该放在哪一层。** 容器挂载、SMB、Windows 客户端混用时，`.git` 放错位置会导致 refs 被写成全零（极难定位）。结论和取舍见 [docs/01-architecture.md](docs/01-architecture.md)。

---

## 实测范围

不是设计文档，是跑通过的东西：

- **整仓首次导入**：一端 4 条分支 + 标签 → 另一端全部建出来，并推回本机 Gitea，两端 sha 完全一致
- **双向闭环**：一端改 → 打包 → 另一端快进 → 另一端开 `b/xxx` 改 → 打包回来 → 先到的一端拿到分支和提交，两个 Gitea 最终同一 sha
- **分支停留**：在 `b/1103-fix` 上收包，工作区一个文件都没动，只更新 `dev` 指针；`SYNC_BRANCH=dev` 时正确落到 `dev`
- **护栏**：本地领先时 `pack` 停下并给出两条出路；两边都改过同一分支时报告分叉；工作区脏时拒绝快进；rebase 未完成时拒绝一切同步；包路径不存在时给明确错误
- **环境自适应**：从仓库子目录执行、`-r` 指定仓库、`SYNC_REPO`、无远端仓库、旧变量残留 —— 全部验证
- **C 端更新**：用真实 `git archive` 产物测试，覆盖深层目录、150+ 字节长路径、中文文件名、可执行脚本；12 项验收全通过
- **边界**：sha256 不符、非 gzip 文件、`../` 路径穿越、目标目录不存在、包内有符号链接 —— 全部正确拦截或跳过

可重跑的测试：

```bash
python tools/build_notebook.py      # 从源码重新生成 ipynb
python tools/test_notebook.py       # 模拟 C 端环境实测
```

---

## 三条铁律

1. **同一时刻只允许一个写入者。** 不要一边用 Windows 图形客户端、一边在服务器上操作同一个仓库。SMB 上的并发写入能把 refs 写成全零，事后极难定位。
2. **本地要和本机 Gitea 一致。** 有没推送的提交时脚本会停下来 —— 先推上去，或者确认"就是要带着这些提交走"再显式放行。
3. **每次搬运都带 sha256 校验。** 别直接拷文件夹，别信"应该没坏"。

---

## 目录

| 路径 | 说明 |
|---|---|
| `scripts/sync.sh` | 功能一：两台机器之间整仓镜像同步 |
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

- **不搬 `refs/remotes/*` 和 stash**。包里只有「远端存在的」本地分支、标签和提交历史；远端跟踪分支会在对面重新生成
- **远端没有的分支不会自动过去**。这是设计如此（防止私货外流），要传就先 `git push`
- **不搬数据文件**。更新包只含 git 提交过的代码，几 GB 数据集请单独用移动硬盘拷
- **真冲突需要人工解决**。两边改了同一处时脚本只负责停下和指路，不做自动合并
- **C 端的改动回不来**。没有 git 就没有回流路径，别让 C 端当开发环境

## License

MIT。
