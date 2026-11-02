#!/bin/sh
# Chorus server, one line on any Linux box (Ubuntu/Debian/CentOS…, root):
#   curl -fsSL http://47.100.106.26/ds/chorus/install.sh | sudo sh
# Optional: CHORUS_PASSWORD=… CHORUS_OWNER=你的名字 CHORUS_PORT=8791 before `sh`. CHORUS_PAIR is the one-time code
# the app's 「复制给 AI 一键部署」 puts in the command: the app then signs in by itself once the server is up. Running it again updates the server
# and keeps every chat, member and key (they live in /var/lib/chorus2).
set -e
SRC=${CHORUS_SRC:?set CHORUS_SRC to the chorus2 server tarball URL (the old /ds/chorus tarball is the OLD server)}
PORT=${CHORUS_PORT:-8791}
[ "$(id -u)" = 0 ] || { echo "请用 root 运行（前面加 sudo）"; exit 1; }

echo "== 1/5 安装依赖"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null; apt-get install -y -q python3 python3-venv curl ca-certificates >/dev/null
  apt-get install -y -q ffmpeg >/dev/null 2>&1 || true
elif command -v dnf >/dev/null; then dnf install -y -q python3 curl >/dev/null; dnf install -y -q ffmpeg >/dev/null 2>&1 || true
elif command -v yum >/dev/null; then yum install -y -q python3 curl >/dev/null
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "需要 Python 3.10 以上"; exit 1; }

echo "== 2/5 下载服务器"
mkdir -p /opt/chorus2 /var/lib/chorus2
curl -fsSL "$SRC" -o /tmp/chorus2-server.tar.gz
# 服务端包的 sha256 由 App 命令传入（CHORUS_SHA256），不一致就停，防止下载途中被替换
if [ -n "$CHORUS_SHA256" ]; then
  GOT=$(sha256sum /tmp/chorus2-server.tar.gz | cut -d' ' -f1)
  [ "$GOT" = "$CHORUS_SHA256" ] || { echo "❌ 服务端包校验不通过（期望 $CHORUS_SHA256，实际 $GOT），已停止"; rm -f /tmp/chorus2-server.tar.gz; exit 1; }
  echo "服务端包校验通过"
fi
# Snapshot using the incoming helper and backup implementation before replacing installed code.
if [ -f /var/lib/chorus2/config.json ]; then
  SNAPSHOT_STAGE=$(mktemp -d)
  tar -C "$SNAPSHOT_STAGE" -xzf /tmp/chorus2-server.tar.gz
  systemctl stop chorus2
  if ! /opt/chorus2/venv/bin/python "$SNAPSHOT_STAGE/server/deploy/pre_upgrade.py" /var/lib/chorus2; then
    rm -rf "$SNAPSHOT_STAGE"
    systemctl start chorus2
    exit 1
  fi
  rm -rf "$SNAPSHOT_STAGE"
fi
rm -rf /opt/chorus2/server; tar -C /opt/chorus2 -xzf /tmp/chorus2-server.tar.gz; rm -f /tmp/chorus2-server.tar.gz

echo "== 3/5 Python 环境（国内走清华镜像）"
[ -x /opt/chorus2/venv/bin/python ] || python3 -m venv /opt/chorus2/venv
PIP="/opt/chorus2/venv/bin/pip install -q --disable-pip-version-check"
$PIP -r /opt/chorus2/server/requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null || $PIP -r /opt/chorus2/server/requirements.txt

echo "== 4/5 服务"
ENV=/etc/chorus2.env
if [ ! -f $ENV ]; then
  PW=${CHORUS_PASSWORD:-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)}
  umask 077
  printf 'AICHAT_DATA=/var/lib/chorus2\nAICHAT_PORT=%s\nAICHAT_PASSWORD=%s\nAICHAT_OWNER=%s\nPYTHONUNBUFFERED=1\n' "$PORT" "$PW" "${CHORUS_OWNER:-我}" > $ENV
fi
# 不用 root 跑：CLI 声部会执行 AI 给的命令，root 等于把整台服务器交给 AI
id chorus >/dev/null 2>&1 || useradd -r -m -d /var/lib/chorus2 -s /bin/bash chorus 2>/dev/null || useradd -r -d /var/lib/chorus2 -s /bin/bash chorus
chown -R chorus:chorus /var/lib/chorus2
chown -R root:root /opt/chorus2; chmod 600 "$ENV"
# Plugins install with the running interpreter; only its venv is service-writable.
chown -R chorus:chorus /opt/chorus2/venv
cat > /etc/systemd/system/chorus2.service <<UNIT
[Unit]
Description=Chorus server
After=network-online.target
[Service]
User=chorus
Group=chorus
NoNewPrivileges=true
PrivateTmp=true
EnvironmentFile=$ENV
WorkingDirectory=/var/lib/chorus2
ExecStart=/opt/chorus2/venv/bin/python /opt/chorus2/server/server.py
Restart=always
RestartSec=5
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable -q chorus2; systemctl restart chorus2
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && ufw allow "$PORT"/tcp >/dev/null || true

echo "== 5/5 体检"
# 不 source 环境文件（密码里的特殊字符会被当成命令执行），逐项按行读取
AICHAT_PORT=$(grep -m1 "^AICHAT_PORT=" $ENV | cut -d= -f2-)
AICHAT_PASSWORD=$(grep -m1 "^AICHAT_PASSWORD=" $ENV | cut -d= -f2-)
for i in 1 2 3 4 5 6 7 8 9 10; do curl -fsS -m 3 "http://127.0.0.1:$AICHAT_PORT/api/hello" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS -m 3 "http://127.0.0.1:$AICHAT_PORT/api/hello" >/dev/null 2>&1 && echo "✅ 服务已启动" || { echo "❌ 服务没起来："; journalctl -u chorus2 -n 20 --no-pager; exit 1; }
/opt/chorus2/venv/bin/python /opt/chorus2/server/server.py doctor || true
IP=$(curl -fsS -m 5 https://4.ipw.cn 2>/dev/null || curl -fsS -m 5 https://ifconfig.me 2>/dev/null || hostname -I | cut -d' ' -f1)
echo
echo "装好了。在 Chorus app 里填："
echo "  服务器地址  $IP:$(grep AICHAT_PORT $ENV | cut -d= -f2)"
echo "  密码        $(grep AICHAT_PASSWORD $ENV | cut -d= -f2-)"
echo "云服务器记得在安全组里放行 TCP $(grep AICHAT_PORT $ENV | cut -d= -f2) 端口。AI 成员（接口 key）在 app 里添加。"
if [ -n "$CHORUS_PAIR" ]; then
  H=$(printf '%s' "$CHORUS_PAIR" | sha256sum | cut -c1-64)
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"server": sys.argv[1], "password": sys.argv[2]}))' "$IP:$AICHAT_PORT" "$AICHAT_PASSWORD")
  # 密码用配对码加密后再上传（AES-256-CBC + PBKDF2），中转站和链路上的人都只看到密文；没有 openssl 就不上传
  ENC=$(printf '%s' "$BODY" | CHORUS_PAIR="$CHORUS_PAIR" openssl enc -aes-256-cbc -pbkdf2 -salt -base64 -A -pass env:CHORUS_PAIR 2>/dev/null)
  if [ -n "$ENC" ] && curl -fsS -m 15 -X PUT -H 'Content-Type: application/json' --data "{\"enc\":\"$ENC\"}" "http://47.100.106.26/pair/$H.json" >/dev/null; then
    echo "已通知手机上的 Chorus：几秒内会自动登录（端口没放行的话，app 会提示）。"
  else
    echo "没能通知手机上的 Chorus，请在 app 里手动填上面的地址和密码。"
  fi
fi
