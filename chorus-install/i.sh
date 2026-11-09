#!/bin/bash
# Chorus 服务端一键安装（干净安装：不带任何别人的数据、密钥）
# 用法：curl -fsSL <本文件地址> | sudo bash -s <解密码>
set -o pipefail
KEY="$1"
BASE="https://fastly.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@369a31d9e9e386d3b2e4fc45f4cb9530459321c4/chorus-install https://testingcf.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@369a31d9e9e386d3b2e4fc45f4cb9530459321c4/chorus-install https://cdn.jsdelivr.net/gh/ndx700/nade-atlas-next-updates@369a31d9e9e386d3b2e4fc45f4cb9530459321c4/chorus-install https://raw.githubusercontent.com/ndx700/nade-atlas-next-updates/369a31d9e9e386d3b2e4fc45f4cb9530459321c4/chorus-install"
PKG_SHA="2eef00faaf24bdd8b6af62c219250f23e2f03bbf554373b763204e5e54a3331b"
APP=${CHORUS_APP:-/opt/dsh-app}; SRV=$APP/server; DATA=$SRV/data; SVC=chorus-app
UNITDIR=${CHORUS_UNITDIR:-/etc/systemd/system}; INFOBIN=${CHORUS_INFOBIN:-/usr/local/bin/chorus-info}   # 后两个只给测试改
PORT="${CHORUS_PORT:-8787}"
NODEV=22.11.0
say(){ printf '\033[1;33m[Chorus]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[Chorus] %s\033[0m\n' "$*"; exit 1; }
[ "$(id -u)" = 0 ] || die "要用 root 运行：命令前面加 sudo"
[ -n "$KEY" ] || die "命令不完整（缺少最后那串解密码），请重新复制整条命令"

info(){ cat > $INFOBIN <<'INFO'
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
chmod 755 $INFOBIN; }

# ── 装过了：原地升级（只换程序，不动 data/、config.json、node_modules） ──
UPGRADE=
if [ -f $SRV/config.json ] || [ -d $DATA ]; then UPGRADE=1; fi

# 下载 → 校验 sha256 → 解密 → 解到 $1（得到 $1/server/…）。出错直接退出，不动已装的东西
fetch_pkg(){
  local X="$1" T; T=$(mktemp -d); mkdir -p "$X"
  local ok= b
  for b in $BASE; do curl -fsSL --max-time 300 -o $T/s.enc "$b/server.tgz.enc" && [ "$(sha256sum < $T/s.enc | cut -c1-64)" = "$PKG_SHA" ] && ok=1 && break; done
  [ -n "$ok" ] || die "下载失败，稍后再试"
  [ "$(sha256sum < $T/s.enc | cut -c1-64)" = "$PKG_SHA" ] || die "文件校验不对，可能下载不完整，重新运行一次"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$KEY" -in $T/s.enc > $T/s.tgz 2>/dev/null && tar xzf $T/s.tgz -C "$X" 2>/dev/null || die "解密失败：命令最后那串解密码不对"
  rm -rf $T
  [ -f "$X/server/src/index.mjs" ] || die "安装包内容不对"
}
# 自更新要用的解密码：放在 server 目录下的 .pkgkey（权限 600，只有服务用户能读）
save_key(){ printf '%s\n' "$KEY" > $SRV/.pkgkey; chmod 600 $SRV/.pkgkey; id chorus >/dev/null 2>&1 && chown chorus:chorus $SRV/.pkgkey; return 0; }
health(){ local P i; P=$(grep -o '"port": *[0-9]*' $SRV/config.json 2>/dev/null | grep -o '[0-9]*$'); P=${P:-$PORT}
  for i in $(seq ${1:-40}); do curl -fs --max-time 2 http://127.0.0.1:$P/api/health >/dev/null && return 0; sleep 1; done; return 1; }

if [ -n "$UPGRADE" ]; then
  say "这台服务器已经装过 Chorus，原地升级程序（你的数据、密码、模型设置、已装组件都不动）。"
  for c in curl tar openssl; do command -v $c >/dev/null || die "缺少 $c，请先装好再运行"; done
  NODE=$APP/node/bin/node; [ -x $NODE ] || NODE=$(command -v node || true); [ -n "$NODE" ] || die "找不到 Node.js"
  NBIN=$(dirname $NODE); export PATH=$NBIN:$PATH
  BK=$APP/backup-$(date +%Y%m%d%H%M%S)
  say "1/4 备份当前程序到 $BK …"
  mkdir -p $BK && chmod 700 $BK
  tar -C $SRV --exclude=./data --exclude=./node_modules --exclude=./config.json --exclude=./.pkgkey -czf $BK/server-code.tgz . || die "备份失败，已取消升级（什么都没改）"
  say "2/4 下载并校验新版…"
  X=$(mktemp -d); fetch_pkg $X
  NEW=$X/server
  # 依赖有没有变（package.json 的 dependencies）
  DEPS_CHANGED=$($NODE -e 'const f=p=>{try{return JSON.stringify(JSON.parse(require("fs").readFileSync(p,"utf8")).dependencies||{})}catch{return ""}};process.stdout.write(f(process.argv[1])===f(process.argv[2])?"":"1")' $SRV/package.json $NEW/package.json)
  say "3/4 替换程序文件…"
  REPLACED=""
  for f in $(cd $NEW && ls -A); do
    case $f in data|node_modules|config.json|.pkgkey) continue;; esac
    rm -rf $SRV/$f; cp -a $NEW/$f $SRV/$f; REPLACED="$REPLACED $f"
  done
  rm -rf $X
  rollback(){ say "新版没起来，回滚到旧版程序…"; for f in $REPLACED; do rm -rf $SRV/$f; done
    tar -xzf $BK/server-code.tgz -C $SRV; id chorus >/dev/null 2>&1 && chown -R chorus:chorus $SRV --no-dereference 2>/dev/null
    systemctl restart $SVC 2>/dev/null; health 30 && say "已恢复旧版（备份留在 $BK）" || say "旧版也没起来，运行 journalctl -u $SVC -n 50 看原因；备份在 $BK"
    die "升级失败，已回滚程序文件，数据没动"; }
  if [ -n "$DEPS_CHANGED" ] && [ "${CHORUS_SKIP_NPM:-}" != 1 ]; then
    say "   依赖有变化，安装组件…"
    cd $SRV; REG=https://registry.npmmirror.com; curl -s --max-time 5 -o /dev/null $REG || REG=https://registry.npmjs.org
    $NBIN/npm install --omit=dev --no-audit --no-fund --registry=$REG >/tmp/chorus-npm.log 2>&1 || { say "组件安装失败，日志在 /tmp/chorus-npm.log"; rollback; }
  fi
  save_key
  id chorus >/dev/null 2>&1 && for f in $REPLACED; do chown -R chorus:chorus $SRV/$f; done
  [ -d $SRV/node_modules ] && [ -n "$DEPS_CHANGED" ] && id chorus >/dev/null 2>&1 && chown -R chorus:chorus $SRV/node_modules
  say "4/4 重启并自检…"
  systemctl restart $SVC 2>/dev/null
  health 40 || rollback
  NV=$($NODE -p 'require(process.argv[1]).version' $SRV/package.json 2>/dev/null)
  say "升级完成，当前版本 ${NV:-?}。旧程序备份在 $BK"
  info; $INFOBIN; exit 0
fi

# ── 系统依赖 ──
say "1/5 安装系统依赖…"
if [ "${CHORUS_SKIP_DEPS:-}" = 1 ]; then :
elif command -v apt-get >/dev/null; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates tar xz-utils openssl python3 python3-pip git >/dev/null 2>&1
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
X=$(mktemp -d); fetch_pkg $X; mkdir -p $APP; cp -a $X/server $APP/ && rm -rf $X
rm -f $SRV/config.json; rm -rf $DATA   # 双保险：保证是空白服务器
save_key

say "4/5 安装组件（国内镜像，1~3 分钟）…"
cd $SRV
REG=https://registry.npmmirror.com
curl -s --max-time 5 -o /dev/null $REG || REG=https://registry.npmjs.org
[ "${CHORUS_SKIP_NPM:-}" = 1 ] || $NBIN/npm install --omit=dev --no-audit --no-fund --registry=$REG >/tmp/chorus-npm.log 2>&1 || die "组件安装失败，日志在 /tmp/chorus-npm.log"
say "   装 PPT / 文档 / 视频要用的组件（再等 1~3 分钟）…"
[ "${CHORUS_SKIP_NPM:-}" = 1 ] || bash $SRV/tools/setup-deps.sh >/tmp/chorus-deps.log 2>&1 || say "   这部分没装全，不影响聊天；PPT/视频可能用不了，日志 /tmp/chorus-deps.log"
mkdir -p $DATA
if [ "$PORT" != 8787 ]; then printf '{"server":{"port":%s,"publicUrl":null},"auth":{},"models":{"default":null,"providers":[]}}\n' "$PORT" > $SRV/config.json; fi

# 单独的系统用户跑服务，不用 root
id chorus >/dev/null 2>&1 || useradd -r -m -d $APP/home -s /bin/bash chorus
chown -R chorus:chorus $APP
cat > $UNITDIR/$SVC.service <<UNIT
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
info; $INFOBIN
