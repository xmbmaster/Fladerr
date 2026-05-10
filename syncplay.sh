#!/usr/bin/env bash
set -euo pipefail

CTID="${CTID:-123}"
HOSTNAME="${HOSTNAME:-fladder-maktep-sg}"
DISK="${DISK:-20}"
RAM="${RAM:-4096}"
CPU="${CPU:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DEBIAN_TEMPLATE="${DEBIAN_TEMPLATE:-debian-13-standard_13.1-2_amd64.tar.zst}"

REPO="${REPO:-https://github.com/irican-f/Fladder-Maktep.git}"
BRANCH="${BRANCH:-syncplay}"
TZ="${TZ:-Asia/Singapore}"

echo "== Checking CTID =="
if pct status "$CTID" >/dev/null 2>&1; then
  echo "ERROR: CTID $CTID already exists."
  echo "Delete it first with: pct stop $CTID || true && pct destroy $CTID"
  exit 1
fi

echo "== Download Debian template =="
pveam update
pveam download "$TEMPLATE_STORAGE" "$DEBIAN_TEMPLATE" || true

echo "== Verify git branch exists =="
if ! git ls-remote --heads "$REPO" "$BRANCH" | grep -q "$BRANCH"; then
  echo "ERROR: Branch '$BRANCH' not found in $REPO"
  exit 1
fi

echo "== Create LXC $CTID =="
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$DEBIAN_TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" \
  --memory "$RAM" \
  --swap 1024 \
  --rootfs "$STORAGE:$DISK" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --unprivileged 0 \
  --features nesting=1,keyctl=1 \
  --ostype debian \
  --start 1

echo "== Wait for container network =="
sleep 10

pct exec "$CTID" -- env REPO="$REPO" BRANCH="$BRANCH" TZ="$TZ" bash -s <<'LXC_SCRIPT'
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y \
  git curl unzip xz-utils zip nginx ca-certificates tar python3 tzdata \
  build-essential clang cmake ninja-build pkg-config libgtk-3-dev

ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
echo "$TZ" > /etc/timezone

mkdir -p /opt
cd /opt

export TAR_OPTIONS=--no-same-owner

echo "== Install Flutter stable =="
if [ ! -d /opt/flutter ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 /opt/flutter
fi

export PATH=/opt/flutter/bin:$PATH
git config --global --add safe.directory /opt/flutter

flutter --version
flutter config --enable-web
flutter doctor || true

echo "== Clone Fladder SyncPlay branch =="
rm -rf /opt/fladder-src
git clone --branch "$BRANCH" --depth 1 "$REPO" /opt/fladder-src

cd /opt/fladder-src
git config --global --add safe.directory /opt/fladder-src

echo "== Apply compatibility patch =="
python3 <<'PY'
from pathlib import Path
import re

for p in Path("lib").rglob("*.dart"):
    s = p.read_text(errors="ignore")
    old = s

    s = s.replace("jellyfin_enums.RepeatMode.repeatall", "RepeatMode.repeatAll")
    s = s.replace("RepeatMode.repeatall", "RepeatMode.repeatAll")
    s = s.replace("repeatMode: RepeatMode.repeatall", "repeatMode: RepeatMode.repeatAll")

    s = re.sub(
        r"import 'package:fladder/jellyfin/jellyfin_open_api\.enums\.swagger\.dart' as jellyfin_enums;\n?",
        "",
        s
    )

    if s != old:
        p.write_text(s)
PY

echo "== Build web release =="
flutter clean
flutter pub get
flutter build web --release --no-wasm-dry-run

echo "== Install web files =="
rm -rf /opt/fladder
mkdir -p /opt/fladder
cp -a build/web/. /opt/fladder/

cat >/etc/nginx/sites-available/fladder <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /opt/fladder;
    index index.html;
    server_name _;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-store";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|wasm|json|ttf|woff|woff2)$ {
        try_files $uri =404;
        expires 1h;
        add_header Cache-Control "public, must-revalidate";
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fladder /etc/nginx/sites-enabled/fladder

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "== Done inside LXC =="
LXC_SCRIPT

IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

echo
echo "======================================"
echo "Fladder Maktep SyncPlay Installed!"
echo "Branch: $BRANCH"
echo "Timezone: $TZ"
echo "Access: http://$IP"
echo "======================================"
