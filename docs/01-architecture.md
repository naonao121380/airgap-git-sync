# 01 · 架构决策：git 工作副本应该落在哪一层

> 这一篇不涉及同步，只解决一个前置问题：**在「Docker 容器 + 宿主机目录挂载 + SMB 给 Windows 访问」这种环境里，`.git` 到底该放在哪。**

放错地方，后面所有同步手段都会失灵。这一篇的结论是踩过坑之后定下来的。

---

## 一、问题的本质

典型环境长这样：

```
Windows 桌面
   │ SMB
   ▼
宿主机 Linux 文件系统  ──bind mount──▶  Docker 容器（JupyterLab / 编辑器）
```

同一份代码，物理上只有一个位置，但可能有三条访问路径（Windows 经 SMB、宿主机 shell、容器内进程）。

**git 不是为"并发多路径写入"设计的**，而 SMB 恰恰不保证原子性。三个写者同时碰同一个 `.git`，最常见的后果是：

```
refs/heads/dev: invalid sha1 pointer 0000000000000000000000000000000000000000
fatal: bad object dev
```

仓库没有真的损坏（对象都还在），但引用被写成了全零，于是 git 认为这个分支指向空。**这种故障极难在事后定位**，因为触发它的动作（在 Windows 上点了一次提交）看起来毫无关联。

---

## 二、三条硬规则

### 规则 1：一个仓库，同一时刻只允许一个写入者

GUI 客户端（GitHub Desktop、VS Code 插件）、容器内进程、宿主机 shell —— 选一个。其余全部改成只读访问，或者干脆不给权限。

如果 Windows 上必须有图形界面，用**浏览器访问容器内的 Web 编辑器**，而不是本地再 clone 一份。本地 clone 一份几乎必然演变成"两个仓库各改各的"，最后手动合并。

### 规则 2：`.git` 放在 Linux 原生文件系统（ext4 / xfs），不要放在 SMB/CIFS 挂载点上

```
✗ /mnt/smb/share/project/.git        ← NAS 的 CIFS 挂载
✓ /srv/project/.git                  ← 本机 ext4
```

SMB 上跑 git 会踩到：`index.lock` 残留、`mmap` 失败、文件时间戳精度丢失、大小写不敏感导致 `README.md` 与 `readme.md` 冲突、权限位不可表达。这些不是配置能解决的，是协议能力缺失。

数据文件（几 GB 的 xlsx、缓存、模型产物）可以继续留在 SMB 上，**代码和 `.git` 必须搬走**。这也是本方案"代码/数据分离"的由来。

### 规则 3：容器只挂载目录，不要在网络文件系统上做 inotify 监听

Docker 的 bind mount 本身没问题。问题出在**容器内的文件监听器**：很多工具（Web Git UI、热重载、文件同步 daemon）用 inotify 监听变化，而在跨挂载点、SMB、overlay 上，inotify 会返回 `EACCES`。

如果容器里跑的东西必须有监听，挂载源必须是本机 ext4 路径，且监听要退化成轮询（polling）。

---

## 三、推荐架构

```
/srv/project/          ← git 工作副本（ext4），容器挂载进来
/srv/data/             ← 数据文件（可以留在 SMB / NAS），容器单独挂载
```

```yaml
# docker-compose.yml
services:
  jupyter:
    volumes:
      - /srv/project:/home/jovyan/work/project    # 代码：本机 ext4
      - /srv/data:/home/jovyan/work/data          # 数据：可以放 NAS
```

好处：

1. **git 操作快且可靠** —— 本地 ext4，无网络往返
2. **权限可表达** —— 644 / 755 有意义，不像 SMB 上全是固定值
3. **SMB 只需暴露数据目录** —— 代码目录不共享，断了 Windows 侧误操作的可能
4. **备份简单** —— `/srv/project` 是自包含的，直接 tar 就有完整仓库

### 数据文件不要入库

数据文件用 `.gitignore` 排除，靠独立通道分发（本方案里 C 端就是这么做的：更新包只含代码，数据保持不动）。理由：

- git 对大二进制文件的压缩和 diff 都很差，仓库会迅速膨胀到几个 G
- 每次更新都会产生完整副本，历史无法清理
- 代码回滚和数据回滚是**两个独立的诉求**，绑在一起会让两者都变难

如果确实需要版本化的数据，用 git-lfs 或 DVC，不要直接塞进普通仓库。

---

## 四、为什么不推荐在容器里跑 Web Git UI

尝试过 ungit（1.5.30，Node 20），结论是**不划算**。记录在这里，省得别人重复踩：

| 现象 | 根因 |
|---|---|
| 打开页面后立刻 disconnected，循环重启 | chokidar 用 inotify 监听 `.git/index`，在挂载点上抛 `EACCES`；`server.js` 的 `uncaughtException` 处理器直接 `process.exit()`，进程自杀 |
| `--unhandled-rejections=warn` 挡不住 | 该参数只拦 Promise rejection，拦不住同步抛出的 `uncaughtException` |
| `Cannot find module '/opt/auth-proxy.js'` | bind mount 的源文件不存在时，Docker 会**静默创建一个同名空目录**；需 `create_host_path: false`（Compose ≥ 2.14） |
| `server certificate verification failed. CAfile: none` | 精简镜像里没有 CA 证书包 |

前两条能靠打补丁绕过（改 `uncaughtException` 只记日志、给 chokidar 加 `error` 监听并切 `usePolling`），但补丁要跟着镜像版本维护，收益很小。

**结论**：容器内的 Web Git UI 只适合"看"，不适合"改"。日常操作直接在宿主机 shell 或 JupyterLab 内置 Terminal 里跑 git 命令，稳定、可脚本化、出问题看得见。

如果只是想要图形化的 diff 和提交历史，`lazygit`、`tig` 这类终端 UI 更轻，也不依赖文件监听。

---

## 五、迁移坑：已有仓库怎么搬到新位置

### 坑一：不能用 `git clone` 搬家

`clone` 只带走提交历史，**不带走**：未提交的改动、stash、未跟踪的数据文件、`.git/config` 里的 remote 与 hooks、`git worktree` 的登记信息。

正确做法是**整体移动目录**（`mv` 或 `rsync -a`），然后修复路径：

```bash
# worktree 里记录的绝对路径会失效
git worktree repair

# 逐个检查是否还有指向旧路径的配置
git config --list --show-origin | grep -i /old/path
```

### 坑二：`.git/config` 会带着旧环境的特征一起走

如果仓库原本在 SMB 上，`.git/config` 里很可能被写进了这些：

```ini
[core]
    filemode = false        # SMB 表达不了可执行位
    ignorecase = true       # SMB 大小写不敏感
```

搬到 ext4 之后它们**不会自动改回来**，结果是新环境里权限变更不被跟踪、大小写不同的文件被当成同一个。

搬完必须复核：

```bash
git config core.filemode      # ext4 上一般是 true；若整个仓库要 777，见第七节
git config core.ignorecase    # ext4 上应该是 false
```

### 坑三：Windows 侧的 CRLF

仓库里存 LF，Windows 检出成 CRLF，如果 `core.autocrlf` 两边不一致，就会产生"全仓文件都被改动"的假象。

统一策略（推荐）：仓库里只存 LF，所有机器上

```bash
git config --global core.autocrlf input     # Linux / macOS；Windows 用 true
```

并在仓库根放一个 `.gitattributes` 兜底，见下一节。

---

## 六、必须加 `.gitattributes`

不要依赖每个人的本地配置，写在仓库里才是强约束：

```gitattributes
# 默认：文本文件一律 LF，二进制不动
* text=auto eol=lf

# 明确声明的二进制类型（避免 git 尝试文本合并）
*.xlsx  binary
*.xls   binary
*.pdf   binary
*.png   binary
*.jpg   binary
*.zip   binary
*.tar.gz binary
*.pkl   binary
*.feather binary
*.parquet binary

# shell 脚本必须是 LF，否则在 Linux 上直接 "bad interpreter"
*.sh    text eol=lf

# Windows 专用脚本保留 CRLF
*.bat   text eol=crlf
*.cmd   text eol=crlf
```

`*.sh` 那条尤其重要：CRLF 的 shell 脚本在 Linux 上会报 `/bin/bash^M: bad interpreter`，而报错信息完全不提行尾问题，新手极难定位。

---

## 七、如果必须让整个仓库 777

有些环境（容器以固定非属主 uid 运行、SMB 共享、组权限不可控）无法避免把所有文件刷成 777。这时：

```bash
git config core.filemode false
```

**为什么必须关掉**：`core.filemode=true` 时 git 会比较文件的"可执行位"。全仓 644 → 777 之后，git 会把每个文件都标成 `mode change 100644 => 100755`，`git status` 里几百个"改动"，实际内容一个字节没变。此时任何 `git add -A` 都会把这份噪音提交进去。

关掉 `filemode` 之后，权限位完全不参与 diff，777 随便刷，`git status` 依然干净。本方案的 `sync.sh` 每次执行都会顺手设这一项，就是这个原因。

---

## 八、小结

| 决策 | 结论 |
|---|---|
| `.git` 放哪 | 宿主机本机文件系统，容器 bind mount 进来 |
| 数据文件 | 独立目录、不入库、单独通道分发 |
| 写入者 | 同一时刻只允许一个 |
| 图形界面 | 浏览器访问容器内的编辑器；不要本地再 clone 一份 |
| Web Git UI | 只看看可以，日常操作走命令行 |
| 行尾 | 仓库存 LF，`.gitattributes` 强约束 |
| 权限 | 需要 777 就关 `core.filemode` |

---

下一步：[02 · 双端同步](02-two-way-sync.md)
