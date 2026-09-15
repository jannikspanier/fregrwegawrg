#!/usr/bin/env bash
set -Eeuo pipefail

STORAGE_PATH="/var/lib/vz/template/cache"

apt-get update
apt-get install -y --no-install-recommends -t bookworm-backports debootstrap ubuntu-keyring debian-archive-keyring zstd ca-certificates

slim() {
  mkdir -p "$ROOT/etc/dpkg/dpkg.cfg.d" "$ROOT/etc/apt/apt.conf.d"
  cat > "$ROOT/etc/dpkg/dpkg.cfg.d/01-apexium-minimal" <<'EOF'
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/bash-completion/*
EOF
  cat > "$ROOT/etc/apt/apt.conf.d/99-apexium-minimal" <<'EOF'
Acquire::Languages "none";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
  rm -rf "$ROOT/var/lib/apt/lists/"* "$ROOT/var/cache/apt/"* "$ROOT/usr/share/doc/"* "$ROOT/usr/share/man/"* "$ROOT/usr/share/info/"* "$ROOT/usr/share/locale/"*
  truncate -s 0 "$ROOT/etc/machine-id"
}

ROOT="$(mktemp -d)"
debootstrap --variant=minbase --arch=amd64 --include=systemd-sysv,ifupdown,iproute2 bookworm "$ROOT" http://deb.debian.org/debian
cat > "$ROOT/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF
slim
rm -f "$STORAGE_PATH/apexium-debian-12-minbase.tar.zst"
tar --numeric-owner --xattrs --acls -C "$ROOT" -cpf - . | zstd -19 -T0 -o "$STORAGE_PATH/apexium-debian-12-minbase.tar.zst"
rm -rf "$ROOT"

ROOT="$(mktemp -d)"
debootstrap --variant=minbase --arch=amd64 --include=systemd-sysv,ifupdown,iproute2 trixie "$ROOT" http://deb.debian.org/debian
cat > "$ROOT/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF
slim
rm -f "$STORAGE_PATH/apexium-debian-13-minbase.tar.zst"
tar --numeric-owner --xattrs --acls -C "$ROOT" -cpf - . | zstd -19 -T0 -o "$STORAGE_PATH/apexium-debian-13-minbase.tar.zst"
rm -rf "$ROOT"

ROOT="$(mktemp -d)"
debootstrap --variant=minbase --arch=amd64 --components=main,universe --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg --include=systemd-sysv,ifupdown,iproute2 noble "$ROOT" https://archive.ubuntu.com/ubuntu
cat > "$ROOT/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
slim
rm -f "$STORAGE_PATH/apexium-ubuntu-24.04-minbase.tar.zst"
tar --numeric-owner --xattrs --acls -C "$ROOT" -cpf - . | zstd -19 -T0 -o "$STORAGE_PATH/apexium-ubuntu-24.04-minbase.tar.zst"
rm -rf "$ROOT"