# 04 · 从零上线清单

> 适用于：B 端有一台 Linux 机器（本文以 RedHat 系为例）和一个 Docker 部署的 Gitea，
> 但这台机器**连不上 A 端的代码托管**，需要用 U 盘把代码搬过来。
>
> 按阶段做，每个阶段都有明确的"验证通过标准"。**没通过就别进下一阶段**，返工成本远高于多花五分钟。

---

## 环境假设

下面的命令都基于这套设定，替换成你的值即可：

| 项 | 值 |
|---|---|
| Gitea 地址 | `http://192.168.1.50:3000` |
| Gitea 账号 | `gituser` |
| 仓库名 | `myproject`（私有、**空仓库**） |
| 克隆地址 | `http://192.168.1.50:3000/gituser/myproject.git` |
| Gitea 数据目录 | 已挂载到宿主机（容器重建不丢库） |

### 同步范围

| 分支 | 在 A 侧 | 在 B 侧 | 说明 |
|---|:--:|:--:|---|
| `dev` | 主线开发 | ✅ 跟 A 走 | **唯一要同步的分支** |
| `uat` / `main` | 备份 | ❌ 不进 B | 只在 A 侧保留，B 不碰 |

只同步一条分支的好处：B 端永远不会因为分支跑偏而出错，包也更小。

---

## 阶段 0 · 确认 Gitea 跑起来了

先分清它是怎么部署的：

```bash
sudo systemctl status gitea --no-pager | head -15     # systemd
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}' # docker
```

本机自测：

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:3000/
```

放行端口（如果开了防火墙）：

```bash
sudo firewall-cmd --permanent --add-port=3000/tcp && sudo firewall-cmd --reload
```

**✅ 通过标准**：另一台机器（比如你的 Windows 桌面）浏览器打开 `http://<这台机器的IP>:3000`，能看到 Gitea 登录页。

> 打不开时按顺序排查：`ss -lntp | grep 3000`（有没有在听）→ `curl 127.0.0.1:3000`（本机通不通）→ 防火墙 → 机器之间能否 ping。SELinux 拦截非标准端口的话，`sudo semanage port -a -t http_port_t -p tcp 3000`。

---

## 阶段 1 · 建空仓库 + 打通 git 认证

### 1.1 网页建空仓库

右上角 `+` → 新建仓库 → 名称 `myproject` → 可见性**私有** → **「初始化仓库」那几个勾全部不勾**（README、`.gitignore`、许可证、模板）→ 创建。

这一步是唯一容易返工的地方：只要勾了任意一个，等 A 的代码推上来必然冲突，只能删库重建。

### 1.2 设 git 身份 + 保存凭据

```bash
git config --global user.name  "b-tester"
git config --global user.email "b-tester@local"
git config --global credential.helper store
git config --global core.autocrlf input
git config --global core.filemode false
```

`credential.helper store` 效果是：输一次账号密码，之后全自动。密码明文存在 `~/.git-credentials`，所以记得 `chmod 600`。

### 1.3 验证认证能通

```bash
git ls-remote http://192.168.1.50:3000/gituser/myproject.git
echo "退出码 $?"
```

**✅ 通过标准**：命令问一次 Username / Password（密码不回显，正常），然后**直接结束，没有任何输出**，退出码 `0`。

空仓库没有分支，**没输出才是对的**。看到 `Authentication failed` 说明用户名写错了（要用账号名，不是邮箱）；`repository not found` 说明地址抄错了。

### 1.4 确认 Gitea 的数据是持久化的

Docker 部署最容易踩的坑：`/data` 没挂到宿主机，容器一重建仓库全没。

```bash
G=$(sudo docker ps --format '{{.Names}}' | grep -i gitea | head -1)
sudo docker inspect "$G" --format '{{range .Mounts}}{{.Type}}  {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

**✅ 通过标准**：输出里有一行目的地是 `/data`。

没有的话，先停下来补挂载，不要继续往里面推东西。

---

## 阶段 2 · 把 A 的 `dev` 搬进 B（U 盘摆渡）

全程靠 U 盘搬两个文件。**顺序不能反**：先 A 打包，再 B 导入。

### 2.1 A 端打一个 `dev` 包裹

在 A 端宿主机：

```bash
cd /srv/project
git rev-parse --show-toplevel        # 输出应该就是这个路径
git switch dev
git branch --show-current            # 必须输出 dev
```

先确认没有"改了但没提交"的内容（**未跟踪文件不影响，不用管**）：

```bash
git status --porcelain | grep -v '^??' || echo "干净"
```

有输出（形如 ` M models/xxx.py`）就先提交或 stash，否则 B 端拿到的是不含这些改动的版本。

打包：

```bash
B=$(date +%Y%m%d)
git bundle create /tmp/fromA-$B.bundle dev
git bundle list-heads /tmp/fromA-$B.bundle
ls -lh /tmp/fromA-$B.bundle
cd /tmp && sha256sum fromA-$B.bundle > fromA-$B.bundle.sha256 && cat fromA-$B.bundle.sha256
```

**✅ 通过标准**：

1. `list-heads` **只输出一行** `refs/heads/dev`
2. `ls -lh` 有文件大小
3. `cat` 打出一串 64 位十六进制

> `git bundle create` 不会因为工作区有未跟踪文件报错，那些文件本来也不进包。

### 2.2 拷到 U 盘

同一目录，**不要改名、不要解压**：

- `fromA-20261030.bundle`
- `fromA-20261030.bundle.sha256`

### 2.3 B 端导入

U 盘插到 B 端，`cd` 到这两个文件所在目录：

```bash
sha256sum -c fromA-20261030.bundle.sha256
```

`OK` 才继续。`FAILED` 说明拷贝损坏，**重拷，别硬上** —— 坏包导入会得到一个残缺仓库。

```bash
# 1) 从包裹建临时裸库
git clone --bare fromA-20261030.bundle /tmp/relay.git

# 2) 只推 dev 进 B 的 Gitea
git --git-dir=/tmp/relay.git push \
  http://192.168.1.50:3000/gituser/myproject.git \
  refs/heads/dev:refs/heads/dev

# 3) 清临时库
rm -rf /tmp/relay.git

# 4) 克隆成工作副本
cd ~ && git clone http://192.168.1.50:3000/gituser/myproject.git myproject

# 5) 确认
cd ~/myproject && git log --oneline -3 && git branch -vv
```

**✅ 通过标准**：第 5 步打印出提交记录，且 `git branch -vv` 显示 `* dev`。

### 2.4 把默认分支改成 dev

Gitea 新建空库时默认分支名常是 `main`，而我们只推了 `dev`，于是网页首页可能显示"仓库为空"。

修法：仓库页 → **设置** → 左侧 **分支** → 默认分支改成 `dev` → 保存 → 回首页刷新。

**✅ 通过标准**：网页能看到提交历史，分支框显示 `dev`。

### 2.5 知道这一步搬了什么、没搬什么

**搬了**：所有提交过的代码。

**没搬**：

- 未跟踪的文件（数据文件、本地配置、产物目录）
- `.git` 里的 stash、reflog
- 其他分支

代码落地后，如果 B 端要真正跑起来还缺数据文件，得单独处理（通常几百 MB 到几 GB，U 盘或移动硬盘直接拷比任何传输方式都快）。

---

## 阶段 3 · 装同步脚本

```bash
cp sync.sh ~/sync.sh
chmod +x ~/sync.sh
cd ~/myproject && ~/sync.sh status
```

**✅ 通过标准**：输出里能看到

```
权限 : 777  filemode=false
```

之后日常操作见 [02 · 双端同步](02-two-way-sync.md)。

---

## 三条铁律

1. **B 端永远不在 `dev` 上直接改代码。** 要改就开 `b/1030-修个bug` 这种分支，由 A 端合并。
2. **合并只在 A 端做。** 两边都 merge 会生成两个不同 sha 的合并提交，历史永久分叉，再也对不上。
3. **每次搬代码都带 sha256 校验。** 别直接拷文件夹，别信"应该没坏"。

---

## 常见卡点

| 现象 | 原因 | 处理 |
|---|---|---|
| 网页打不开 | 端口没放行 / 只听 127.0.0.1 | `ss -lntp \| grep 3000`，改 `BIND_IP` 或防火墙 |
| `ls-remote` 输出一堆分支名 | 仓库不是空的（建库时勾了初始化） | 删库重建，或先清空 |
| `sha256sum -c` 报 `FAILED` | 拷贝损坏 | 重拷；别忽略 |
| 推完网页显示空仓库 | 默认分支是 `main` | 设置里改成 `dev` |
| `could not read Username` | 凭据没保存 | 重跑一次 `ls-remote` 输密码，或检查 `~/.git-credentials` 权限 |
| 容器重建后仓库消失 | `/data` 没挂载 | 见 1.4，补挂载 |

---

下一步：[02 · 双端同步](02-two-way-sync.md) ／ [03 · 单向更新到受限环境](03-air-gapped-update.md)
