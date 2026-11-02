# 部署 Chorus 2（与旧实例并排）

不改旧实例：旧的端口、数据目录、systemd 单元、nginx location 全都不动。新实例 = 端口 **8791**、数据 `/srv/chorus2/data`、单元 `chorus2.service`、路径 `/chorus2/`。

## 1. 用户与目录
```bash
sudo useradd --system --home /srv/chorus2 --shell /usr/sbin/nologin chorus2
sudo mkdir -p /srv/chorus2/data /etc/chorus2
sudo git clone https://github.com/ndx700/chorus-ui-brass /srv/chorus2/app
sudo python3 -m venv /srv/chorus2/venv
sudo /srv/chorus2/venv/bin/pip install -r /srv/chorus2/app/server/requirements.txt
sudo chown -R chorus2:chorus2 /srv/chorus2
```

## 2. 密码（只放这里，不进仓库）
```bash
sudo install -m 600 -o root -g root /dev/null /etc/chorus2/env
sudoedit /etc/chorus2/env      # 写一行：AICHAT_PASSWORD=你的密码
```
模型 key 在 App 里「加一个 AI」填，存在 `/srv/chorus2/data/config.json`（只有 chorus2 用户可读）。

## 3. systemd
```bash
sudo cp /srv/chorus2/app/server/deploy/chorus2.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now chorus2
curl -s http://127.0.0.1:8791/api/hello        # {"app": "aichat", ...}
```

## 4. nginx
把 `deploy/nginx-chorus2.conf` 的内容放进现有 `server { }` 里（或 `include` 它），然后：
```bash
sudo nginx -t && sudo systemctl reload nginx
curl -s https://<域名或 IP>/chorus2/api/hello
```

## 5. App
首次打开「定调 / 连接服务器」：地址填 `https://<域名或 IP>/chorus2`，密码填第 2 步的密码。地址随时可在 设置 → 服务器 改。

## 6. 升级与回滚
```bash
cd /srv/chorus2/app && sudo -u chorus2 git pull && sudo systemctl restart chorus2
# 回滚：sudo -u chorus2 git checkout <上一个提交> && sudo systemctl restart chorus2
```
数据目录有自动备份（`/srv/chorus2/data/backups`）；恢复见 设置 → 备份。

## 7. 检查清单
- `systemctl status chorus2` 为 active；`journalctl -u chorus2 -n 50` 无报错。
- 旧实例仍正常（它的端口/路径照旧可访问）。
- `/chorus2/api/ws` 能升级为 WebSocket（App 里进度实时变化）。

## Other install routes (ported from the old server, re-pointed at the side-by-side instance)
- `install.sh` — one-line installer for a friend's server: venv in /opt/chorus2, data /var/lib/chorus2, env /etc/chorus2.env, unit chorus2, port 8791, health check + `server.py doctor`, prints the pairing code. Never touches the old `chorus` unit.
- `Dockerfile` / `docker-compose.yml` — same server in a container (port 8791, volume `chorus2`).
