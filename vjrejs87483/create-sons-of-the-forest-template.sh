#!/usr/bin/env bash
set -Eeuo pipefail

VMID=9109
TEMPLATE_NAME="sons-of-the-forest"
STORAGE="local"
BRIDGE="vmbr3"
BASE_TEMPLATE="${STORAGE}:vztmpl/apexium-debian-12-minbase.tar.zst"

CORES=4
MEMORY=10240
SWAP=0
ROOTFS_SIZE=12

PREP_IP="10.77.250.29/16"
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

SETUP_SCRIPT="$(mktemp "/tmp/apexium-sons-of-the-forest-setup.XXXXXX.sh")"

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

curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /tmp/steamcmd
chown -R gameserver:gameserver /opt/gameserver /tmp/steamcmd /tmp/steam-home
run_sotf_steamcmd() {
  rm -rf /tmp/steam-home/Steam/appcache /tmp/steamcmd/appcache
  runuser -u gameserver -- env HOME=/tmp/steam-home /tmp/steamcmd/steamcmd.sh "$@"
}

# SteamCMD kann fuer App 2465200 kurzfristig "Missing configuration" liefern.
# Die Wiederholungen laufen ausschliesslich beim Template-Build.
if ! run_sotf_steamcmd \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir /opt/gameserver \
    +login anonymous \
    +app_update 2465200 validate \
    +quit || [ ! -f /opt/gameserver/SonsOfTheForestDS.exe ]; then
  sleep 5
  if ! run_sotf_steamcmd \
      +@sSteamCmdForcePlatformType windows \
      +force_install_dir /opt/gameserver \
      +login anonymous \
      +app_info_update 1 \
      +app_update 2465200 validate \
      +quit || [ ! -f /opt/gameserver/SonsOfTheForestDS.exe ]; then
    sleep 10
    run_sotf_steamcmd \
      +@sSteamCmdForcePlatformType windows \
      +force_install_dir /opt/gameserver \
      +login anonymous \
      +app_info_update 1 \
      +app_update 2465200 -beta public validate \
      +quit
  fi
fi

test -f /opt/gameserver/SonsOfTheForestDS.exe || { echo "SteamCMD hat App 2465200 nicht vollstaendig installiert: /opt/gameserver/SonsOfTheForestDS.exe fehlt." >&2; exit 1; }
runuser -u gameserver -- env HOME=/opt/gameserver WINEPREFIX=/opt/gameserver/data/wine WINEARCH=win64 xvfb-run -a /usr/lib/wine/wine64 wineboot

# Der offizielle Windows-Launcher legt fuer den Dedicated Server diese App-ID an.
# Unter Wine tun wir das bereits im Template, damit der erste Kundenstart keinen
# zusaetzlichen Neustart wegen einer fehlenden steam_appid.txt verlangt.
printf '1326470\n' > /opt/gameserver/steam_appid.txt
chown gameserver:gameserver /opt/gameserver/steam_appid.txt

mkdir -p /usr/local/lib/apexium
cat > /usr/local/lib/apexium/sotf-console-filter.awk <<'AWK'
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

    if (line ~ /^\[UnityMemory\] Configuration Parameters/) { unitymem=1; next }
    if (unitymem && line ~ /^[[:space:]]+"memorysetup-/) next
    if (unitymem) unitymem=0

    if (line ~ /^Texture2DArray is not supported on this platform\/GPU$/) { texture_stack=1; next }
    if (texture_stack && line ~ /^HeadlessLoggingManager: Hooking$/) { texture_stack=0; next }
    if (texture_stack) next

    if (line ~ /^Unloading [0-9]+ /) next
    if (line ~ /^UnloadTime:/) next
    if (line ~ /^Total: .*\(FindLiveObjects:/) next
    if (line ~ /^Couldn.t create a Convex Mesh from source mesh /) next
    if (line ~ /^No mesh data available for mesh /) next
    if (line ~ /^DontDestroyOnLoad only works /) next
    if (line ~ /^This custom render path shader needs to have at least 1 passes\.$/) next
    if (line ~ /^Could not find material Hidden\/Video/) next
    if (line ~ /^Could not find video decode shader pass /) next
    if (line ~ /^WARNING: Shader Unsupported:/) next
    if (line ~ /^WARNING: Shader Did you use #pragma /) next
    if (line ~ /^WARNING: Shader If subshaders removal was intentional/) next
    if (line ~ /^ERROR: Shader /) next
    if (line ~ /^There is no texture data available to upload\.$/) next
    if (line ~ /^Texture2DArray is not supported on this platform\/GPU$/) next
    if (line ~ /^Microsoft Media Foundation video decoding to texture disabled:/) next
    if (line ~ /^ALSA lib /) next
    if (line ~ /^[0-9a-f]+:err:vulkan:wine_vk_init /) next
    if (line ~ /^[0-9a-f]+:err:combase:RoGetActivationFactory /) next
    if (line ~ /^[0-9a-f]+:err:winediag:ntlm_check_version /) next
    if (line ~ /^[0-9a-f]+:err:ntlm:ntlm_LsaApInitializePackage /) next

    if (line ~ /^#DSL Loading progress: [0-9]+/) {
        progress = line
        sub(/^#DSL Loading progress: /, "", progress)
        sub(/[^0-9].*$/, "", progress)
        if (progress == last_progress) next
        last_progress = progress
    }
    emit(line)
}
AWK

cat > /usr/local/bin/apexium-start-game <<'EOF'
#!/usr/bin/env bash
cd /opt/gameserver
DATA=/opt/gameserver/data/sotf
CFG="$DATA/dedicatedserver.cfg"
OWNERS="$DATA/ownerswhitelist.txt"
mkdir -p "$DATA"
# Ein leeres ownerswhitelist.txt ist gueltig. Ohne die Datei erzeugt SOTF sie
# beim ersten Start selbst und verlangt danach zwingend einen Neustart.
if [ ! -e "$OWNERS" ]; then : > "$OWNERS"; fi
export SOTF_PASSWORD="${SOTF_PASSWORD:-}"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<CFGJSON
{
  "IpAddress": "0.0.0.0",
  "GamePort": ${GAME_PORT},
  "QueryPort": ${QUERY_PORT},
  "BlobSyncPort": ${BLOB_SYNC_PORT},
  "ServerName": "Apexium Sons of the Forest",
  "MaxPlayers": ${MAX_PLAYERS},
  "Password": "",
  "LanOnly": false,
  "SaveSlot": 1,
  "SaveMode": "Continue",
  "GameMode": "Normal",
  "SaveInterval": 600,
  "IdleDayCycleSpeed": 0.0,
  "IdleTargetFramerate": 5,
  "ActiveTargetFramerate": 60,
  "LogFilesEnabled": false,
  "TimestampLogFilenames": false,
  "TimestampLogEntries": false,
  "SkipNetworkAccessibilityTest": true
}
CFGJSON
fi
perl -0pi -e '
sub j { my $v=shift // q{}; $v =~ s/\\/\\\\/g; $v =~ s/"/\\"/g; return $v }
my $name=$ENV{SERVER_NAME}//q{}; my $players=$ENV{MAX_PLAYERS}//8; my $pass=$ENV{SOTF_PASSWORD}//q{};
my $game=$ENV{GAME_PORT}; my $query=$ENV{QUERY_PORT}; my $blob=$ENV{BLOB_SYNC_PORT};
s/"GamePort"\s*:\s*\d+/"GamePort": $game/g;
s/"QueryPort"\s*:\s*\d+/"QueryPort": $query/g;
s/"BlobSyncPort"\s*:\s*\d+/"BlobSyncPort": $blob/g;
s/"MaxPlayers"\s*:\s*\d+/"MaxPlayers": $players/g;
s/"ServerName"\s*:\s*"[^"]*"/qq{"ServerName": "}.j($name).qq{"}/ge;
s/"Password"\s*:\s*"[^"]*"/qq{"Password": "}.j($pass).qq{"}/ge;
' "$CFG"
export WINEPREFIX=/opt/gameserver/data/wine WINEARCH=win64
exec xvfb-run --auto-servernum --server-args="-screen 0 640x480x24" /usr/lib/wine/wine64 SonsOfTheForestDS.exe -userdatapath ./data/sotf -batchmode -nographics > >(awk -f /usr/local/lib/apexium/sotf-console-filter.awk) 2>&1
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
if [ "$WIPE" = "1" ]; then
    find "$ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
mkdir -p "$ROOT"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/steamcmd" "$TMP/home"
curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C "$TMP/steamcmd"
chown -R gameserver:gameserver "$ROOT" "$TMP/steamcmd" "$TMP/home"
APP_ARGS=( +@sSteamCmdForcePlatformType windows )
if [ "$VERSION" = "latest" ]; then
    :
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +force_install_dir "$ROOT" +login anonymous +app_update 2465200 validate +quit
elif [[ "$VERSION" == branch:* ]]; then
    BRANCH="${VERSION#branch:}"; printf '%s' "$BRANCH" | grep -Eq '^[A-Za-z0-9._+-]{1,64}$' || { echo "Ungültiger Steam-Branch" >&2; exit 2; }
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +force_install_dir "$ROOT" +login anonymous +app_update 2465200 -beta "$BRANCH" validate +quit
elif [[ "$VERSION" == manifest:*:* ]]; then
    SPEC="${VERSION#manifest:}"; DEPOT="${SPEC%%:*}"; MANIFEST="${SPEC#*:}"
    printf '%s' "$DEPOT" | grep -Eq '^[0-9]+$' && printf '%s' "$MANIFEST" | grep -Eq '^[0-9]+$' || { echo "Ungültiger Steam-Manifest-Spec" >&2; exit 2; }
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +login anonymous +download_depot 2465200 "$DEPOT" "$MANIFEST" +quit
    CONTENT="$TMP/home/Steam/steamapps/content/app_2465200/depot_$DEPOT"; [ -d "$CONTENT" ] || { echo "Steam-Manifest-Inhalt fehlt" >&2; exit 2; }; cp -a "$CONTENT/." "$ROOT/"
else echo "Ungültige Steam-Version: $VERSION" >&2; exit 2; fi
mkdir -p "$ROOT/data/wine"; chown -R gameserver:gameserver "$ROOT"; runuser -u gameserver -- env HOME="$ROOT" WINEPREFIX="$ROOT/data/wine" WINEARCH=win64 xvfb-run -a /usr/lib/wine/wine64 wineboot
printf '%s
' "$VERSION" > /etc/apexium-gameserver-version; chown -R gameserver:gameserver "$ROOT"
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
pvesh create "/nodes/${NODE}/lxc/${VMID}/firewall/ipset" \
  --name "ipfilter-net0"
pvesh set "/nodes/${NODE}/lxc/${VMID}/firewall/options" \
  --enable 1 \
  --ipfilter 1 \
  --policy_in ACCEPT \
  --policy_out ACCEPT
pct template "$VMID"
