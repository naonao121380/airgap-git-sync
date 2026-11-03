# 02 · 双端同步手册（A ↔ B）

> 场景：两台机器网络不通，靠 **U 盘**搬东西，只同步一条分支（默认 `dev`，可切成 `uat` 等发布分支）。
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

### 0.1 谁是 A、谁是 B

两端跑的是**同一份文件、同样的代码**，脚本本身不天生知道自己在哪台机器。所以每台机器的
`.sync.env` 里用一行把它写清楚：

```bash
SYNC_ROLE=A     # A 端：有 dev/uat 全部分支，负责合并
SYNC_ROLE=B     # B 端：只有同步分支，跟着跑、偶尔改代码
```

写了以后脚本会校验：

| 情况 | 结果 |
|---|---|
| B 端敲 `merge` | 直接拒绝，并告诉你 B 端该敲什么 |
| B 端在同步分支上攒了提交，`pack` | 直接拒绝（否则等于绕过 dev 直接改发布版） |
| 落点等于发布分支本身，`merge` | 直接拒绝，提示补 `SYNC_MERGE_INTO=dev` |

不写 `SYNC_ROLE` 也能跑，但三道校验都不会生效，全靠人工记住。

**但 env 是本机的**：B 写了什么不会传到 A。要让 A 把 B 的改动合到 `dev`，**A 自己的 env 里也得有 `SYNC_MERGE_INTO=dev`**，两端都要写。

变量名还必须带 `SYNC_` 前缀：

| 你写的 | 脚本读到的 | 结果 |
|---|---|---|
| `SYNC_MERGE_INTO=dev` | `dev` | ✅ 挑取到 dev |
| `MERGE_INTO=dev`（漏前缀） | 空 | ❌ 悄悄回落成同步分支 `uat` |
| 什么都不写 | 空 | ❌ 同上 |

`.sync.env` 是直接 `source` 的，**名字写错不会报错**，只会静默按默认值跑——这是最难查的一类问题。新版脚本启动时先扫一遍，发现漏前缀的变量会直接点出来，并且把实际落点也打出来：

```
[!] /devsdb/git-sync/.sync.env 里有变量名漏了 SYNC_ 前缀，脚本读不到：
        MERGE_INTO=dev
      要写成 SYNC_xxx=... 才生效，本次按默认值跑
```

想随时确认落点，跑 `sync.sh status` 看这两行：

```
      角色 : B
      同步 : 分支 uat，B 的提案落到 dev
```

`角色` 空着说明没写 `SYNC_ROLE`；落点写成 `uat` 说明 `SYNC_MERGE_INTO` 没生效。

落点可疑时 `status` 会额外提醒，`merge` 会**直接停下不动手**：

```
[!] 这次会把 b/1103-修bug 直接合进 uat —— uat 就是 B 端在跟的发布分支
      B 的改动会停在发布版上，dev 永远拿不到，下次发版就被覆盖
      本意是「B 跟发布版跑、改动回 dev」的话，在 /devsdb/git-sync/.sync.env 写一行：
        SYNC_MERGE_INTO=dev
[停] 合并落点可疑，已停下（没有改动任何东西）
```

确实要把改动留在发布分支上（少见），显式放行：`SYNC_ALLOW_MERGE_TO_RELEASE=1`。

> **如果是旧脚本，写什么都没用。** `SYNC_MERGE_INTO` / `SYNC_ROLE` 都是 2026-11-02 之后才有的变量，在那之前 `merge` 一律合进当前同步分支。两端都换成新版再试。

---

## 1. 安装（两端各做一次，约 5 分钟）

### 1.1 把脚本放到一个固定目录

放**仓库外面**、任何固定位置都行，例如 `/devsdb/git-sync/`：

```bash
mkdir -p /devsdb/git-sync
cp /path/to/sync.sh /devsdb/git-sync/sync.sh
chmod +x /devsdb/git-sync/sync.sh
```

顺手做个短命令，后面所有命令都写成 `sync xxx`，一行敲完：

```bash
echo "alias sync='/devsdb/git-sync/sync.sh'" >> ~/.bashrc && source ~/.bashrc
```

> **千万不要把 `sync.sh` 放进仓库目录。** 放进去它会变成仓库里的文件，下次同步时对面那版要覆盖你的副本，git 会拒绝快进，整条链路卡死。

### 1.2 在脚本旁边写 `.sync.env`

配置文件和脚本**放同一个目录**，脚本搬到哪配置就跟到哪：

```bash
vi /devsdb/git-sync/.sync.env
```

**A 端**（有 `dev`、`uat` 全部分支，负责合并）：

```bash
SYNC_ROLE=A
SYNC_BRANCH=uat
SYNC_MERGE_INTO=dev
SYNC_REPO=/srv/project
SYNC_MEDIA=/media/usb
```

**B 端**（只有同步分支，负责跟着跑、改代码）：

```bash
SYNC_ROLE=B
SYNC_BRANCH=uat
SYNC_MERGE_INTO=dev
SYNC_REPO=/data/project
SYNC_MEDIA=/media/usb
```

两个文件**内容几乎一样**，只有 `SYNC_ROLE` 和 `SYNC_REPO` 不同。逐项说明：

| 变量 | 写什么 | 说明 |
|---|---|---|
| `SYNC_ROLE` | `A` 或 `B` | 这台机器是谁。写了才有校验：B 端跑 `merge` 会被直接拒绝 |
| `SYNC_BRANCH` | `uat` | 同步哪条分支。两端必须一致 |
| `SYNC_MERGE_INTO` | `dev` | B 的提案合到哪。**两端都要写**，漏了就合进 uat |
| `SYNC_REPO` | 仓库绝对路径 | 写了就能在任意目录执行脚本，不用先 `cd` |
| `SYNC_MEDIA` | U 盘挂载点 | 只是默认值，命令里也可以直接传 |
| `SYNC_PERM` | 不用写 | 不写＝刷 777；写成 `SYNC_PERM=`（空）＝不处理权限 |
| `SYNC_ALLOW_MERGE_TO_RELEASE` | 不用写 | 确实要把改动合进发布分支本身时才设成 1 |

> 变量名必须带 `SYNC_` 前缀。写成 `MERGE_INTO=dev` 脚本读不到，会静默按默认值跑（合进 uat）。
> 新版启动时会把这个点出来。

### 1.3 自检

```bash
/devsdb/git-sync/sync.sh status
```

A 端应该是这样：

```
  仓库
      路径 : /srv/project
      分支 : dev
      提交 : a9e3860 ...
      配置 : /devsdb/git-sync/.sync.env
      角色 : A
      同步 : 分支 uat，B 的提案落到 dev
      权限 : 777    filemode=false
```

**三行都要对**：`角色` 是本机的，`同步` 那行落点必须是 `dev`。落点写成 `uat` 说明 `SYNC_MERGE_INTO` 没生效，回去看 1.2。

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

### 1.5 换同步分支：从 dev 改成 uat

默认同步 `dev`。如果 B 端跑的是**发布版**、不希望跟着开发分支往前跑，把同步分支改成 `uat` 之类的发布分支。**两端都要改**。

先确认 A 端本地有这条分支：

```bash
git branch uat origin/uat 2>/dev/null || git switch -c uat origin/uat
```

然后两端各写一行（A 和 B 都一样）：

```bash
cat >> /devsdb/git-sync/.sync.env <<'EOF'
SYNC_BRANCH=uat
SYNC_MERGE_INTO=dev
EOF
```

`SYNC_MERGE_INTO` 决定 B 的修改落到哪个分支。**不要省这一行**，原因见下。

#### 为什么不能只改 SYNC_BRANCH

B 的提交是在 `uat` 基础上做的。如果直接合回 `uat`，`uat` 就会比 `dev` 多出只在测试环境里存在过的代码，而 `dev` 永远拿不到——下次从 `dev` 发布时这个修复就丢了。

设了 `SYNC_MERGE_INTO=dev` 之后，A 端 `merge` 做的是**挑取**（cherry-pick）：只把 B 那几条提交搬到 `dev`，不把 `uat` 上一长串 `merge pull request` 记录拖进来。搬运完成后：

```
A: dev  ← B 的修复（cherry-pick）
A: uat    还是发布版的样子
```

要让 B 真正用上这个修复，还要在 A 端走一次你平时的发布流程（`dev` → `uat` 的 PR），然后再 `pack`。B 端在等待期间继续待在 `b/xxx` 分支上，代码是新的，不影响测试。

#### B 端换分支时要注意

B 的 `uat` 一般比 `dev` 旧。切过去以后**工作区里的代码会退回发布版**，未跟踪的数据文件不受影响。

B 上通常还没有 `uat` 这条分支，**不用手工建**——把 A 新打的包 `load` 一次，脚本会自动从包里建出来并切过去：

```bash
sync load /media/usb/toB      # 看到「已新建本地分支 uat」就对了
sync status                   # 确认 "同步 : 分支 uat，B 的提案落到 dev"
```

屏幕上会先提示一句 `本地还没有 uat，下面会从包里建`，然后：

```
[OK] 已新建本地分支 uat = 36e91e3 Merge pull request 'Dev' into uat
[OK] 已推送 origin/uat
```

B 上如果还留着早先同步过去的 `dev` 分支，建议删掉，免得有人在那儿改：

```bash
git branch -D dev
```

#### pack 不再要求先切分支

A 平时在 `dev` 上干活，打包时**不用先切到 `uat`**——包是按分支引用取的，和当前所在分支无关。屏幕上会提示一句：

```
[!] 当前在 dev，本次打包的是 uat（dev 不受影响）
```

---

### 1.6 B 端要改代码怎么办

#### 先看该用哪种模式

| B 端主要干什么 | `SYNC_BRANCH` 用 | 理由 |
|---|---|---|
| 只跑测试、看结果，不改代码 | `uat` | 跟发布版，不会被开发中的代码带偏 |
| 要改代码，哪怕只改一两个文件 | **`dev`** | `uat` 落后 `dev`，改动回 `dev` 时几乎必然冲突 |

**这不是偏好问题。** `uat` 是 `dev` 后面的某个快照，B 在 `uat` 上改的文件，A 那边 `dev` 里往往已经变过了；
两边从同一个文件的同一位置往下改，`git` 就会要求手工解冲突（实测：在 `models/core.py` 末尾追加一行都能冲突）。
所以**只要 B 要改代码，就把两端都切到 `dev`**，让 B 一直在最新代码上改。

```bash
sed -i 's/^SYNC_BRANCH=uat/SYNC_BRANCH=dev/' /devsdb/git-sync/.sync.env    # 两端各跑一次
```

`SYNC_MERGE_INTO=dev` 不用动——`dev` 模式下落点也是 `dev`，正好一致。

改完 `sync status` 应该看到 `同步 : 分支 dev，B 的提案落到 dev`，然后 A `pack`、B `load`（B 上会自动建出 `dev` 并切过去）。

#### 如果只能跟 uat：也能改，但要知道代价

B 端停在 `uat`。**不要在 `uat` 上直接改**——`uat` 是发布版本，改动会留在发布版上，`dev` 永远拿不到。
规矩和 `dev` 模式一样，只有一处不同：**你的改动会落到 `dev`，而不是 `uat`。**

#### 完整一圈

**B 端（改代码）**

```bash
sync branch 1103-修bug            # ① 从 uat 开提案分支 b/1103-修bug
# ... 改代码 ...
git add -A && git commit -m "修了 xxx"   # ② 提交
sync pack /media/usb/toA          # ③ 打包给 A
```

**A 端（收下并落地）**

```bash
sync load  /media/usb/toA         # ④ 收包（B 的分支进 refs/remotes/peer/）
sync merge b/1103-修bug           # ⑤ 挑取到 dev（注意：不是 uat）
# ⑥ 照你平时的发布流程，把 dev 合进 uat（PR）
sync pack  /media/usb/toB         # ⑦ 打包回 B
```

**B 端（收结果）**

```bash
sync load /media/usb/toB          # ⑧ uat 更新，工作区变
git branch -D b/1103-修bug        # ⑨ 已进 uat，可以删
```

`merge` 那一步屏幕上会明说落点：

```
  挑取 b/1103-修bug 的 1 个提交 → dev
        41d485c B 修了 bug
[OK] 已挑入：cb5fef5 B 修了 bug

      B 的改动现在在 dev，还没进 uat
      要让 B 用上，先在 A 上把 dev 合并进 uat（走你平时的 PR 流程）
```

#### 三个必须知道的点

**① 改动先进 `dev`，再靠发版回到 `uat`。**
第 ⑤ 步之后，`dev` 上有你的提交，`uat` 上没有。中间这段时间，B 的 `b/xxx` 分支就是"最新代码"，测试照跑，不受影响。等第 ⑥ 步发版完成，`uat` 才会带上这个修复。

**② 在 `b/xxx` 上收到新包，不会被踢回 `uat`。**
`load` 检测到你在提案分支上，只更新 `uat` 这条分支指针，**工作区一个字节都不动**：

```
      当前在提案分支 b/1103-修bug，下面只更新 uat，工作区保持原样
[OK] 已更新 uat = 19f544a A 又更新 uat
      你在 b/1103-修bug 上，工作区没动
      要把新代码合进当前分支：git rebase uat
```

想让 A 的新代码也进到你手上，就照提示跑一次 `git rebase uat`。有冲突的话 git 会停下让你改，改完 `git add -A && git rebase --continue`；想放弃就 `git rebase --abort`。

**③ `uat` 比 `dev` 旧，冲突只能 A 端解。**
B 是在发布版基础上改的，只要 `dev` 上动过同一个文件，第 ⑤ 步挑取就会冲突：

```
[!] 有冲突，需要手工解决：
        models/xxx.py
      改完这些文件，然后：
        git add -A
        git cherry-pick --continue
      不想继续就回滚： git cherry-pick --abort
```

改完继续即可。**不在 A 端解，B 端没法解**——`b/xxx` 上的代码是对的，只是和 `dev` 的最新版要碰一下。

冲突多了就说明模式选错了，回到本节开头切成 `dev`。

#### 为什么删分支要用 `-D` 而不是 `-d`

`merge` 走的是**挑取**（cherry-pick），同一个改动在 A 端会生成一个**新的提交号**。B 本地那条
`b/1103-修bug` 的原始提交（例如 `b26fded`）在 `uat` 里根本不存在，git 就认为"没合并"，
`git branch -d` 会拒绝删除：

```
error: the branch 'b/1103-修bug' is not fully merged
```

内容其实已经在里面了（`uat` 里是 `6974c69`，同一个修改、不同提交号）。确认代码已经在 `uat` 上之后，
直接用 `git branch -D` 删掉即可。不放心就先对一下文件内容：`git diff uat b/1103-修bug` 应该是空的。

---

## 2. 日常用法

### 场景一：A 改了代码，同步给 B（最常用）

**A 端**：

```bash
sync pack /media/usb/toB      # 配了 SYNC_REPO 就能在任意目录跑
```

看到 `[OK] 已生成 sync-A端主机名-时间.bundle` 就成了。**整个 toB 目录一起拷走**（`.bundle` 和 `.bundle.sha256` 两个文件必须在一起）。

**B 端**：

```bash
sync load /media/usb/toB
```

关键几行：

```
[OK] sha256 校验通过
[OK] 已快进到 e1fbd8d A v2
[OK] 权限已刷成 777
```

---

### 场景二：B 改了代码，回传给 A

**B 端**（先开分支，别在同步分支上改）：

```bash
sync branch 1030-修bug            # 建并切到 b/1030-修bug
# ... 改代码 ...
git add -A && git commit -m "修了 xxx"  # 提交
sync pack /media/usb/toA
```

> 如果同步的是 `uat`（`SYNC_BRANCH=uat`），这几步完全一样，只是 `merge` 会把你的提交挑到 `dev` 而不是 `uat`。详见 [1.6 节](#16-b-端要改代码怎么办)。

**A 端**：

```bash
sync load  /media/usb/toA          # 先把 B 的分支收进来
sync merge b/1030-修bug            # 合进 dev（或 SYNC_MERGE_INTO 指定的分支），并推回 Gitea
sync pack  /media/usb/toB          # 打个新包带回 B
```

**B 端**（把合并结果收回来）：

```bash
sync load /media/usb/toB
git branch -D b/1030-修bug              # 这个分支已经合过了，可以删
```

---

### 场景三：只想看看现在什么状态

```bash
sync status
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
- **只想单独刷权限** → `sync fixperm`

---

## 4. 出错对照表

| 屏幕上出现 | 意思 | 怎么办 |
|---|---|---|
| `sha256 不匹配` | U 盘拷贝中文件坏了 | 重拷一遍，不要硬来 |
| `有 N 个文件改了但没提交` | 忘了 commit | `git add -A && git commit -m "说明"`，或 `git checkout -- .` 丢弃 |
| `变量名漏了 SYNC_ 前缀` | env 里写成 `MERGE_INTO=dev`，脚本读不到 | 改回 `SYNC_MERGE_INTO=dev`，重跑 `status` 确认 |
| `[停] 合并落点可疑` | 同步的是发布分支，但落点还是它本身 | env 里写 `SYNC_MERGE_INTO=dev`；真要合进发布分支才加 `SYNC_ALLOW_MERGE_TO_RELEASE=1` |
| `[停] 这台机器是 B 端` | 在 B 上跑了 `merge` | `merge` 只能在 A 跑；B 要做的是 `branch` → 改 → `commit` → `pack` |
| `[停] 同步分支被直接改过` | 在 `uat` 上直接提交了 | 按屏幕给的三行命令挪到 `b/xxx`，再把同步分支退回去 |
| `error: ... is not fully merged` | 挑取后提交号变了，git 认不出"已合并" | 确认内容已在 `uat` 上，改用 `git branch -D` |
| `未跟踪文件将被覆盖，已改名备份` | 本地同名文件要被打包里的版本顶替 | **正常现象**，旧文件还在，名字后面加了 `.preload-时间` |
| `两边都改过 XXX，历史分叉了` | A、B 同时动了同步分支 | 按屏幕提示操作，或把输出发我 |
| `快进失败，上面是 git 的原话` | 少见，通常是文件锁 | 关掉 Jupyter 里正在跑的任务再试 |
| `推送超时或失败` | 本机 Gitea 没起来 / 网络断 | **可以忽略**，不影响两端同步 |
| `当前目录不在 git 仓库里` | 没 cd 到仓库 | 先 `cd` 到仓库目录 |
| `目录里没有 sync-*.bundle` | U 盘没挂上或拿错目录 | 用 `ls /media/usb` 确认 |

---

## 5. 四条规矩（记不住别的，记这四条）

1. **B 端改代码，先 `sync branch <名字>`。** 直接在同步分支上改，改动会绕过 `dev` 进 `uat`。
2. **`merge` 只在 A 端做。** 别在 B 上敲（写了 `SYNC_ROLE=B` 会被直接拒绝）。
3. **`SYNC_MERGE_INTO=dev` 两端都要写。** env 是本机的，写一边不生效。
4. **U 盘分 `toA` / `toB` 两个目录**，别混。

---

## 6. 一页速查

| 我想 | 在哪台 | 敲什么 |
|---|---|---|
| 打包给对面 | A | `sync pack /media/usb/toB` |
| 打包给对面 | B | `sync pack /media/usb/toA` |
| 收对面包 | B | `sync load /media/usb/toB` |
| 收对面包 | A | `sync load /media/usb/toA` |
| 开分支改代码 | B | `sync branch 1103-xxx` |
| 合并 B 的改动 | A | `sync merge b/1103-xxx` |
| 让 A 的新代码进当前分支 | B | `git rebase uat`（或 `dev`） |
| 从 uat 模式切到 dev 模式 | 两台都行 | `sed -i 's/^SYNC_BRANCH=uat/SYNC_BRANCH=dev/' /devsdb/git-sync/.sync.env` |
| 看状态 / 看落点对不对 | 两台都行 | `sync status` |
| 只刷权限 | 两台都行 | `sync fixperm` |
| 忘命令了 | 两台都行 | `sync` |

---

## 7. 技术备忘（出问题时给维护的人看）

- 配置文件固定读**脚本所在目录**的 `.sync.env`（`BASH_SOURCE` 解析，符号链接以真实位置为准）
- 脚本用 `git bundle` 传输，只打包同步分支和 `b/*` 分支，不含 `refs/remotes/*`（Gitea 会拒）
- 导包时 fetch 到 `refs/remotes/peer/*`，不污染本地分支
- 快进前会扫描"将被覆盖但本地未纳管"的文件，改名成 `.preload-<时间戳>` 保留
- `pack` 按分支引用打包，与当前所在分支无关；当前若不在同步分支上会提示一句，并跳过工作区干净检查
- 删分支用 `-D`：`merge` 走 cherry-pick，A 端的提交号与 B 的原始提交不同，`-d` 的祖先判断必然失败
- 全程不 `push --force`，不改写历史
