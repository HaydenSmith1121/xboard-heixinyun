# 部署说明

这个仓库是 **Xboard 的二次开发分支**（上游：`cedar2025/Xboard`，MIT 协议）。

当前分支代码与上游 `master` 一致 —— 二开改动（密码兼容、订阅路由等）尚未落地。
所以现在部署它，得到的是一个**干净可用的 Xboard 环境**，用途是先把环境跑通、
把上游行为摸清，之后二开改动会继续提交到这个仓库，重新构建即可生效。

**仓库里为部署准备的东西：**

| 文件 | 作用 |
| --- | --- |
| `compose.yaml` | 部署编排。相比上游官方模板改了三处：端口只绑 `127.0.0.1`、资源档 `minimal`、从本仓库构建镜像 |
| `install.sh` | 一键部署脚本（含前置检查、构建、初始化、启动、自检） |
| `.dockerignore` | 补了 `.git`，避免每次构建白传 70MB+ 历史 |

---

## 1. 前置条件

- Debian / Ubuntu（其他发行版把 `apt` 换成对应包管理器即可）
- 已安装 **Docker** 与 **Docker Compose 插件**（见第 2 节）
- 端口 `7001` 空闲
- 磁盘 ≥ 5 GB，可用内存 ≥ 800 MB

---

## 2. 安装 Docker（已装过可跳过）

> ⚠️ **如果这台机器上还跑着别的服务，先读这一段。**
> 安装 Docker 会修改 iptables/nftables：它会创建自己的链、可能调整 FORWARD 策略、
> 并且**会绕过 ufw**。装之前必须先备份规则，装之后立刻对比。

```bash
# 2.1 备份防火墙规则（必做）
mkdir -p /root/fw-backup
iptables-save > /root/fw-backup/iptables-before-docker.txt
nft list ruleset > /root/fw-backup/nftables-before-docker.txt 2>/dev/null
ls -la /root/fw-backup/
```

```bash
# 2.2 安装 Docker（Debian 用 debian，Ubuntu 用 ubuntu）
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version && docker compose version
```

> 如果 `download.docker.com` 拉不动，改用国内镜像源，或先给系统配好代理再重试。

```bash
# 2.3 装完立刻核对：防火墙差异 + 现有服务是否正常
iptables-save > /tmp/iptables-after-docker.txt
diff /root/fw-backup/iptables-before-docker.txt /tmp/iptables-after-docker.txt | head -60

curl -s -o /dev/null -w "现有站点 -> %{http_code}\n" -H "Host: haoyongjichang.top" http://127.0.0.1/
systemctl is-active xui-manager-panel-backend
```

**只要现有服务异常，先停手回退 Docker，再排查。**

---

## 3. 部署

### 方式一：一键脚本（推荐）

```bash
git clone https://github.com/HaydenSmith1121/xboard-heixinyun.git /opt/xboard-verify
cd /opt/xboard-verify
bash install.sh
```

脚本会依次做：前置检查 → 端口/资源检查 → 准备挂载点 → 构建镜像 → 初始化 →
启动 → 自检，并在最后打印访问方式。

想换端口或管理员邮箱：

```bash
HOST_PORT=17001 ADMIN_ACCOUNT=me@example.com bash install.sh
```

> 换端口时记得同步改 `compose.yaml` 里的 `ports`，否则容器还是绑 7001。

### 方式二：手动逐步（想知道每一步在干什么就用这个）

```bash
# 3.1 拉代码
git clone https://github.com/HaydenSmith1121/xboard-heixinyun.git /opt/xboard-verify
cd /opt/xboard-verify

# 3.2 准备挂载点
#     .env 必须是「文件」：不存在时 Docker 会把它建成目录，安装会直接失败
touch .env
mkdir -p .docker/.data storage/logs storage/theme plugins

# 3.3 构建镜像
#     CACHEBUST 用来让 Docker 重新 clone 仓库代码，而不是复用旧缓存层
export CACHEBUST=$(date +%s)
docker compose build

# 3.4 初始化（建表 + 建管理员）
#     ENABLE_SQLITE / ENABLE_REDIS / ADMIN_ACCOUNT 三个都传，安装过程无交互
docker compose run --rm \
  -e ENABLE_SQLITE=true \
  -e ENABLE_REDIS=true \
  -e ADMIN_ACCOUNT=admin@haoyongjichang.top \
  xboard php artisan xboard:install

# 3.5 启动
docker compose up -d
docker compose ps

# 3.6 自检
ss -lntp | grep 7001                          # 必须是 127.0.0.1:7001
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:7001/
```

> 🔴 **第 3.4 步的输出里有两样东西只打印一次、不存盘，必须立刻记下：**
> - **管理员密码**
> - **后台访问路径**（形如 `/{一串随机字符}`，**不是 `/admin`**）
>
> 漏记就只能推倒重来（清空 `.env` 后重跑，会连数据一起清掉）。

---

## 4. 访问

面板只绑在 `127.0.0.1`，公网访问不到。**推荐用 SSH 隧道**——不碰 Nginx、不碰 DNS、不开公网端口。

```bash
# 在你自己的电脑上执行（不是服务器）
ssh -N -L 7001:127.0.0.1:7001 root@<服务器IP>
```

保持这个窗口开着，然后浏览器打开：

```
http://127.0.0.1:7001/<安装时打印的访问路径>
```

如果确实需要域名访问，再新增一个 Nginx 配置（**别改现有站点的配置文件**）：

```nginx
# /etc/nginx/conf.d/xboard-verify.conf
server {
    listen 80;
    server_name xboard.haoyongjichang.top;

    location / {
        proxy_pass http://127.0.0.1:7001;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
    }
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
# 回退：sudo rm /etc/nginx/conf.d/xboard-verify.conf && sudo nginx -t && sudo systemctl reload nginx
```

---

## 5. 常用操作

```bash
cd /opt/xboard-verify

docker compose ps                          # 状态
docker compose logs -f xboard              # 日志
docker compose restart                     # 重启
docker compose down                        # 停止（保留数据）
docker compose exec xboard bash            # 进容器

# 彻底清空（连数据库一起删）
docker compose down -v && rm -f .docker/.data/database.sqlite
```

---

## 6. 更新代码

仓库有新提交后：

```bash
cd /opt/xboard-verify
git pull
export CACHEBUST=$(date +%s)     # 必须换值，否则会复用旧的代码缓存层
docker compose up -d --build
```

---

## 7. 排错

**构建卡住 / 失败**

构建过程需要：拉 `phpswoole/swoole:php8.2-alpine`（Docker Hub）→ 容器内 `git clone` 本仓库 → `composer install`（packagist.org）。
任一环节网络不通都会失败：

```bash
docker compose build 2>&1 | tail -40          # 看卡在哪一步
curl -sI https://github.com | head -1          # 测 GitHub
curl -sI https://registry-1.docker.io/v2/ | head -1   # 测 Docker Hub
```

不通就给 Docker 配代理（`/etc/systemd/system/docker.service.d/proxy.conf`），或改用第 8 节的备选方案。

**容器起来了但打不开**

```bash
docker compose logs --tail=80 xboard
ss -lntp | grep 7001
```

**忘记管理员密码**

只能重装：`rm -f .env && touch .env`（**会清空数据**），然后重跑 `bash install.sh`。

**担心面板暴露到公网**

```bash
ss -lntp | grep 7001
```

出现 `0.0.0.0:7001` 或 `*:7001` 就是暴露了 —— 检查 `compose.yaml` 的 `ports` 是不是 `127.0.0.1:7001:7001`，改完 `docker compose up -d`。

---

## 8. 备选：用官方预构建镜像（跳过构建）

不想在服务器上构建，可以改用上游镜像。改 `compose.yaml`：删掉整个 `build:` 段，把 `image:` 改成：

```yaml
    image: ghcr.io/cedar2025/xboard:latest
```

然后：

```bash
docker compose up -d
```

代价：
- 拉的是 `ghcr.io`，国内经常拉不动（可能比构建更慢）
- **仓库里的代码改动不会生效** —— 只适合纯验证环境

---

## 9. 与同机其他服务共存的注意事项

这套部署是刻意设计成「不打扰别人」的：

| 隔离项 | 做法 |
| --- | --- |
| 端口 | 只绑 `127.0.0.1:7001`，与现有服务的 80 / 25889 不冲突，公网访问不到 |
| 目录 | 全部在 `/opt/xboard-verify` 内，不碰 `/opt/xui-manager-panel-*`、`/var/www/*` |
| 进程 | Docker 管理，与现有 systemd 服务互不干涉 |
| 数据 | 自己的 SQLite（`.docker/.data/database.sqlite`）与容器内 Redis |
| Nginx | 验证期**完全不改**（用 SSH 隧道） |
| 资源 | `RESOURCE_PROFILE=minimal`，限制占用 |

仍然需要留意的两点：

1. **Docker 会改 iptables/nftables**（第 2 节已覆盖备份与核对）
2. **资源**：Octane + Horizon 常驻内存，如果机器内存紧张，可以关掉队列进程 —— 在 `compose.yaml` 的 `environment` 里把 `ENABLE_HORIZON=true` 改成 `false`，然后 `docker compose up -d`
