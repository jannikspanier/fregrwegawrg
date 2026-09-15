#!/usr/bin/env bash
set -Eeuo pipefail

VMID=9110
TEMPLATE_NAME="the-forest"
STORAGE="local"
BRIDGE="vmbr3"
BASE_TEMPLATE="${STORAGE}:vztmpl/apexium-debian-12-minbase.tar.zst"

CORES=3
MEMORY=6144
SWAP=0
ROOTFS_SIZE=8

PREP_IP="10.77.250.30/16"
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

SETUP_SCRIPT="$(mktemp "/tmp/apexium-the-forest-setup.XXXXXX.sh")"

cat > "$SETUP_SCRIPT" <<'APEXIUM_CONTAINER_SETUP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get -o Acquire::Languages=none update

apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  openssh-server \
  lib32gcc-s1 \
  lib32stdc++6 \
  wine64 \
  xvfb \
  xauth

useradd \
  --system \
  --user-group \
  --home-dir /opt/gameserver \
  --create-home \
  --shell /usr/sbin/nologin \
  gameserver

chown root:root /opt

chmod 0755 /opt

mkdir -p \
  /opt/gameserver/data \
  /opt/gameserver/data/wine \
  /tmp/steamcmd \
  /tmp/steam-home

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

curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /tmp/steamcmd
chown -R gameserver:gameserver /opt/gameserver /tmp/steamcmd /tmp/steam-home
runuser -u gameserver -- env HOME=/tmp/steam-home /tmp/steamcmd/steamcmd.sh \
  +@sSteamCmdForcePlatformType windows \
  +force_install_dir /opt/gameserver \
  +login anonymous \
  +app_info_update 1 \
  +app_update 556450 validate \
  +quit

test -f /opt/gameserver/TheForestDedicatedServer.exe || { echo "SteamCMD hat App 556450 nicht vollstaendig installiert: /opt/gameserver/TheForestDedicatedServer.exe fehlt." >&2; exit 1; }

runuser -u gameserver -- env HOME=/opt/gameserver WINEPREFIX=/opt/gameserver/data/wine WINEARCH=win64 xvfb-run -a /usr/lib/wine/wine64 wineboot

mkdir -p /usr/local/lib/apexium
cat > /usr/local/lib/apexium/the-forest-console-filter.awk <<'AWK'
function emit(line) {
    if (line == last) return
    print line
    fflush()
    last = line
}
{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^[[:space:]]*$/) next
    if (line ~ /^Platform assembly: /) next
    if (line ~ /^Loading Z:\\/ && line ~ / into Unity Child Domain$/) next
    if (line ~ /^OnLevelWasLoaded was found on /) next
    if (line ~ /^This message has been deprecated /) next
    if (line ~ /^Add a delegate to SceneManager\.sceneLoaded /) next
    if (line ~ /^[[:space:]]*\(Filename:[[:space:]]+Line:/) next
    if (line ~ /^Unloading [0-9]+ /) next
    if (line ~ /^UnloadTime:/) next
    if (line ~ /^Total: .*\(FindLiveObjects:/) next
    if (line ~ /^Fallback handler could not load library .*\/Mono\//) next
    if (line ~ /^[0-9a-f]+:err:winediag:ntlm_check_version /) next
    if (line ~ /^[0-9a-f]+:err:ntlm:ntlm_LsaApInitializePackage /) next
    if (line ~ /^Warning: VR SWITCHER /) next
    if (line ~ /^VR SWITCHER /) next
    if (line ~ /^WARNING: Shader Unsupported: /) next
    if (line ~ /^NullReferenceException: Object reference not set to an instance of an object$/) next
    if (line ~ /^Exception: NullReferenceException:/) next
    if (line ~ /^TheForest\.Utils\.Input\.GetAxis /) next
    if (line ~ /^UICamera\./) next
    if (line ~ /^[[:space:]]+at (TheForest\.Utils\.Input|UICamera)\./) next
    if (line ~ /^Error: RenderTexture\.Create failed:/) next
    if (line ~ /^RenderTexture\.Create failed:/) next
    if (line ~ /^The referenced script on this Behaviour /) next

    sub(/^Log: /, "", line)
    emit(line)
}
AWK

cat > /usr/local/bin/apexium-start-game <<'EOF'
#!/usr/bin/env bash
cd /opt/gameserver
CFG=data/the-forest-server.cfg
touch "$CFG"
set_property() {
  key="$1"; value="$2"
  if grep -q "^${key} " "$CFG"; then
    safe=$(printf '%s' "$value" | sed 's/[\&|]/\\&/g')
    sed -i "s|^${key} .*|${key} ${safe}|" "$CFG"
  else
    printf '%s %s\n' "$key" "$value" >> "$CFG"
  fi
}
SERVER_IP="$(ip -4 -o addr show dev eth0 scope global | sed -n 's/.* inet \([^/]*\)\/.*/\1/p' | head -n1)"
if [ -z "$SERVER_IP" ]; then
  echo "Keine IPv4-Adresse auf eth0 gefunden." >&2
  exit 1
fi
set_property serverIP "$SERVER_IP"
set_property serverSteamPort "$STEAM_PORT"
set_property serverGamePort "$GAME_PORT"
set_property serverQueryPort "$QUERY_PORT"
set_property serverName "$SERVER_NAME"
set_property serverPlayers "$MAX_PLAYERS"
set_property enableVAC on
set_property serverPassword "${FOREST_PASSWORD:-}"
set_property serverPasswordAdmin "${FOREST_ADMIN_PASSWORD:-}"
set_property serverSteamAccount "${FOREST_STEAM_ACCOUNT:-}"
set_property serverAutoSaveInterval 30
set_property difficulty Normal
set_property initType Continue
set_property slot 1
set_property showLogs on
set_property serverContact ""
set_property veganMode off
set_property vegetarianMode off
set_property resetHolesMode off
set_property treeRegrowMode on
set_property allowBuildingDestruction on
set_property allowEnemiesCreativeMode off
set_property allowCheats off
set_property realisticPlayerDamage off
set_property saveFolderPath ""
set_property targetFpsIdle 5
set_property targetFpsActive 60
export WINEPREFIX=/opt/gameserver/data/wine WINEARCH=win64
exec xvfb-run --auto-servernum --server-args="-screen 0 640x480x24:32" /usr/lib/wine/wine64 TheForestDedicatedServer.exe -batchmode -nographics -nosteamclient -configfilepath /opt/gameserver/data/the-forest-server.cfg > >(awk -f /usr/local/lib/apexium/the-forest-console-filter.awk) 2>&1
EOF

chmod 0755 /usr/local/bin/apexium-start-game

cat > /etc/systemd/system/apexium-gameserver.service <<'EOF'
[Service]
User=gameserver
EnvironmentFile=/etc/apexium-gameserver.env
StandardOutput=journal
StandardError=journal
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

apt-get purge -y --autoremove curl lib32gcc-s1 lib32stdc++6

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
pvesh create "/nodes/${NODE}/lxc/${VMID}/firewall/ipset" \
  --name "ipfilter-net0"
pvesh set "/nodes/${NODE}/lxc/${VMID}/firewall/options" \
  --enable 1 \
  --ipfilter 1 \
  --policy_in ACCEPT \
  --policy_out ACCEPT
pct template "$VMID"
