#!/usr/bin/env bash
set -Eeuo pipefail

VMID=9100
TEMPLATE_NAME="minecraft-java"
STORAGE="local"
BRIDGE="vmbr3"
BASE_TEMPLATE="${STORAGE}:vztmpl/apexium-debian-13-minbase.tar.zst"

CORES=2
MEMORY=4096
SWAP=0
ROOTFS_SIZE=8

PREP_IP="10.77.250.20/16"
PREP_GW="10.77.0.1"

pct create "$VMID" "$BASE_TEMPLATE" \
  --hostname "$TEMPLATE_NAME" \
  --ostype debian \
  --unprivileged 1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${STORAGE}:${ROOTFS_SIZE},mountoptions=noatime" \
  --net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=${PREP_IP},gw=${PREP_GW},ip6=manual,type=veth" \
  --console 0 \
  --tty 0 \
  --start 1

SETUP_SCRIPT="$(mktemp "/tmp/apexium-minecraft-java-setup.XXXXXX.sh")"

cat > "$SETUP_SCRIPT" <<'APEXIUM_CONTAINER_SETUP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get -o Acquire::Languages=none update

mkdir -p /usr/share/man/man1

apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  jq \
  openssh-server \
  openjdk-25-jdk-headless

useradd \
  --system \
  --user-group \
  --home-dir /opt/gameserver \
  --create-home \
  --shell /usr/sbin/nologin \
  gameserver

chown root:root /opt

chmod 0755 /opt

mkdir -p /opt/gameserver/data

chown -R gameserver:gameserver \
  /opt/gameserver

chmod 0750 /opt/gameserver

cat > /etc/ssh/sshd_config.d/90-apexium.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
Match User gameserver
    PasswordAuthentication yes
    PubkeyAuthentication no
    ChrootDirectory /opt
    ForceCommand internal-sftp -d /gameserver
    DisableForwarding yes
Match all
EOF
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/hostkeys.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/ssh-keygen -A
EOF
systemctl disable ssh.service
systemctl enable ssh.socket

# Keine virtuelle Login-Konsole im Kunden-LXC. pct enter/SFTP funktionieren
# weiterhin; dadurch startet kein unnoetiger agetty-Prozess.
systemctl mask getty@.service serial-getty@.service console-getty.service container-getty@.service 2>/dev/null || true

# LXC teilt die Host-Uhr; ein eigener NTP-Dienst im Container ist unnoetig.
systemctl mask systemd-timesyncd.service 2>/dev/null || true

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-apexium.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
RuntimeMaxFileSize=4M
RateLimitIntervalSec=30s
RateLimitBurst=2000
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
EOF

MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
MANIFEST="$(curl -fsSL "$MANIFEST_URL")"
MC_VERSION="$(printf '%s' "$MANIFEST" | jq -r '.latest.release')"
MC_VERSION_URL="$(printf '%s' "$MANIFEST" | jq -r --arg v "$MC_VERSION" '.versions[] | select(.id == $v) | .url')"
MC_SERVER_URL="$(curl -fsSL "$MC_VERSION_URL" | jq -r '.downloads.server.url')"
curl -fL "$MC_SERVER_URL" -o /opt/gameserver/server.jar
chown gameserver:gameserver /opt/gameserver/server.jar

cat > /usr/local/bin/apexium-console-command <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > /run/apexium-gameserver/console
EOF

chmod 0755 \
  /usr/local/bin/apexium-console-command

cat > /usr/local/bin/apexium-start-game <<'EOF'
#!/usr/bin/env bash
cd /opt/gameserver
printf 'eula=true\n' > eula.txt
touch server.properties
set_property() {
  key="$1"; value="$2"
  if grep -q "^${key}=" server.properties; then
    safe=$(printf '%s' "$value" | sed 's/[\&|]/\\&/g')
    sed -i "s|^${key}=.*|${key}=${safe}|" server.properties
  else
    printf '%s=%s\n' "$key" "$value" >> server.properties
  fi
}
set_property server-port "$GAME_PORT"
set_property max-players "$MAX_PLAYERS"
set_property motd "$SERVER_NAME"
F=/run/apexium-gameserver/console
rm -f "$F"; mkfifo -m 600 "$F"; exec 3<>"$F"
exec java -Xms512M -Xmx"$(( $MEMORY_MB - 512 ))M" -jar server.jar nogui <&3
EOF

chmod 0755 \
  /usr/local/bin/apexium-start-game

cat > /etc/systemd/system/apexium-gameserver.service <<'EOF'
[Service]
User=gameserver
EnvironmentFile=/etc/apexium-gameserver.env
StandardOutput=journal
StandardError=journal
RuntimeDirectory=apexium-gameserver
ExecStart=/usr/local/bin/apexium-start-game
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitCORE=0
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF


# Debug-Symbole werden fuer den produktiven Gameserver nicht benoetigt.
find /opt/gameserver -type f -iname '*.pdb' -delete

# Update-Abhaengigkeiten bleiben fuer Versionswechsel und Neuinstallationen im Kundencontainer erhalten.

# Nur der SSH-Server und ssh-keygen bleiben; Client-Werkzeuge werden nicht gebraucht.
rm -f \
  /usr/bin/ssh \
  /usr/bin/scp \
  /usr/bin/sftp \
  /usr/bin/slogin \
  /usr/bin/ssh-add \
  /usr/bin/ssh-agent \
  /usr/bin/ssh-copy-id \
  /usr/bin/ssh-keyscan \
  /usr/bin/ssh-argv0 \
  /usr/lib/openssh/ssh-keysign \
  /usr/lib/openssh/ssh-pkcs11-helper \
  /usr/lib/openssh/ssh-sk-helper \
  /usr/lib/openssh/sftp-server \
  /usr/lib/systemd/user/ssh-agent.socket \
  /usr/lib/systemd/user/sockets.target.wants/ssh-agent.socket
rm -rf /etc/ssh/ssh_config /etc/ssh/ssh_config.d

# Paketmanager-/Trim-Dienste existieren in der Appliance nicht mehr.
rm -f \
  /usr/lib/systemd/system/apt-daily.service \
  /usr/lib/systemd/system/apt-daily.timer \
  /usr/lib/systemd/system/apt-daily-upgrade.service \
  /usr/lib/systemd/system/apt-daily-upgrade.timer \
  /usr/lib/systemd/system/dpkg-db-backup.service \
  /usr/lib/systemd/system/dpkg-db-backup.timer \
  /usr/lib/systemd/system/fstrim.service \
  /usr/lib/systemd/system/fstrim.timer \
  /lib/systemd/system/apt-daily.service \
  /lib/systemd/system/apt-daily.timer \
  /lib/systemd/system/apt-daily-upgrade.service \
  /lib/systemd/system/apt-daily-upgrade.timer \
  /lib/systemd/system/dpkg-db-backup.service \
  /lib/systemd/system/dpkg-db-backup.timer \
  /lib/systemd/system/fstrim.service \
  /lib/systemd/system/fstrim.timer \
  /etc/systemd/system/timers.target.wants/apt-daily.timer \
  /etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer \
  /etc/systemd/system/timers.target.wants/dpkg-db-backup.timer \
  /etc/systemd/system/timers.target.wants/fstrim.timer \
  /etc/cron.daily/apt-compat \
  /etc/cron.daily/dpkg \
  /etc/logrotate.d/apt \
  /etc/logrotate.d/dpkg \
  /etc/logrotate.d/alternatives \
  /usr/libexec/dpkg/dpkg-db-backup

# Debconf und Archiv-Keyrings werden nach dem Build nicht mehr ben tigt.
rm -f /usr/bin/debconf* /usr/sbin/dpkg-reconfigure /etc/debconf.conf
rm -rf /usr/share/perl5/Debconf /usr/share/keyrings

# Kein interaktiver Login/MOTD in den Kunden-Appliances.
rm -rf /etc/update-motd.d
rm -f /etc/motd /etc/issue /etc/issue.net
cat > /usr/local/bin/apexium-install-version <<'APEXIUM_VERSION_INSTALLER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="${1:-latest}"
WIPE="${2:-0}"
ROOT=/opt/gameserver
USER_AGENT='Apexium-Hosting/1.0 (https://apexium.cloud)'
if [ "$WIPE" = "1" ]; then
    find "$ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
mkdir -p "$ROOT"

fetch_mojang_manifest() {
    curl -fsSL 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
}

install_vanilla() {
    local requested="$1" manifest resolved version_url server_url
    manifest="$(fetch_mojang_manifest)"
    if [ "$requested" = "latest" ]; then
        resolved="$(printf '%s' "$manifest" | jq -r '.latest.release')"
    else
        resolved="$requested"
    fi
    version_url="$(printf '%s' "$manifest" | jq -r --arg v "$resolved" '.versions[] | select(.id == $v) | .url' | sed -n '1p')"
    [ -n "$version_url" ] && [ "$version_url" != "null" ] || { echo "Minecraft-Version nicht gefunden: $resolved" >&2; exit 2; }
    server_url="$(curl -fsSL "$version_url" | jq -r '.downloads.server.url // empty')"
    [ -n "$server_url" ] || { echo "Für Minecraft $resolved ist kein offizielles Server-JAR verfügbar" >&2; exit 2; }
    curl -fL "$server_url" -o "$ROOT/server.jar"
    RESOLVED_VERSION="$resolved"
}

install_papermc_project() {
    local project="$1" requested="$2" payload resolved builds url
    payload="$(curl -fsSL -H "User-Agent: $USER_AGENT" "https://fill.papermc.io/v3/projects/$project")"
    if [ "$requested" = "latest" ]; then
        resolved="$(printf '%s' "$payload" | jq -r '.versions | to_entries[0].value[0] // empty')"
    else
        resolved="$requested"
    fi
    [ -n "$resolved" ] || { echo "Keine $project-Version gefunden" >&2; exit 2; }
    builds="$(curl -fsSL -H "User-Agent: $USER_AGENT" "https://fill.papermc.io/v3/projects/$project/versions/$resolved/builds")"
    url="$(printf '%s' "$builds" | jq -r '(first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // first(.[].downloads."server:default".url) // empty)')"
    [ -n "$url" ] || { echo "Kein stabiler $project-Build für Minecraft $resolved verfügbar" >&2; exit 2; }
    curl -fL -H "User-Agent: $USER_AGENT" "$url" -o "$ROOT/server.jar"
    RESOLVED_VERSION="$project:$resolved"
}

install_purpur() {
    local requested="$1" payload resolved
    payload="$(curl -fsSL 'https://api.purpurmc.org/v2/purpur')"
    if [ "$requested" = "latest" ]; then
        resolved="$(printf '%s' "$payload" | jq -r '.versions[-1] // empty')"
    else
        resolved="$requested"
    fi
    [ -n "$resolved" ] || { echo "Keine Purpur-Version gefunden" >&2; exit 2; }
    curl -fL "https://api.purpurmc.org/v2/purpur/$resolved/latest/download" -o "$ROOT/server.jar"
    RESOLVED_VERSION="purpur:$resolved"
}

install_fabric() {
    local requested="$1" resolved loader installer
    if [ "$requested" = "latest" ]; then
        resolved="$(curl -fsSL 'https://meta.fabricmc.net/v2/versions/game' | jq -r 'first(.[] | select(.stable == true)).version // empty')"
    else
        resolved="$requested"
    fi
    [ -n "$resolved" ] || { echo "Keine Fabric-kompatible Minecraft-Version gefunden" >&2; exit 2; }
    loader="$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/$resolved" | jq -r 'first(.[] | select(.loader.stable == true)).loader.version // .[0].loader.version // empty')"
    installer="$(curl -fsSL 'https://meta.fabricmc.net/v2/versions/installer' | jq -r 'first(.[] | select(.stable == true)).version // .[0].version // empty')"
    [ -n "$loader" ] && [ -n "$installer" ] || { echo "Kein Fabric Loader/Installer für Minecraft $resolved verfügbar" >&2; exit 2; }
    curl -fL "https://meta.fabricmc.net/v2/versions/loader/$resolved/$loader/$installer/server/jar" -o "$ROOT/server.jar"
    RESOLVED_VERSION="fabric:$resolved"
}

install_buildtools() {
    local software="$1" requested="$2" target tmp jar resolved
    target="$requested"
    [ "$target" = "latest" ] || printf '%s' "$target" | grep -Eq '^[0-9]+([.][0-9]+){1,3}$' || { echo "Ungültige BuildTools-Version" >&2; exit 2; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    chmod 0755 "$tmp"
    mkdir -p "$tmp/build" "$tmp/home"
    chown -R gameserver:gameserver "$tmp/build" "$tmp/home"
    curl -fL 'https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar' -o "$tmp/BuildTools.jar"
    chown gameserver:gameserver "$tmp/BuildTools.jar"
    runuser -u gameserver -- env HOME="$tmp/home" sh -c 'cd "$1" && exec java -jar "$2" --rev "$3"' sh "$tmp/build" "$tmp/BuildTools.jar" "$target"
    jar="$(find "$tmp/build" -maxdepth 1 -type f -name "${software}-*.jar" -print | sort -V | tail -n1)"
    [ -n "$jar" ] || { echo "BuildTools hat kein ${software}-Server-JAR erzeugt" >&2; exit 2; }
    cp "$jar" "$ROOT/server.jar"
    if [ "$target" = "latest" ]; then
        resolved="$(basename "$jar" .jar | sed -E "s/^${software}-//; s/-R.*$//")"
    else
        resolved="$target"
    fi
    [ -n "$resolved" ] || resolved="$target"
    RESOLVED_VERSION="$software:$resolved"
    rm -rf "$tmp"
    trap - RETURN
}

case "$VERSION" in
    latest)
        install_vanilla latest
        ;;
    vanilla:*)
        install_vanilla "${VERSION#vanilla:}"
        ;;
    paper:*)
        install_papermc_project paper "${VERSION#paper:}"
        ;;
    folia:*)
        install_papermc_project folia "${VERSION#folia:}"
        ;;
    purpur:*)
        install_purpur "${VERSION#purpur:}"
        ;;
    fabric:*)
        install_fabric "${VERSION#fabric:}"
        ;;
    spigot:*)
        install_buildtools spigot "${VERSION#spigot:}"
        ;;
    craftbukkit:*)
        install_buildtools craftbukkit "${VERSION#craftbukkit:}"
        ;;
    *)
        # Backwards compatibility: existing Apexium orders stored Vanilla as a
        # plain Minecraft version such as 1.21.4.
        install_vanilla "$VERSION"
        ;;
esac

printf '%s\n' "$RESOLVED_VERSION" > /etc/apexium-gameserver-version
chown -R gameserver:gameserver "$ROOT"
APEXIUM_VERSION_INSTALLER_EOF
chmod 0755 /usr/local/bin/apexium-install-version
printf '%s\n' 'template' > /etc/apexium-gameserver-version

rm -f /etc/apexium-gameserver.env
rm -rf /root
mkdir -m 0700 /root
rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed /var/lib/dhcp/dhclient*.leases /var/lib/systemd/network/*.lease
truncate -s 0 /etc/machine-id
rm -rf /etc/apt /var/lib/apt /var/cache/apt /usr/lib/apt /var/lib/dpkg /etc/dpkg /usr/lib/dpkg /usr/share/dpkg /var/cache/debconf /var/lib/debconf /usr/share/debconf
rm -f /usr/bin/apt /usr/bin/apt-* /usr/bin/apt-get /usr/bin/apt-cache /usr/bin/apt-config /usr/bin/dpkg /usr/bin/dpkg-* /usr/bin/dpkg-query /usr/bin/dpkg-trigger
rm -f /usr/lib/x86_64-linux-gnu/libapt-pkg.so* /usr/lib/x86_64-linux-gnu/libapt-private.so*
rm -rf /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale /usr/share/lintian /usr/share/bash-completion
find /var/log -mindepth 1 -delete
find /tmp /var/tmp -xdev -mindepth 1 -delete
passwd -l root
APEXIUM_CONTAINER_SETUP_EOF

chmod 0700 "$SETUP_SCRIPT"

pct push "$VMID" "$SETUP_SCRIPT" /root/apexium-template-setup.sh --perms 0700
rm -f "$SETUP_SCRIPT"
pct exec "$VMID" -- bash /root/apexium-template-setup.sh
pct exec "$VMID" -- rm -f /root/apexium-template-setup.sh

pct fstrim "$VMID" --ignore-mountpoints 1

pct shutdown "$VMID" --timeout 60 --forceStop 1

pct set "$VMID" --delete net0
NODE="$(hostname -s)"
pvesh create \
  "/nodes/${NODE}/lxc/${VMID}/firewall/ipset" \
  --name "ipfilter-net0"
pvesh set \
  "/nodes/${NODE}/lxc/${VMID}/firewall/options" \
  --enable 1 \
  --ipfilter 1 \
  --policy_in ACCEPT \
  --policy_out ACCEPT
pct template "$VMID"
