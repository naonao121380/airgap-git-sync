# 功能一 · 两台断网机器之间同步（完整手册）

> 一句话：**两端跑同一份脚本，`pack` 把远端存在的所有分支打成一个文件，`load` 把里面的分支和标签都对到本地。**

---

## 0. 先理解模型（三分钟，省掉后面所有困惑）

### 0.1 没有 A 端 B 端

旧版本分"A 端合并 / B 端只能开提案分支"，需要写 `SYNC_ROLE`、`SYNC_MERGE_INTO`，还要 cherry-pick。
**那套东西已经删掉了。** 现在是：

- 两端**完全对等**，同一份脚本、同一套命令
- 谁都可以改代码，谁都可以打包
- 包里装的是**本机 Gitea 上存在的所有分支 + 标签**，对面照单全收
- 不需要选"同步分支"，不存在"只同步 dev"这回事

### 0.2 哪些分支会进包：只看远端

**远端（本机 Gitea）是唯一标准。** 打包范围严格等于"远端有哪些分支"：

| 情况 | 脚本动作 |
|---|---|
| 远端有、本地有，一致 | 进包 |
| 远端有、本地落后 | 先快进，再进包 |
| **远端有、本地没有** | **先拉下来**（建同名本地分支，与远端一样新），再进包 |
| **本地有、远端没有** | **不进包**，只提示 |

原因是这套东西要保证"两端的 Gitea 内容最终一致"。本地随手开的分支如果也能打包，就会在对面凭空多出一条谁都没推过的分支；
反过来，只要推到自己 Gitea，它就自动成为"远端存在的分支"，跟着包走。

要传一条工作分支过去，**先 push**：

```bash
git add -A && git commit -m "修了 xxx"
git push origin b/1103-fix        # ← 少了这步，这个分支不会进包
sync.sh pack /media/usb/toB
```

停在一个"远端没有"的分支上打包时，脚本会明确警告，不会让你以为搬过去了：

```
[!] 这些分支远端没有，本次不打包：b/1103-fix
[!] 你现在就在 b/1103-fix 上，它远端没有 → 这个分支上的提交这次不会被打包
      先推：git push origin b/1103-fix    （推完重跑，它就会进包）
```

> 没有 `origin`（或设了 `SYNC_SKIP_REMOTE=1`）时无法判断"远端有哪些"，会退化成打包本地全部分支，并提示一句。

### 0.3 每次运行都先和本机 Gitea 对齐

"断网"指的是 A 和 B 之间，不是每台机器和它自己的 Gitea。所以每个命令开头都有这一步：

| 本地 vs `origin` | 脚本动作 |
|---|---|
| 落后 N 个提交 | **自动快进**（等价 `git pull --ff-only`），工作区跟着更新 |
| 完全一致 | 什么也不做 |
| **领先**（有没推送的提交） | **停下**，列出来，给两条出路 |
| **分叉** | **停下**，给出 rebase / merge 命令 |
| 远端连不上 | 提示后继续（离线也能用） |

停下时**一个字节都不改**，提交不会丢。

### 0.4 跑完回到你原来的分支

- 默认：停回**运行前所在的分支**。在 `b/1103-fix` 上跑，跑完还在那儿，工作区不动
- `SYNC_BRANCH=dev`：无论从哪跑，跑完都停到 `dev`

其他被更新的分支只挪指针，不碰工作区。

---

## 1. 安装（每台机器各做一次，约 5 分钟）

### 1.1 把脚本放到任意目录

```bash
mkdir -p ~/git-sync
cp /path/to/sync.sh ~/git-sync/sync.sh
chmod +x ~/git-sync/sync.sh
```

**脚本放哪都行**，不需要在仓库里，也不需要 `cd`：仓库按 `-r 参数 → SYNC_REPO → 从当前目录往上找 .git` 的顺序自动定位。

> 别把 `sync.sh` / `.sync.env` 放进仓库工作区。它们会随包同步、覆盖对面那份，还会让打包内容无谓地变来变去。放仓库外面最省事。

### 1.2 写配置（跟脚本同一个目录）

```bash
cat > ~/git-sync/.sync.env <<'EOF'
SYNC_BRANCH=dev
SYNC_REPO=/data/project
SYNC_MEDIA=/media/usb
SYNC_PERM=777
EOF
```

| 变量 | 默认 | 作用 |
|---|---|---|
| `SYNC_BRANCH` | 空 | 同步完停在这个分支；空 = 停回运行前的分支 |
| `SYNC_REPO` | 空 | 仓库路径。设了就能在任意目录执行 |
| `SYNC_MEDIA` | `/media/usb` | U 盘挂载点，`pack`/`load` 不给参数时用它 |
| `SYNC_PERM` | `777` | 每次操作后刷成的权限；写成 `SYNC_PERM=` 空串则跳过 |
| `SYNC_REMOTE` | `origin` | 远端名 |
| `SYNC_ALLOW_LOCAL_AHEAD` | `0` | 设 `1` 时本地领先也照常继续 |
| `SYNC_SKIP_REMOTE` | `0` | 设 `1` 时完全不碰远端（纯离线） |

变量名**必须带 `SYNC_` 前缀**。写成 `BRANCH=dev` 不会报错，只会静默按默认值跑；脚本启动时会扫出来点给你看。

### 1.3 自检

```bash
~/git-sync/sync.sh status
```

正常输出：

```
  仓库
      路径 : /data/project
      分支 : dev
      提交 : a9e3860 初始版本
      远端 : http://192.168.1.50:3000/gituser/myproject.git
      配置 : ~/git-sync/.sync.env
      停留 : dev  ← SYNC_BRANCH 指定
      权限 : 777    filemode=false

  分支与远端
  dev                          a9e3860  与远端一致
  uat                          8b2c1f0  落后 3 个提交（运行任一命令会自动快进）
```

看到 `filemode=false` 说明权限适配生效。没配提交身份的补一次：

```bash
git config --global user.name  "tester"
git config --global user.email "tester@local"
```

### 1.4 U 盘建两个目录（别混用）

```
/media/usb/toB/     ← 这一端打包放这里，给对面用
/media/usb/toA/     ← 对面打包放这里，给这一端用
```

不分开的话，U 盘里会同时躺着两个方向的包，`load` 自动挑"最新的那个"，很容易拿错方向。

---

## 2. 日常用法

### 2.1 首次：把一端的仓库复制到另一端

**有仓库的那端**（假设叫甲）：

```bash
~/git-sync/sync.sh pack /media/usb/toB
```

看到 `[OK] 已生成 sync-主机名-时间.bundle`，**整个目录一起拷走**（`.bundle` 和 `.bundle.sha256` 必须在一起）。

**对面**（假设叫乙，目录里可能已经有一份老代码）：

```bash
~/git-sync/sync.sh load /media/usb/toB
```

会发生什么：

```
      自动选中最新包：sync-jia-20261103-161357.bundle
[OK] sha256 校验通过
      本地没有，将新建：dev uat main
[OK] 已新建 dev（并切过去）= 5062e8a 初始版本
[OK] 已新建 uat = 5062e8a
[OK] 已新建 main = 5062e8a
[OK] 已推送 3 个分支到 origin
```

- 乙原来那些**没被 git 跟踪**的文件（老代码副本），同名的会改名成 `xxx.preload-时间戳` 留着，不删
- 乙本机 Gitea 也会被推成一样的内容
- 完成后再跑一次 `sync.sh pack` 回传，两端就完全同源了

### 2.2 之后：改 → 打包 → 收包

**改代码的一端**：

```bash
# 想要一条自己的工作分支就开一条（可选）
~/git-sync/sync.sh branch 1103-修bug

# 改完提交（脚本不会替你提交）
git add -A && git commit -m "修了 xxx"

# 推到自己 Gitea —— 不推的话这条分支不进包
git push origin b/1103-修bug

# 打包
~/git-sync/sync.sh pack /media/usb/toB
```

**收包的一端**：

```bash
~/git-sync/sync.sh load /media/usb/toB
```

就这样，两步。谁先谁后都行，谁改都一样。

### 2.3 一条命令速查

| 我想 | 敲什么 |
|---|---|
| 打包给对面 | `sync.sh pack /media/usb/toB` |
| 收对面包 | `sync.sh load /media/usb/toB` |
| 开工作分支 | `sync.sh branch 1103-xxx` |
| 让工作分支能被打包 | `git push origin b/1103-xxx` |
| 看状态 | `sync.sh status` |
| 只刷权限 | `sync.sh fixperm` |
| 换台机器没 cd 过来 | `sync.sh -r /data/project pack /media/usb/toB` |
| 忘命令了 | `sync.sh` |

---

## 3. 分支：现在怎么管

### 3.1 进包的是「远端存在的分支」

打包范围 = 本机 Gitea 的分支清单（`git for-each-ref refs/remotes/origin`）：

- **远端有、本地没有** → 脚本先把它们建成同名本地分支（跟远端一样新），然后一起进包
- **本地有、远端没有** → **不进包**。这类分支在 `status` 里显示 `远端没有（不会进包，先 git push）`
- 标签照旧全部带走

对面 `load` 之后：

- 对面没有的分支 → **新建**（工作区不动，除非是首次导入）
- 对面有但落后 → **快进**
- 对面已经包含 → **跳过**
- 两边都改过 → **停下报告分叉**（见第 4 节）

所以 `main`、`uat`、`feature/x`、`b/1103-fix` 都会跟过去——前提是它们已经推到了某一端的 Gitea 上。

### 3.2 在分支上改，别在主干上直接攒

建议习惯：**改代码先 `sync.sh branch <名字>`**，得到 `b/名字` 分支，提交后 `git push origin b/名字` 再打包。

原因不是脚本限制，而是协作：两边都在 `dev` 上直接提交，两边一搬就分叉，得手工 rebase。
各在各的分支上改，合的时候在 GitHub/Gitea 上走 PR，冲突面小得多。

（`b/名字` 这种本地分支只要没推，就不会进包 —— 见 0.2。这是有意为之：想让对面看到，就必须先在 Gitea 上留下记录。）

### 3.3 停在哪个分支

```bash
# 默认：停回运行前的分支。在 b/1103-fix 上跑 load，跑完还在 b/1103-fix
~/git-sync/sync.sh load /media/usb/toB

# 想每次跑完都停在 dev（适合测试机固定跑一套脚本）
echo 'SYNC_BRANCH=dev' >> ~/git-sync/.sync.env
```

人在 `b/1103-fix` 上收包时，`dev` 被更新了但工作区没动，脚本会提示：

```
[OK] dev 已快进 → 88e64c8
      dev 有新代码，要合进当前分支：git rebase dev
```

跟着敲就行。

---

## 4. 出问题时怎么办

### 4.1 `本地领先远端`（`pack` / `load` 停下）

```
[!] 这些分支比 origin 多出本地提交（还没推送）：
      dev  +1 个提交
        0bb42c9 B 修了个 bug

      两条路：
        ① 推到本机 Gitea，让两边一致（推荐）
           git push origin <分支>
        ② 就是要带着这些提交去对面
           SYNC_ALLOW_LOCAL_AHEAD=1 sync.sh pack ...
```

选 ①（正规）还是 ②（临时放行）都行。② 打包会把这些提交带走，对面收到后也会一起推回它自己的 Gitea。

### 4.2 `有分支已分叉`

两边都改过同一个分支，谁也不是谁的祖先。

```bash
# 看差在哪
git log --oneline origin/dev..dev     # 我多的
git log --oneline dev..origin/dev     # 远端多的

# 把本地提交接到远端后面（推荐）
git checkout dev
git rebase origin/dev
git push --force-with-lease origin dev      # rebase 改写过历史，要 force

# 或者保留合并记录
git checkout dev && git merge origin/dev && git push origin dev
```

处理完再跑一次原来的命令。

### 4.3 `收包时报分叉`（`peer/dev` 和本地都改过）

同样的逻辑，只是对方是"包里的引用"：

```bash
git checkout dev
git rebase peer/dev        # 把本地提交接到包里那版后面
# 有冲突就改文件 → git add -A → git rebase --continue
```

然后重跑 `sync.sh load`。

### 4.4 `有 N 个已跟踪文件改了但没提交`

要更新工作区时才会拦。先提交或丢弃：

```bash
git add -A && git commit -m "说明"     # 或者
git checkout -- .                      # 丢弃（不可恢复）
```

### 4.5 `仓库里有个没做完的操作`

`.git/rebase-merge`、`MERGE_HEAD` 这类残留会拦住所有同步命令。收尾或撤掉：

```bash
git status
git rebase --continue    # 或 --abort
git merge  --continue    # 或 --abort
```

### 4.6 出错对照表

| 屏幕上的话 | 意思 / 怎么办 |
|---|---|
| `本地与 origin 一致，无需更新` | 正常，不需要你做什么 |
| `已快进 → abc1234` | 正常，自动 pull 了 |
| `本地有、远端没有的分支（不会进包）` | 正常（比如刚开的 `b/xxx`）。要传过去先 `git push origin <分支>` |
| `远端有、本地没有的分支，已拉下来` | 正常，对面新增的分支被拉成同名本地分支，会一起进包 |
| `这些分支远端没有，本次不打包` | 打包范围的提醒，确认是不是漏推了 |
| `未跟踪文件将被覆盖，已改名备份` | 正常，旧文件还在，后缀 `.preload-时间` |
| `拉取远端失败，这次跳过对齐` | Gitea 没起来 / 网络不通。能连就重跑，连不上就写 `SYNC_SKIP_REMOTE=1` |
| `没有名为 origin 的远端` | 这个仓库没配远端，只靠 U 盘同步也能用 |
| `已跳过权限修正（SYNC_PERM 为空）` | 配置里写了 `SYNC_PERM=`，就是不处理权限 |

---

## 5. 从旧版本迁移

旧版 `.sync.env` 里的 `SYNC_ROLE`、`SYNC_MERGE_INTO`、`SYNC_ALLOW_MERGE_TO_RELEASE` 新版**不再读取**，启动时会提示：

```
[!] .sync.env 里还有旧模型的变量，新版不读了，可以删掉：
       SYNC_ROLE SYNC_MERGE_INTO
      新模式不分 A/B，只同步远端存在的分支，不需要角色和合并落点
```

删掉它们，只留 `SYNC_BRANCH` / `SYNC_REPO` / `SYNC_MEDIA` / `SYNC_PERM`。

旧版的 `merge` 子命令也删了，敲它会告诉你直接 `git merge` + `git push` 然后打包。

**两端的仓库要不要重建？** 不需要。旧版同步的分支（`dev` 或 `uat`）和新版对得上，
第一次 `pack` / `load` 时其他分支会被补齐（新建），不会重写已有的提交。

---

## 6. 三条规矩

1. **改代码先 `sync.sh branch <名字>`，提交后 `git push` 一下**，否则这条分支不进包。
2. **本地要和本机 Gitea 一致** —— 脚本发现领先会停下来，先推或显式放行。
3. **U 盘分 `toA` / `toB` 两个目录**，别混。

---

## 7. 技术备忘（出问题时给维护的人看）

- 对齐时会把"远端有、本地没有"的分支用 `git branch --track` 建成同名本地分支，保证打包范围 ⊇ 远端分支
- `pack` = `git bundle create <file> <远端存在的 refs/heads/* 逐个列出> --tags`；不含 `refs/remotes/*`（Gitea 会拒收），也不含本地独有分支
- 没有远端可用时退化为 `git bundle create --all`，并打印提示
- `load` = `git fetch --prune <bundle> "+refs/heads/*:refs/remotes/peer/*"`，先取到 `peer/*` 再逐分支判断，不直接覆盖。
  `peer` 只是引用命名空间，**不是 git remote**，`git remote -v` 看不到它，`git branch -a` 里会显示成 `remotes/peer/dev`
- 非当前分支用 `git update-ref` 挪指针，工作区零改动；当前分支用 `git merge --ff-only`，工作区跟着更新
- 快进前扫描"会被覆盖但本地未纳管"的文件，改名成 `.preload-<时间戳>` 保留，不删除
- 全程不 `push --force`；`load` 结束时只对**更新过/新建过**的分支做普通 push（都是快进）
- 包名带 `YYYYMMDD-HHMMSS`，`load` 按名字里的时间戳选最新，不用 mtime（同秒会打平）
