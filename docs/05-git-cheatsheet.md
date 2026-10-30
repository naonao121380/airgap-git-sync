# 05 · Git 命令速查

> 给"知道要干什么、但记不住命令"的人。按场景组织，不按 git 的子系统组织。
>
> 本文假设：远端叫 `origin`，主线叫 `dev`，个人开发分支叫 `feature/xxx`。
> 全部替换成你自己的名字即可。

---

## 0. 三条铁律

1. **永远不要跑 `git clean -fdx`** —— 它连"被忽略的文件"一起删。数据文件（`*.xlsx`、模型产物、缓存）通常就在忽略列表里，删掉无法恢复。
2. **永远不要 `git push --force` 到共享分支** —— 会改掉别人的历史。真要强推，用 `--force-with-lease`，且只推自己的分支。
3. **同一时刻只允许一个写入者** —— 不要一边用 Windows 上的图形客户端、一边在服务器上操作同一个仓库。理由见 [01 · 架构决策](01-architecture.md) 第二节。

---

## 1. 看状态

| 命令 | 作用 |
|---|---|
| `git status` | 最常用。看改了哪些文件、在哪个分支、离远端多远 |
| `git status -sb` | 精简版，一行分支 + 一行一个文件 |
| `git status -uno` | 忽略未跟踪文件，**仓库大时快很多** |
| `git log --oneline --graph --decorate --all -20` | 提交图，看分支怎么分叉合并的 |
| `git log --oneline -5` | 当前分支最近 5 条提交 |
| `git diff` | 工作区 vs 暂存区（还没 `add` 的改动） |
| `git diff --cached` | 暂存区 vs 上次提交（已 `add` 待提交的） |
| `git diff HEAD` | 工作区 vs 上次提交（全部改动） |
| `git diff dev origin/dev` | 本地 dev 与远端 dev 的差异 |
| `git show <sha>` | 看某次提交具体改了什么 |
| `git branch -vv` | 所有本地分支 + 各自跟踪的远端 + 领先/落后几个 |

---

## 2. 从云端下载（拉取）

| 命令 | 作用 | 什么时候用 |
|---|---|---|
| `git fetch origin --prune` | **只更新远端的“账本”，不动你的文件** | 每次开工第一件事 |
| `git pull --ff-only` | 拉取并快进，**本地有分叉就报错停下** | 最安全，日常首选 |
| `git pull --rebase` | 先把你本地未推的提交挪到远端最新之上 | 本地有提交又要拉时 |
| `git reset --hard origin/dev` | **彻底对齐远端**，丢掉本地所有改动 | 只想“要远端那份”时 |

> `git status` 里的 ahead/behind 是拿本地缓存比的，**必须先 `fetch` 才准**。
> 想直接问服务器真实值：`git ls-remote origin dev`

---

## 3. 上传到云端（推送）

| 命令 | 作用 |
|---|---|
| `git push origin feature/xxx` | 推当前工作分支 |
| `git push -u origin feature/xxx` | 首次推，同时建立跟踪关系（之后直接 `git push` 就行） |
| `git push --force-with-lease origin feature/xxx` | ⚠️ 改写远端历史，但会先检查远端有没有别人的新提交。**只用于自己的分支** |

> 推完自己的分支后到网页端提 PR（`feature/xxx` → `dev`），不要直接推 `dev`。

---

## 4. 提交

| 命令 | 作用 |
|---|---|
| `git add <文件路径>` | 暂存指定文件 |
| `git add -u` | 暂存所有**已跟踪**文件的改动（不含新增） |
| `git add -A` | 暂存所有改动（含新增，不含被忽略/未跟踪） |
| `git commit -m "说明"` | 提交暂存的改动 |
| `git commit -am "说明"` | 跳过 `add`，提交所有已跟踪文件的改动（新增文件仍需 `add`） |
| `git commit --amend` | 修改上一条提交（补文件或改说明）。**只在没推送前用** |
| `git restore --staged <文件>` | 把文件从暂存区拿出来（改动还在） |

---

## 5. 分支

| 命令 | 作用 |
|---|---|
| `git branch` | 本地分支列表 |
| `git branch -a` | 含远端分支 |
| `git switch dev` | 切到 dev |
| `git switch -c feature/xxx` | 新建并切过去 |
| `git switch -C dev origin/dev` | 本地 dev 强制重置成远端 dev 并切过去 |
| `git merge dev` | 把 dev 合进当前分支 |
| `git branch -d xxx` | 删除已合并的分支 |
| `git branch -D xxx` | ⚠️ 强制删除（未合并也删） |

---

## 6. 对比 / 查历史

| 命令 | 作用 |
|---|---|
| `git log --oneline dev..origin/dev` | 远端比你多的提交 |
| `git log --oneline origin/dev..dev` | 你比远端多的提交（未推的） |
| `git log -p --follow <文件>` | 某文件的完整修改历史 + 每次内容 diff |
| `git log --author="gituser" --oneline -10` | 按人筛 |
| `git blame <文件>` | 每行是谁、哪次提交改的 |
| `git diff <分支A> <分支B> --stat` | 两分支差异概览 |
| `git diff <分支A> <分支B> -- <路径>` | 只比某个目录/文件 |

---

## 7. 撤销与后悔（⚠️ 危险区）

| 命令 | 作用 | 危险度 |
|---|---|---|
| `git restore <文件>` | 丢弃某个文件的工作区改动 | ⚠️ 改动立即消失 |
| `git restore .` | 丢弃**全部**工作区改动 | ⚠️⚠️ |
| `git reset` | 只清空暂存区，**文件一个都不动** | 安全 |
| `git reset --hard` | 工作区 + 暂存区全部回到 HEAD | ⚠️⚠️ 未提交改动全丢 |
| `git revert <sha>` | 生成一个“反向提交”来抵消某次提交 | 安全，**已推送的用它** |
| `git reflog` | 所有 HEAD 移动记录，**误操作后的救命符** | 只读 |
| `git reset --hard <reflog里的sha>` | 回到误操作前的状态 | 配合上面用 |

> 记住：**已经 push 出去的提交，用 `revert` 不要用 `reset`**。`reset` 只适合本地还没推的东西。

---

## 8. 清理

| 命令 | 作用 |
|---|---|
| `git clean -n` | **干跑**，只列出会被删的未跟踪文件 |
| `git clean -fd` | 删未跟踪文件（**不影响被忽略的文件**） |
| `git clean -fdx` | ⚠️⚠️ **连被忽略的也删** —— 数据文件、缓存全没 |
| `git gc --prune=now` | 压缩仓库、清理悬空对象 |

---

## 9. 固定工作流

### 日常：在自己的分支上开发

```bash
git switch feature/xxx
git fetch origin --prune
git merge origin/dev          # 先把 dev 的最新合进来，减少后面对不上
# ---- 改代码 ----
git status -sb
git add -A
git commit -m "说明"
git push origin feature/xxx
# ---- 到网页端提 PR：feature/xxx → dev ----
```

### 只想“要远端那份，本地全不要”

```bash
git fetch origin --prune
git reset --hard origin/dev
git switch -C dev origin/dev
git status -sb
```

### 临时切到别的分支看代码（不动任何东西）

```bash
git switch dev
git log --oneline -5
git switch feature/xxx        # 看完切回来
```

---

## 10. 卡住了怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `fatal: detected dubious ownership` | 仓库属主 ≠ 当前用户 | `git config --global --add safe.directory <仓库路径>` |
| `fatal: Unable to create '.git/index.lock'` | 上次 git 异常退出留下锁 | `ls -l .git/index.lock` 确认没有 git 在跑，再 `rm .git/index.lock` |
| `error: Your local changes would be overwritten` | 切分支/拉取会覆盖未提交改动 | 先 `git stash` 或 `git commit`，再操作 |
| `You have unmerged paths` / `UU` | 合并或 stash pop 有冲突 | `git status` 看冲突文件；不想要这些合并就 `git merge --abort` |
| `## dev...origin/dev [ahead 3, behind 5]` | 本地和远端各有新提交 | 要么 `git pull --rebase`，要么 `git reset --hard origin/dev` 全丢本地 |
| `HEAD detached at xxx` | 处在一个游离的提交上 | `git switch dev` 回到分支 |
| `fatal: bad object xxx` / `无效的 sha1 指针` | refs 坏了 | `git fetch --force --prune origin`，仍不行见下一行 |
| 仓库彻底混乱，只想重来 | —— | 隔壁目录 `git clone` 一份干净的做参照，**不要 `clean -fdx`** |

---

## 11. 提速（SMB / 大目录下必做）

```bash
# 本地忽略清单：不进版本库、不影响任何人
cat >> .git/info/exclude <<'EOF'
*.zip
*.tar.gz
*.whl
.ipynb_checkpoints/
__pycache__/
output/
data/
EOF

# 日常用这个代替 git status
git status -uno
```

仓库目录里堆着 GB 级备份 zip 时，`git status` 会遍历整个工作树，慢是必然的。上面的排除项能让它少扫一大半。
