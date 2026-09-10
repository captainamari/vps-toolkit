# Ubuntu 24.04 Docker VPS 工具箱

> English version: [README.md](./README.md)

适用场景：运行多个 Docker 服务的小型个人生产环境 VPS。

**账号约定**：所有脚本均需以 root 身份运行。

## 推荐的网络方案

只对公网开放：

- SSH（默认 `22/tcp`，或你自定义的端口）
- HTTP（`80/tcp`）
- HTTPS（`443/tcp`）

应用容器只绑定到回环地址，通过 Nginx 反向代理对外暴露：

```yaml
services:
  open-webui:
    ports:
      - "127.0.0.1:3000:8080"

  strategy-web:
    ports:
      - "127.0.0.1:3100:8000"

  personal-site:
    ports:
      - "127.0.0.1:3200:3000"
```

注意：当容器使用 `3000:8080` 这种方式发布端口时，**不要**想当然地认为 UFW 会阻止该端口对外访问；Docker 会自行管理其数据包过滤规则，可能绕过 UFW 的默认策略。

## 文件说明

- `01-bootstrap.sh` — 首次登录后的基础检查与初始化配置
- `daily-health-check.sh` — 只读为主的主机/容器健康检查报告
- `weekly-maintenance.sh` — 保守的每周清理/更新流程
- `backup-docker-volumes.sh` — 通用的 Docker 数据卷/配置文件级备份

## 首次运行

以 root 身份登录服务器后：

```bash
chmod +x *.sh
bash ./01-bootstrap.sh
```

默认情况下脚本**不会**关闭 root 的密码登录，请务必先在**新开的第二个终端**中验证 root 的 SSH 密钥登录正常，再决定是否收紧安全策略。

确认密钥登录可用后，可选择性地启用「仅密钥登录」加固（禁用密码登录，保留 root 密钥登录）：

```bash
ENABLE_SSH_HARDENING=1 bash ./01-bootstrap.sh
```

如果你使用非默认 SSH 端口，请始终保持端口参数一致：

```bash
SSH_PORT=2222 ENABLE_SSH_HARDENING=1 bash ./01-bootstrap.sh
```

常用环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TIMEZONE` | `UTC` | 系统时区 |
| `SSH_PORT` | `22` | SSH 端口，会同步写入 UFW 与 Fail2ban 规则 |
| `SWAP_GB` | `4` | 创建的 swap 大小（GiB），设为 `0` 跳过 |
| `INSTALL_NGINX` | `1` | 是否安装 Nginx 与 Certbot |
| `APPLY_OS_UPDATES` | `1` | 是否安装当前可用的系统安全更新 |
| `ENABLE_SSH_HARDENING` | `0` | 是否启用 SSH 仅密钥登录加固 |

## 每日健康检查

```bash
bash ./daily-health-check.sh
```

确认输出符合预期后，建议加入 crontab（root 的 crontab）：

```cron
15 6 * * * /usr/local/sbin/daily-health-check.sh >/dev/null 2>&1
```

如果需要告警通知，请不要直接丢弃输出，而是接入你自己的监控或通知系统。

## 每周维护

仅生成报告并做无害清理：

```bash
bash ./weekly-maintenance.sh
```

同时安装常规的 Ubuntu 系统包更新：

```bash
APPLY_UPDATES=1 bash ./weekly-maintenance.sh
```

脚本刻意**不会**自动更新应用容器（如 Open WebUI、交易系统、个人网站等）。请在做好备份、阅读发布说明后单独更新这些应用。

## 备份

```bash
bash ./backup-docker-volumes.sh
```

这是通用的文件级备份。数据库类服务（PostgreSQL/MySQL/SQLite 等）需要使用其原生的 dump 工具做应用一致性备份，仅靠卷文件备份不足以保证可靠恢复。

关键的策略配置、数据库和源码等重要数据，至少应有一份**保存在该 VPS/服务商之外**的副本。

常用环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BACKUP_ROOT` | `/srv/backups/docker-volumes` | 备份输出目录 |
| `RETENTION_DAYS` | `14` | 备份保留天数，超期自动删除 |
| `BACKUP_IMAGE` | `alpine:3.22` | 用于挂载卷并打包的临时容器镜像 |

## 建议的目录规范

```text
/srv/
├── apps/
│   ├── open-webui/
│   ├── strategy/
│   └── personal-site/
├── data/
├── logs/
└── backups/
```

建议每个应用使用独立的 Compose 项目。密钥/口令等敏感信息保存在 `.env` 文件中，并设置严格权限（`chmod 600`），切勿提交到 Git 仓库。

## 安全提示

- 所有脚本均以 root 统一登录为前提，不再创建/依赖额外的 sudo 用户。
- `ENABLE_SSH_HARDENING=1` 只会禁用密码登录（`PasswordAuthentication no`），并将 `PermitRootLogin` 设置为 `prohibit-password`（即仍允许 root 通过密钥登录，但拒绝密码登录），执行前请确保 `/root/.ssh/authorized_keys` 中已经配置好你的公钥。
- Fail2ban 默认针对 SSH 端口生效，UFW 默认只放行 SSH/80/443。
- 建议在生产使用前先运行 `daily-health-check.sh` 并完成一次可验证的备份/恢复演练。
