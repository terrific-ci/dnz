#!/bin/sh
# Install DNZ on Linux: downloads dnz and dnz-proxy from the DNZ image on
# Docker Hub (no Docker needed) and puts them in /usr/local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/terrific-ci/dnz/main/install.sh | sh
#
# With --service it also runs dnz as a systemd service: the unit, the
# settings file, port 53 freed from systemd-resolved's stub, and started.
#
#   curl -fsSL https://raw.githubusercontent.com/terrific-ci/dnz/main/install.sh | sh -s -- --service
#
# Options (after `sh -s --` when piped):
#   --service       also set up and start the dnz systemd service
#   --version X     install version X (default: the latest release)
#   --only NAME     install only dnz or only dnz-proxy
#   --dir DIR       install into DIR (default: /usr/local/bin)
#   -h, --help
#
# DNZ_VERSION and DNZ_INSTALL_DIR work too. Running it again upgrades.
set -eu

IMAGE=${DNZ_IMAGE:-terrificci/dnz}
VERSION=${DNZ_VERSION:-latest}
DIR=${DNZ_INSTALL_DIR:-/usr/local/bin}
ONLY=""
SERVICE=""

if [ -t 1 ]; then B=$(printf '\033[1m') C=$(printf '\033[36m') R=$(printf '\033[31m') N=$(printf '\033[0m'); else B='' C='' R='' N=''; fi
step() { printf '%s→%s %s\n' "$C" "$N" "$*"; }
fail() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Install DNZ (dnz and dnz-proxy) from the DNZ image on Docker Hub.

Options:
  --service       also set up and start the dnz systemd service
  --version X     install version X (default: the latest release)
  --only NAME     install only dnz or only dnz-proxy
  --dir DIR       install into DIR (default: /usr/local/bin)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE=1; shift ;;
    --version) [ $# -ge 2 ] || fail "--version needs a value"; VERSION=$2; shift 2 ;;
    --version=*) VERSION=${1#*=}; shift ;;
    --only) [ $# -ge 2 ] || fail "--only needs a value"; ONLY=$2; shift 2 ;;
    --only=*) ONLY=${1#*=}; shift ;;
    --dir) [ $# -ge 2 ] || fail "--dir needs a value"; DIR=$2; shift 2 ;;
    --dir=*) DIR=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
done

case "$ONLY" in
  "") BINARIES="dnz dnz-proxy" ;;
  dnz|dnz-proxy) BINARIES=$ONLY ;;
  *) fail "--only takes dnz or dnz-proxy, not $ONLY" ;;
esac
if [ -n "$SERVICE" ]; then
  # dnz-proxy needs its DNZ address and token first; the dashboard shows its
  # setup (Settings → Proxy → Set up dnz-proxy).
  [ "$ONLY" != dnz-proxy ] || fail "--service sets up dnz; for dnz-proxy use Settings → Proxy → Set up dnz-proxy in the dashboard"
  BINARIES=dnz
fi
# Image tags have no leading v: 1.0.0, 1.0, latest.
VERSION=${VERSION#v}

# --- The machine -------------------------------------------------------------

[ "$(uname -s)" = Linux ] || fail "DNZ runs on Linux; on another system use the Docker image (terrificci/dnz)"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "no DNZ build for $(uname -m); there are amd64 and arm64" ;;
esac
if ldd --version 2>&1 | grep -qi musl; then
  fail "DNZ needs a glibc-based distribution (Debian, Ubuntu, RHEL and similar), not Alpine or another musl one; use the Docker image there"
fi
for tool in curl tar gzip; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
if command -v sha256sum >/dev/null 2>&1; then SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA256="shasum -a 256"
else fail "sha256sum is required"; fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$DIR" 2>/dev/null || true
  if [ ! -d "$DIR" ] || [ ! -w "$DIR" ]; then
    command -v sudo >/dev/null 2>&1 || fail "$DIR isn't writable; run as root or pick another --dir"
    SUDO=sudo
  fi
fi

# The service needs root for /etc and systemctl, whatever --dir is.
ROOT=""
if [ -n "$SERVICE" ]; then
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
    || fail "--service needs systemd; without it see Deploy → systemd → Without systemd in the DNZ docs"
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "--service needs root; run it as root or install sudo"
    ROOT=sudo
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- Docker Hub --------------------------------------------------------------

REGISTRY=https://registry-1.docker.io/v2/$IMAGE
TOKEN=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$IMAGE:pull" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || true
[ -n "$TOKEN" ] || fail "couldn't reach Docker Hub (auth.docker.io)"

# get URL [Accept...]: a registry request with the pull token.
get() {
  url=$1; shift
  accept=""
  for a in "$@"; do accept="${accept:+$accept, }$a"; done
  if [ -n "$accept" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: $accept" "$url"
  else
    curl -fsSL -H "Authorization: Bearer $TOKEN" "$url"
  fi
}

# One JSON object per line, each starting at its "mediaType" (registry JSON
# without jq: an index lists manifests, a manifest lists its layers).
entries() { tr -d ' \t\r\n' | sed 's/"mediaType"/\
"mediaType"/g'; }
digest_of() { grep -o '"digest":"sha256:[0-9a-f]*"' | head -n 1 | cut -d '"' -f 4; }

step "Looking up ${B}$IMAGE:$VERSION${N} for linux/$ARCH"
manifest=$(get "$REGISTRY/manifests/$VERSION" \
  application/vnd.oci.image.index.v1+json \
  application/vnd.docker.distribution.manifest.list.v2+json \
  application/vnd.oci.image.manifest.v1+json \
  application/vnd.docker.distribution.manifest.v2+json) \
  || fail "version $VERSION wasn't found (tags look like 1.0.0, 1.0 or latest)"

if ! printf '%s' "$manifest" | grep -q '"layers"'; then
  # An index: pick this machine's platform.
  digest=$(printf '%s' "$manifest" | entries | grep "\"architecture\":\"$ARCH\"" | grep '"os":"linux"' | digest_of)
  [ -n "$digest" ] || fail "$IMAGE:$VERSION has no linux/$ARCH build"
  manifest=$(get "$REGISTRY/manifests/$digest" \
    application/vnd.oci.image.manifest.v1+json \
    application/vnd.docker.distribution.manifest.v2+json) || fail "couldn't download the image manifest"
fi

# Layers, newest first: dnz and dnz-proxy are copied in last.
layers=""
for d in $(printf '%s' "$manifest" | entries | grep -e 'layer' -e 'rootfs' | grep -o '"digest":"sha256:[0-9a-f]*"' | cut -d '"' -f 4); do
  layers="$d $layers"
done
[ -n "$layers" ] || fail "the image manifest lists no layers"

missing=$BINARIES
for layer in $layers; do
  [ -n "$missing" ] || break
  blob=$TMP/layer.tar.gz
  get "$REGISTRY/blobs/$layer" > "$blob" || fail "couldn't download layer $layer"
  sum=$($SHA256 "$blob" | cut -d ' ' -f 1)
  [ "sha256:$sum" = "$layer" ] || fail "layer $layer doesn't match its checksum"
  list=$(tar -tzf "$blob" 2>/dev/null) || continue
  still=""
  for bin in $missing; do
    member=$(printf '%s\n' "$list" | grep -x -e "usr/local/bin/$bin" -e "\./usr/local/bin/$bin" | head -n 1) || true
    if [ -n "$member" ]; then
      tar -xzf "$blob" -C "$TMP" "$member"
      mv "$TMP/$member" "$TMP/$bin"
    else
      still="$still $bin"
    fi
  done
  missing=${still# }
  rm -f "$blob"
done
[ -z "$missing" ] || fail "$missing wasn't found in $IMAGE:$VERSION"

# --- Install -----------------------------------------------------------------

# Check that they start here before replacing anything (an older glibc
# shows up now, not when the service restarts).
for bin in $BINARIES; do
  chmod 0755 "$TMP/$bin"
  if ! out=$("$TMP/$bin" --version 2>&1); then
    printf '%s\n' "$out" >&2
    fail "$bin $VERSION doesn't run on this machine (glibc $(ldd --version 2>&1 | head -n 1 | grep -o '[0-9][0-9.]*$' || echo unknown)); nothing was installed"
  fi
  versions="${versions:-}${versions:+, }$out"
done

$SUDO mkdir -p "$DIR"
for bin in $BINARIES; do
  # Copy next to it, then rename: replaces a running binary safely.
  $SUDO cp "$TMP/$bin" "$DIR/.$bin.new"
  $SUDO chmod 0755 "$DIR/.$bin.new"
  $SUDO mv -f "$DIR/.$bin.new" "$DIR/$bin"
  step "Installed ${B}$DIR/$bin${N}"
done

printf '\n%s\n' "$versions"

if [ -z "$SERVICE" ]; then
  running=""
  if command -v systemctl >/dev/null 2>&1; then
    for bin in $BINARIES; do
      systemctl is-active --quiet "$bin" 2>/dev/null && running="$running $bin"
    done
  fi
  echo
  if [ -n "$running" ]; then
    echo "Restart the running service to use the new version:"
    echo "  sudo systemctl restart${running}"
  else
    echo "Next: run it as a service, or run this again with --service to have it done"
    echo "(Deploy → systemd in the DNZ docs)."
  fi
  exit 0
fi

# --- The systemd service -----------------------------------------------------
# The unit and settings file are the ones in Deploy → systemd; keep them the same.

UNIT=/etc/systemd/system/dnz.service
ENVFILE=/etc/dnz/dnz.env
echo

cat > "$TMP/dnz.service" <<EOF
[Unit]
Description=DNZ DNS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DIR/dnz
Restart=on-failure
RestartSec=2

# Its own throwaway user; data lives in /var/lib/dnz.
DynamicUser=yes
StateDirectory=dnz
WorkingDirectory=/var/lib/dnz
Environment=DNZ_DATABASE_URL=sqlite:///var/lib/dnz/dnz.db
Environment=DNZ_DNS_ADDR=0.0.0.0:53
Environment=DNZ_HTTP_ADDR=127.0.0.1:8080
# Settings here override the ones above.
EnvironmentFile=-/etc/dnz/dnz.env
# DoT/HTTPS: let the service read TLS keys owned by group ssl-cert (Debian/Ubuntu).
#SupplementaryGroups=ssl-cert

# Ports 53 (and 853/443 for DoT/HTTPS) without root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
EOF

if [ ! -f "$UNIT" ]; then
  $ROOT install -m 644 "$TMP/dnz.service" "$UNIT"
  step "Created ${B}$UNIT${N}"
elif ! $ROOT cmp -s "$TMP/dnz.service" "$UNIT"; then
  $ROOT cp "$UNIT" "$UNIT.bak"
  $ROOT install -m 644 "$TMP/dnz.service" "$UNIT"
  step "Updated ${B}$UNIT${N} (the old one is in $UNIT.bak)"
fi

# The settings file is yours: created once, never overwritten.
if ! $ROOT test -f "$ENVFILE"; then
  cat > "$TMP/dnz.env" <<'EOF'
# DNZ settings; every one is optional. After a change: sudo systemctl restart dnz

# Where DNS listens. 0.0.0.0:53 clashes with systemd-resolved's stub on
# Ubuntu/Debian; see "Port 53 and systemd-resolved".
#DNZ_DNS_ADDR=0.0.0.0:53

# The web UI and API. Keep it on 127.0.0.1 behind an HTTPS reverse proxy.
#DNZ_HTTP_ADDR=127.0.0.1:8080

# The reverse proxy's address, so the audit log shows real client IPs.
#DNZ_TRUSTED_PROXIES=127.0.0.1,::1

# Name shown in notifications.
#DNZ_INSTANCE_NAME=dns-1

# Create the first admin at startup instead of using the setup page.
#DNZ_ADMIN_USERNAME=admin
#DNZ_ADMIN_PASSWORD=

# Default upstreams and strategy on first start (changeable in the UI).
#DNZ_UPSTREAM=1.1.1.1:53,8.8.8.8:53
#DNZ_FORWARD_STRATEGY=failover

# DNS over TLS / QUIC, HTTPS and DoH over HTTP/3. PEM files, re-read when they change.
#DNZ_TLS_CERT=/etc/dnz/tls/certificates/dns.example.com.crt
#DNZ_TLS_KEY=/etc/dnz/tls/certificates/dns.example.com.key
EOF
  $ROOT install -D -m 600 "$TMP/dnz.env" "$ENVFILE"
  step "Created ${B}$ENVFILE${N}"
fi

# setting KEY DEFAULT: the value the service gets (the settings file wins).
setting() {
  v=$($ROOT sed -n "s/^[[:space:]]*$1=//p" "$ENVFILE" 2>/dev/null | tail -n 1 | tr -d "\"'" || true)
  printf '%s' "${v:-$2}"
}
DNS_ADDR=$(setting DNZ_DNS_ADDR 0.0.0.0:53)
HTTP_ADDR=$(setting DNZ_HTTP_ADDR 127.0.0.1:8080)

# Port 53: only a wildcard address clashes with systemd-resolved's stub on
# 127.0.0.53; a server bound to one LAN address doesn't.
start=1
case "$DNS_ADDR" in
  0.0.0.0:*|"[::]":*|:*)
    port=${DNS_ADDR##*:}
    if command -v ss >/dev/null 2>&1; then
      others=$($ROOT ss -Hlunp "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d '"' -f 2 | grep -vx dnz | sort -u | tr '\n' ' ' || true)
      others=${others% }
      if [ "$others" = systemd-resolve ]; then
        step "Freeing port $port: turning off systemd-resolved's stub listener"
        $ROOT mkdir -p /etc/systemd/resolved.conf.d
        conf=/etc/systemd/resolved.conf.d/dnz.conf
        if ! $ROOT test -f "$conf"; then
          printf '[Resolve]\nDNSStubListener=no\n' | $ROOT tee "$conf" >/dev/null
        elif ! $ROOT grep -q '^DNSStubListener=no' "$conf"; then
          printf 'DNSStubListener=no\n' | $ROOT tee -a "$conf" >/dev/null
        fi
        # resolv.conf points at the stub, which is gone now: use resolved's
        # real upstream list so this server still resolves names.
        if [ "$(readlink /etc/resolv.conf 2>/dev/null || true)" != /run/systemd/resolve/resolv.conf ] \
          && grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
          $ROOT ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
          step "Pointed ${B}/etc/resolv.conf${N} at /run/systemd/resolve/resolv.conf"
        fi
        $ROOT systemctl restart systemd-resolved
      elif [ -n "$others" ]; then
        printf '%swarning:%s port %s is taken by %s; dnz is set up but not started.\n' "$R" "$N" "$port" "$others" >&2
        echo "Stop that program, or set DNZ_DNS_ADDR=<this server's IP>:53 in $ENVFILE," >&2
        echo "then: sudo systemctl start dnz (Deploy → Port 53 in the DNZ docs)." >&2
        start=""
      fi
    fi
    ;;
esac

$ROOT systemctl daemon-reload
$ROOT systemctl enable --quiet dnz
[ -n "$start" ] || exit 1

# restart, not start: a rerun upgrades a running dnz.
$ROOT systemctl restart dnz
step "Starting ${B}dnz${N}"
# A bad start (a taken port, a bad setting) crashes within a second and
# then waits to restart, so it has to stay up a few seconds.
i=0
while [ $i -lt 4 ]; do
  sleep 1
  if ! systemctl is-active --quiet dnz; then
    echo >&2
    $ROOT journalctl -u dnz -n 15 --no-pager >&2 || true
    echo >&2
    fail "dnz didn't start; see above, or: journalctl -u dnz -e"
  fi
  i=$((i + 1))
done

dash=$HTTP_ADDR
case "$dash" in 0.0.0.0:*|"[::]":*|:*) dash=127.0.0.1:${dash##*:} ;; esac
printf '\n%sDNZ is running.%s\n\n' "$B" "$N"
echo "  Dashboard  http://$dash  (create the first admin there)"
case "$HTTP_ADDR" in
  127.*|localhost:*|"[::1]":*)
    echo "             only on this server; from your computer:"
    echo "             ssh -L ${dash##*:}:$dash $(id -un)@$(hostname)  then open http://localhost:${dash##*:}" ;;
esac
echo "  DNS        $DNS_ADDR"
echo "  Settings   $ENVFILE, then: sudo systemctl restart dnz"
echo "  Logs       journalctl -u dnz -f"
