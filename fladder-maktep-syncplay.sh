#!/usr/bin/env bash
set -euo pipefail

CTID="${CTID:-123}"
HOSTNAME="fladder-maktep"
DISK="${DISK:-16}"
RAM="${RAM:-4096}"
CPU="${CPU:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DEBIAN_TEMPLATE="debian-13-standard_13.1-2_amd64.tar.zst"

REPO="https://github.com/irican-f/Fladder-Maktep.git"
BRANCH="maktep-syncplay"

echo "== Download Debian 13 template if missing =="
pveam update
pveam download "$TEMPLATE_STORAGE" "$DEBIAN_TEMPLATE" || true

echo "== Create LXC $CTID =="
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$DEBIAN_TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" \
  --memory "$RAM" \
  --swap 1024 \
  --rootfs "$STORAGE:$DISK" \
  --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  --unprivileged 1 \
  --features nesting=1 \
  --ostype debian \
  --start 1

echo "== Wait for container network =="
sleep 8

echo "== Install Fladder Maktep SyncPlay build =="
pct exec "$CTID" -- bash -lc "
set -e

apt update
apt install -y \
  git curl unzip xz-utils zip nginx ca-certificates \
  clang cmake ninja-build pkg-config libgtk-3-dev

mkdir -p /opt
cd /opt

if [ ! -d flutter ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1
fi

export PATH=/opt/flutter/bin:\$PATH
flutter config --enable-web
flutter doctor || true

rm -rf /opt/fladder-src
git clone --branch $BRANCH --depth 1 $REPO /opt/fladder-src

cd /opt/fladder-src
flutter pub get
flutter build web --release

rm -rf /opt/fladder
mkdir -p /opt/fladder
cp -a build/web/* /opt/fladder/

cat >/etc/nginx/sites-available/fladder <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /opt/fladder;
    index index.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|wasm|json)$ {
        expires 7d;
        add_header Cache-Control \"public, immutable\";
        try_files \$uri =404;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fladder /etc/nginx/sites-enabled/fladder

nginx -t
systemctl enable nginx
systemctl restart nginx
"

IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

echo
echo "Done."
echo "Fladder Maktep SyncPlay:"
echo "http://$IP"
