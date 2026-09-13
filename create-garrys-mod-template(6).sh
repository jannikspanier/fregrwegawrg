#!/usr/bin/env bash
set -Eeuo pipefail

VMID=9107
TEMPLATE_NAME="garrys-mod"
STORAGE="local"
BRIDGE="vmbr3"
BASE_TEMPLATE="${STORAGE}:vztmpl/apexium-debian-12-minbase.tar.zst"

CORES=2
MEMORY=4096
SWAP=0
ROOTFS_SIZE=30

PREP_IP="10.77.250.27/16"
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

SETUP_SCRIPT="$(mktemp "/tmp/apexium-garrys-mod-setup.XXXXXX.sh")"

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
  lib32stdc++6

useradd \
  --system \
  --user-group \
  --home-dir /opt/gameserver \
  --create-home \
  --shell /usr/sbin/nologin \
  gameserver

chown root:root /opt

chmod 0755 /opt

mkdir -p /opt/gameserver/data /opt/steamcmd /opt/gameserver/.steam

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

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-apexium.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
RuntimeMaxFileSize=4M
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF

curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /opt/steamcmd
chown -R gameserver:gameserver /opt/gameserver /opt/steamcmd
runuser -u gameserver -- env HOME=/opt/gameserver /opt/steamcmd/steamcmd.sh \
  +force_install_dir /opt/gameserver \
  +login anonymous \
  +app_update 4020 validate \
  +quit
test -x /opt/gameserver/srcds_run || { echo "SteamCMD hat App 4020 nicht vollst ndig installiert: /opt/gameserver/srcds_run fehlt." >&2; exit 1; }
mkdir -p /opt/gameserver/.steam/sdk32
cp /opt/steamcmd/linux32/steamclient.so /opt/gameserver/.steam/sdk32/steamclient.so
rm -rf /opt/steamcmd
chown -R gameserver:gameserver /opt/gameserver
cat > /usr/local/bin/apexium-console-command <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > /run/apexium-gameserver/console
EOF

chmod 0755 /usr/local/bin/apexium-console-command

cat > /usr/local/bin/apexium-start-game <<'EOF'
#!/usr/bin/env bash
cd /opt/gameserver
F=/run/apexium-gameserver/console
rm -f "$F"; mkfifo -m 600 "$F"; exec 3<>"$F"
A=(-game garrysmod -console +port "$GAME_PORT" +maxplayers "$MAX_PLAYERS" +map "${GMOD_MAP:-gm_construct}" +hostname "$SERVER_NAME")
if [ -n "${STEAM_GSLT:-}" ]; then A+=(+sv_setsteamaccount "$STEAM_GSLT"); fi
exec ./srcds_run "${A[@]}" <&3
EOF

chmod 0755 /usr/local/bin/apexium-start-game

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


apt-get purge -y --autoremove curl

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
