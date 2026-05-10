pct exec "$CTID" -- env REPO="$REPO" BRANCH="$BRANCH" TZ="$TZ" bash -s <<'LXC_SCRIPT'
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y \
  git curl unzip xz-utils zip nginx ca-certificates tar python3 tzdata \
  build-essential clang cmake ninja-build pkg-config

ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
echo "$TZ" > /etc/timezone

mkdir -p /opt
cd /opt

export TAR_OPTIONS=--no-same-owner

echo "== Install Flutter =="
if [ ! -d /opt/flutter ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 /opt/flutter
fi

export PATH=/opt/flutter/bin:$PATH

flutter config --enable-web
flutter doctor || true

echo "== Clone Fladder SyncPlay =="
rm -rf /opt/fladder-src
git clone --branch "$BRANCH" --depth 1 "$REPO" /opt/fladder-src

cd /opt/fladder-src

echo "== Apply optional patch (safe) =="
python3 <<'PY'
from pathlib import Path
import re

for p in Path("lib").rglob("*.dart"):
    try:
        s = p.read_text()
    except:
        continue

    new = s.replace("repeatall", "repeatAll")

    new = re.sub(
        r"import .*jellyfin_open_api.*\n?",
        "",
        new
    )

    if new != s:
        p.write_text(new)
PY

echo "== Build =="
flutter clean
flutter pub get

# More stable build flags
flutter build web --release

echo "== Deploy =="
rm -rf /opt/fladder
mkdir -p /opt/fladder
cp -a build/web/. /opt/fladder/

cat >/etc/nginx/sites-available/fladder <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /opt/fladder;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Prevent stale UI (important for Flutter apps)
    location = /index.html {
        add_header Cache-Control "no-store";
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|wasm|json)$ {
        expires 1h;
        add_header Cache-Control "public";
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fladder /etc/nginx/sites-enabled/fladder

nginx -t
systemctl restart nginx
systemctl enable nginx

echo "== DONE =="
LXC_SCRIPT
