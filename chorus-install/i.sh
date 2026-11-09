#!/bin/bash
# Chorus 服务端一键安装（干净安装：不带任何别人的数据、密钥）
# 用法：curl -fsSL <本文件地址> | sudo bash -s <解密码>
set -o pipefail
KEY="$1"
BASE="https://fastly.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@3ee144acf52bd4f4e275f6a7ce97023480e7959b/chorus-install https://testingcf.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@3ee144acf52bd4f4e275f6a7ce97023480e7959b/chorus-install https://cdn.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@3ee144acf52bd4f4e275f6a7ce97023480e7959b/chorus-install https://raw.githubusercontent.com/ndx700/nade-atlas-next-updates/3ee144acf52bd4f4e275f6a7ce97023480e7959b/chorus-install"
PKG_SHA="ebfc4b9cdde0cec0bbb9a8926dd8ab76560fea4c6157434e29694a9c4e5ed52a"
APP=/opt/dsh-app; SRV=$APP/server; DATA=$SRV/data; SVC=chorus-app
PORT="${CHORUS_PORT:-8787}"
NODEV=22.11.0
say(){ printf '\033[1;33m[Chorus]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[Chorus] %s\033[0m\n' "$*"; exit 1; }
[ "$(id -u)" = 0 ] || die "要用 root 运行：命令前面加 sudo"
[ -n "$KEY" ] || die "命令不完整（缺少最后那串解密码），请重新复制整条命令"

info(){ cat > /usr/local/bin/chorus-info <<'INFO'
#!/bin/bash
D=/opt/dsh-app/server/data; P=$(grep -o '"port": *[0-9]*' /opt/dsh-app/server/config.json 2>/dev/null | grep -o '[0-9]*$'); P=${P:-8787}
IP=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null | grep -Eo '^[0-9.]+$' || true)
[ -z "$IP" ] && IP=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null | grep -Eo '^[0-9.]+$' || true)
for u in https://ip.sb https://ifconfig.me https://api.ipify.org https://myip.ipip.net; do [ -n "$IP" ] && break; IP=$(curl -4 -s --max-time 4 $u 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1); done
IP=${IP:-你的服务器公网IP}
PIN=$(grep -o '"pin": *"[0-9]*"' $D/first-setup.pin 2>/dev/null | grep -o '[0-9]\{6\}')
C="chorus://$IP:$P"; [ -n "$PIN" ] && C="$C?pin=$PIN"
echo
echo "================ Chorus 装好了 ================"
echo " 接入码（复制整行，粘到 App 第一页）："
echo
echo "   $C"
echo
[ -z "$PIN" ] && echo " （这台服务器已经设过密码，App 里直接用密码登录）"
echo " 连不上的话：去云服务器控制台 → 安全组，放行 TCP $P 端口"
echo " 以后想再看这段，运行：sudo chorus-info"
echo "=============================================="
INFO
chmod 755 /usr/local/bin/chorus-info; }

# ── 装过了就不动数据，只把接入码再给一遍 ──
if [ -f $SRV/config.json ] || [ -d $DATA ]; then
  say "这台服务器已经装过 Chorus，不会覆盖已有数据。"
  info; systemctl is-active --quiet $SVC || systemctl restart $SVC 2>/dev/null; /usr/local/bin/chorus-info; exit 0
fi

# ── 系统依赖 ──
say "1/5 安装系统依赖…"
if command -v apt-get >/dev/null; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates tar xz-utils openssl python3 python3-pip git >/dev/null 2>&1
elif command -v dnf >/dev/null; then dnf install -y -q curl ca-certificates tar xz openssl python3 python3-pip git >/dev/null 2>&1
elif command -v yum >/dev/null; then yum install -y -q curl ca-certificates tar xz openssl python3 python3-pip git >/dev/null 2>&1
fi
for c in curl tar openssl python3; do command -v $c >/dev/null || die "缺少 $c，自动安装失败，请先装好再运行"; done

# ── Node.js（自带一份，不动系统里的） ──
say "2/5 准备 Node.js…"
mkdir -p $APP
NODE=$(command -v node || true)
if [ -n "$NODE" ] && [ "$($NODE -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ]; then :; else
  case $(uname -m) in x86_64) A=x64;; aarch64|arm64) A=arm64;; *) die "不支持的 CPU：$(uname -m)";; esac
  F=node-v$NODEV-linux-$A.tar.xz; ok=
  for m in https://cdn.npmmirror.com/binaries/node/v$NODEV https://npmmirror.com/mirrors/node/v$NODEV https://nodejs.org/dist/v$NODEV; do
    curl -fsSL --max-time 300 -o /tmp/$F $m/$F && ok=1 && break
  done
  [ -n "$ok" ] || die "Node.js 下载失败，检查服务器能不能上网"
  rm -rf $APP/node && mkdir -p $APP/node && tar xJf /tmp/$F -C $APP/node --strip-components=1 && rm -f /tmp/$F
  NODE=$APP/node/bin/node
fi
NBIN=$(dirname $NODE); export PATH=$NBIN:$PATH

# ── 服务端程序 ──
say "3/5 下载服务端…"
T=$(mktemp -d)
ok=
for b in $BASE; do curl -fsSL --max-time 300 -o $T/s.enc "$b/server.tgz.enc" && [ "$(sha256sum < $T/s.enc | cut -c1-64)" = "$PKG_SHA" ] && ok=1 && break; done
[ -n "$ok" ] || die "下载失败，稍后再试"
[ "$(sha256sum < $T/s.enc | cut -c1-64)" = "$PKG_SHA" ] || die "文件校验不对，可能下载不完整，重新运行一次"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$KEY" -in $T/s.enc | tar xz -C $APP || die "解密失败：命令最后那串解密码不对"
rm -rf $T
rm -f $SRV/config.json; rm -rf $DATA   # 双保险：保证是空白服务器

say "4/5 安装组件（国内镜像，1~3 分钟）…"
cd $SRV
REG=https://registry.npmmirror.com
curl -s --max-time 5 -o /dev/null $REG || REG=https://registry.npmjs.org
$NBIN/npm install --omit=dev --no-audit --no-fund --registry=$REG >/tmp/chorus-npm.log 2>&1 || die "组件安装失败，日志在 /tmp/chorus-npm.log"
say "   装 PPT / 文档 / 视频要用的组件（再等 1~3 分钟）…"
bash $SRV/tools/setup-deps.sh >/tmp/chorus-deps.log 2>&1 || say "   这部分没装全，不影响聊天；PPT/视频可能用不了，日志 /tmp/chorus-deps.log"
mkdir -p $DATA
if [ "$PORT" != 8787 ]; then printf '{"server":{"port":%s,"publicUrl":null},"auth":{},"models":{"default":null,"providers":[]}}\n' "$PORT" > $SRV/config.json; fi

# 单独的系统用户跑服务，不用 root
id chorus >/dev/null 2>&1 || useradd -r -m -d $APP/home -s /bin/bash chorus
chown -R chorus:chorus $APP
cat > /etc/systemd/system/$SVC.service <<UNIT
[Unit]
Description=Chorus server
After=network-online.target
[Service]
User=chorus
WorkingDirectory=$SRV
Environment=DATA_DIR=$DATA
Environment=PATH=$NBIN:/usr/local/bin:/usr/bin:/bin
Environment=npm_config_registry=$REG
Environment=HOME=$APP/home
Environment=OPEN_SETUP_WINDOW_MS=0
ExecStart=$NODE $SRV/src/index.mjs
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
UNIT
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && ufw allow $PORT/tcp >/dev/null
command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd -q --permanent --add-port=$PORT/tcp; firewall-cmd -q --reload; }

say "5/5 启动…"
systemctl daemon-reload; systemctl enable -q --now $SVC
for i in $(seq 40); do curl -fs --max-time 2 http://127.0.0.1:$PORT/api/health >/dev/null && break; sleep 1; done
curl -fs --max-time 2 http://127.0.0.1:$PORT/api/health >/dev/null || die "服务没起来，运行 journalctl -u $SVC -n 50 看原因"
for i in $(seq 10); do [ -f $DATA/first-setup.pin ] && break; sleep 1; done
info; /usr/local/bin/chorus-info
