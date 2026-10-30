# 02 · 双端同步手册（A ↔ B）

> 场景：两台机器网络不通，靠 **U 盘**搬东西，只同步 `dev` 一条分支。
> 示例路径：A 端 `/srv/project`，B 端 `/data/project`，按你的实际路径替换。
>
> 前置：B 端已经有一个能用的 Gitea 和空仓库，见 [04 · 从零上线清单](04-bootstrap-checklist.md)。

---

## 0. 它在干什么

```
   A 端                                          B 端
  ┌──────────────┐      U 盘/toB      ┌──────────────┐
  │  dev 分支     │ ──── pack ────▶   │  dev 分支     │
  │              │                    │              │
  └──────────────┘   ◀── pack ────    └──────────────┘
                       U 盘/toA
```

每条命令都做三件事：**打包/解包 → 校验 sha256 → 把权限刷成 777**。
777 不会造成"满仓文件被改动"的假象，因为脚本同时关掉了 git 对权限位的跟踪。

---

## 1. 安装（两端各做一次，约 5 分钟）

### 1.1 把脚本放到家目录

把 `sync.sh` 拷到两台机器的**家目录**（用 U 盘拷，或 `scp`）：

```bash
cp /path/to/sync.sh ~/sync.sh
chmod +x ~/sync.sh
```

> **千万不要把 `sync.sh` 放进仓库目录。** 放进去它会变成仓库里的文件，下次同步时 A 的新版要覆盖 B 的副本，git 会拒绝快进，整条链路卡死。

### 1.2 写一行配置（可选）

```bash
echo 'SYNC_MEDIA=/media/usb' > ~/.sync.env
```

可用的变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `SYNC_BRANCH` | `dev` | 同步的分支 |
| `SYNC_MEDIA` | `/media/usb` | U 盘挂载点默认值 |
| `SYNC_PERM` | `777` | 每次操作后刷成的权限；留空则跳过 chmod |
| `SYNC_REPO` | — | 仓库路径，设了就能在任意目录执行脚本 |

不写也行，脚本都有默认值。实际用的时候在命令后面直接传目录更保险。

### 1.3 自检

先 `cd` 到仓库目录，再跑：

```bash
cd /data/project    # B 端示例
~/sync.sh status
```

正常输出大致是：

```
  仓库
      路径 : /data/project
      分支 : dev
      提交 : a9e3860 ...
      远端 : http://192.168.1.50:3000/gituser/myproject.git
      权限 : 777    filemode=false
  本地分支
  dev                      a9e3860  2026-10-30
  工作区
[OK] 没有未提交的改动
```

看到 `权限 : 777  filemode=false` 就说明权限适配已经生效。

如果提示没配提交身份（合并时才会报错），补一次：

```bash
git config --global user.name  "B-tester"
git config --global user.email "b-tester@local"
```

### 1.4 建好 U 盘的两个目录（重要）

U 盘上建两个文件夹，**永远不要混用**：

```
/media/usb/toB/     ← A 打包放这里，给 B 用
/media/usb/toA/     ← B 打包放这里，给 A 用
```

不分开的话，U 盘里会同时躺着两边的包，`load` 自动挑"最新的那个"，很容易拿错方向。

---

## 2. 日常用法

### 场景一：A 改了代码，同步给 B（最常用）

**A 端**：

```bash
cd /srv/project
~/sync.sh pack /media/usb/toB
```

看到 `[OK] 已生成 sync-A端主机名-时间.bundle` 就成了。**整个 toB 目录一起拷走**（`.bundle` 和 `.bundle.sha256` 两个文件必须在一起）。

**B 端**：

```bash
cd /data/project
~/sync.sh load /media/usb/toB
```

关键几行：

```
[OK] sha256 校验通过
[OK] 已快进到 e1fbd8d A v2
[OK] 权限已刷成 777
```

---

### 场景二：B 改了代码，回传给 A

**B 端**（先开分支，别在 dev 上改）：

```bash
cd /data/project
~/sync.sh branch 1030-修bug            # 建并切到 b/1030-修bug
# ... 改代码 ...
git add -A && git commit -m "修了 xxx"  # 提交
~/sync.sh pack /media/usb/toA
```

**A 端**：

```bash
cd /srv/project
~/sync.sh load  /media/usb/toA          # 先把 B 的分支收进来
~/sync.sh merge b/1030-修bug            # 合进 dev，并推回 A 的 Gitea
~/sync.sh pack  /media/usb/toB          # 打个新包带回 B
```

**B 端**（把合并结果收回来）：

```bash
~/sync.sh load /media/usb/toB
git branch -d b/1030-修bug              # 这个分支已经合过了，可以删
```

---

### 场景三：只想看看现在什么状态

```bash
~/sync.sh status
```

---

## 3. 权限 777 到底怎么处理的

| 时刻 | 脚本做的事 |
|---|---|
| 每次 `pack` / `load` / `merge` / `branch` 结束 | `chmod -R 777 <仓库>`（含 `.git`） |
| 每次执行 | `git config core.filemode false` |

`core.filemode false` 的作用：git 不再比较文件的权限位。所以哪怕 644 全变成 777，`git status` 也不会冒出一堆"被修改"的文件。

特殊情况：

- **chmod 报权限不足**（仓库属主不是当前用户）→ 手动跑一次 `sudo chmod -R 777 <仓库>`
- **只想单独刷权限** → `~/sync.sh fixperm`

---

## 4. 出错对照表

| 屏幕上出现 | 意思 | 怎么办 |
|---|---|---|
| `sha256 不匹配` | U 盘拷贝中文件坏了 | 重拷一遍，不要硬来 |
| `有 N 个文件改了但没提交` | 忘了 commit | `git add -A && git commit -m "说明"`，或 `git checkout -- .` 丢弃 |
| `未跟踪文件将被覆盖，已改名备份` | 本地同名文件要被打包里的版本顶替 | **正常现象**，旧文件还在，名字后面加了 `.preload-时间` |
| `两边都改过 dev，历史分叉了` | A、B 同时动了 dev | 按屏幕提示操作，或把输出发我 |
| `快进失败，上面是 git 的原话` | 少见，通常是文件锁 | 关掉 Jupyter 里正在跑的任务再试 |
| `推送超时或失败` | 本机 Gitea 没起来 / 网络断 | **可以忽略**，不影响两端同步 |
| `当前目录不在 git 仓库里` | 没 cd 到仓库 | 先 `cd` 到仓库目录 |
| `目录里没有 sync-*.bundle` | U 盘没挂上或拿错目录 | 用 `ls /media/usb` 确认 |

---

## 5. 三条规矩（记不住别的，记这三条）

1. **B 端改代码，先 `~/sync.sh branch <名字>`。** 直接改 dev 会让两边历史打架。
2. **合并（`merge`）只在 A 端做。**
3. **U 盘分 `toA` / `toB` 两个目录**，别混。

---

## 6. 一页速查

| 我想 | 在哪台 | 敲什么 |
|---|---|---|
| 打包给对面 | A | `~/sync.sh pack /media/usb/toB` |
| 打包给对面 | B | `~/sync.sh pack /media/usb/toA` |
| 收对面包 | B | `~/sync.sh load /media/usb/toB` |
| 收对面包 | A | `~/sync.sh load /media/usb/toA` |
| 开分支改代码 | B | `~/sync.sh branch 1030-xxx` |
| 合并 B 的改动 | A | `~/sync.sh merge b/1030-xxx` |
| 看状态 | 两台都行 | `~/sync.sh status` |
| 只刷权限 | 两台都行 | `~/sync.sh fixperm` |
| 忘命令了 | 两台都行 | `~/sync.sh` |

---

## 7. 技术备忘（出问题时给维护的人看）

- 脚本用 `git bundle` 传输，只打包 `dev` 和 `b/*` 分支，不含 `refs/remotes/*`（Gitea 会拒）
- 导包时 fetch 到 `refs/remotes/peer/*`，不污染本地分支
- 快进前会扫描"将被覆盖但本地未纳管"的文件，改名成 `.preload-<时间戳>` 保留
- `pack` 只允许在 `dev` 或 `b/*` 分支上执行
- 全程不 `push --force`，不改写历史
