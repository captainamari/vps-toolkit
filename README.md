# Ubuntu 24.04 Docker VPS Toolkit

Target use case: a small personal production VPS running multiple Docker services.

**Account convention**: all scripts must be run as **root**. This toolkit does not create or rely on a separate sudo/admin user.

## Recommended network pattern

Expose only:

- SSH (`22/tcp` by default, or your chosen SSH port)
- HTTP (`80/tcp`)
- HTTPS (`443/tcp`)

Bind application containers to loopback and reverse proxy them with Nginx:

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

Do **not** assume UFW blocks a Docker-published port when you use
`3000:8080`; Docker manages its own packet-filtering rules.

## Files

- `01-bootstrap.sh` — first-login checks and baseline configuration
- `daily-health-check.sh` — read-mostly host/container health report
- `weekly-maintenance.sh` — conservative weekly cleanup/update workflow
- `backup-docker-volumes.sh` — generic file-level Docker volume/config backup

## First run

Logged in as root:

```bash
chmod +x *.sh
bash ./01-bootstrap.sh
```

By default the script does **not** disable password login for root. Open a
**second terminal** and verify that root SSH key login works before tightening
anything further.

After confirming key login works, optionally enable key-only SSH hardening
(disables password login, keeps root key login):

```bash
ENABLE_SSH_HARDENING=1 bash ./01-bootstrap.sh
```

If you use a non-default SSH port, supply the actual port consistently:

```bash
SSH_PORT=2222 ENABLE_SSH_HARDENING=1 bash ./01-bootstrap.sh
```

Common environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `TIMEZONE` | `UTC` | System timezone |
| `SSH_PORT` | `22` | SSH port, synced into UFW and Fail2ban rules |
| `SWAP_GB` | `4` | Swapfile size (GiB) to create; set `0` to skip |
| `INSTALL_NGINX` | `1` | Whether to install Nginx and Certbot |
| `APPLY_OS_UPDATES` | `1` | Whether to apply currently available OS security updates |
| `ENABLE_SSH_HARDENING` | `0` | Whether to enable SSH key-only hardening |

## Daily check

```bash
bash ./daily-health-check.sh
```

Suggested cron entry (root's crontab) after you have reviewed the output:

```cron
15 6 * * * /usr/local/sbin/daily-health-check.sh >/dev/null 2>&1
```

If you want alerts, do not discard the output; send it to your own monitoring or
notification system instead.

## Weekly maintenance

Report/cleanup only:

```bash
bash ./weekly-maintenance.sh
```

Install normal Ubuntu package upgrades as well:

```bash
APPLY_UPDATES=1 bash ./weekly-maintenance.sh
```

Application container updates are intentionally excluded. Update Open WebUI,
your trading system and your website separately after taking backups and checking
their release notes.

## Backup

```bash
bash ./backup-docker-volumes.sh
```

This is a generic file-level backup. Databases need native dumps for reliable
application-consistent recovery; volume-file backups alone are not sufficient.

At least one copy of critical strategy configuration, databases and source
artifacts should live **outside the VPS/provider**.

Common environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_ROOT` | `/srv/backups/docker-volumes` | Backup output directory |
| `RETENTION_DAYS` | `14` | Days to retain backup sets before deletion |
| `BACKUP_IMAGE` | `alpine:3.22` | Temporary container image used to mount volumes and archive them |

## Suggested directory convention

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

Prefer one Compose project per application. Keep secrets in `.env` files with
restrictive permissions (`chmod 600`) and never commit them to Git.

## Security notes

- All scripts assume a unified root login; no separate sudo user is created or relied upon.
- `ENABLE_SSH_HARDENING=1` only disables password login (`PasswordAuthentication no`) and sets
  `PermitRootLogin` to `prohibit-password` (root key login is still allowed, password login is
  rejected). Make sure your public key is already in `/root/.ssh/authorized_keys` before running it.
- Fail2ban is configured for the SSH port by default; UFW only allows SSH/80/443 by default.
- Run `daily-health-check.sh` and complete a verified backup/restore drill before production use.

## 中文文档

See [README_CN.md](./README_CN.md) for the Chinese version.
