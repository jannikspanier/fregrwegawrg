#!/usr/bin/env bash
set -Eeuo pipefail

VMID=9104
TEMPLATE_NAME="ark"
STORAGE="local"
BRIDGE="vmbr3"
BASE_TEMPLATE="${STORAGE}:vztmpl/apexium-debian-12-minbase.tar.zst"

CORES=4
MEMORY=10240
SWAP=0
ROOTFS_SIZE=40

PREP_IP="10.77.250.24/16"
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

SETUP_SCRIPT="$(mktemp "/tmp/apexium-ark-setup.XXXXXX.sh")"

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
  libatomic1

useradd \
  --system \
  --user-group \
  --home-dir /opt/gameserver \
  --create-home \
  --shell /usr/sbin/nologin \
  gameserver

chown root:root /opt

chmod 0755 /opt

mkdir -p /opt/gameserver/data /tmp/steamcmd /tmp/steam-home

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
run_ark_steamcmd() {
  rm -rf /tmp/steam-home/Steam/appcache /tmp/steamcmd/appcache
  runuser -u gameserver -- env HOME=/tmp/steam-home /tmp/steamcmd/steamcmd.sh "$@"
}

# SteamCMD kann fuer Dedicated-Server-Apps kurzfristig "Missing configuration"
# liefern. Die Wiederholungen laufen ausschliesslich beim Template-Build.
if ! run_ark_steamcmd \
    +force_install_dir /opt/gameserver \
    +login anonymous \
    +app_update 376030 validate \
    +quit || [ ! -x /opt/gameserver/ShooterGame/Binaries/Linux/ShooterGameServer ]; then
  sleep 5
  if ! run_ark_steamcmd \
      +@sSteamCmdForcePlatformType linux \
      +force_install_dir /opt/gameserver \
      +login anonymous \
      +app_info_update 1 \
      +app_update 376030 validate \
      +quit || [ ! -x /opt/gameserver/ShooterGame/Binaries/Linux/ShooterGameServer ]; then
    sleep 10
    run_ark_steamcmd \
      +@sSteamCmdForcePlatformType linux \
      +force_install_dir /opt/gameserver \
      +login anonymous \
      +app_info_update 1 \
      +app_update 376030 -beta public validate \
      +quit
  fi
fi
test -x /opt/gameserver/ShooterGame/Binaries/Linux/ShooterGameServer || { echo "SteamCMD hat App 376030 nicht vollst ndig installiert: /opt/gameserver/ShooterGame/Binaries/Linux/ShooterGameServer fehlt." >&2; exit 1; }

# Der Linux-Server benoetigt keine mitgelieferten Win32/Win64-Binaerbaeume.
# Das spart insbesondere die grossen Windows-PDBs/Binaries im Master-Template.
find /opt/gameserver/ShooterGame/Binaries /opt/gameserver/Engine/Binaries   -type d \( -name Win32 -o -name Win64 \) -prune -exec rm -rf {} + 2>/dev/null || true
mkdir -p /opt/gameserver/.steam/sdk64
cp /tmp/steamcmd/linux64/steamclient.so /opt/gameserver/.steam/sdk64/steamclient.so
chown -R gameserver:gameserver /opt/gameserver
mkdir -p /usr/local/lib/apexium

cat > /usr/local/lib/apexium/source_rcon.pl <<'PERL'
#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;

my ($port_key, $pass_key, @cmd) = @ARGV;
my %env;
open my $fh, '<', '/etc/apexium-gameserver.env' or die "env unavailable\n";
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /^([A-Z][A-Z0-9_]*)=(.*)$/;
    my ($key, $value) = ($1, $2);
    if ($value =~ /^"(.*)"$/s) {
        $value = $1;
        $value =~ s/\\(.)/$1/gs;
    }
    $env{$key} = $value;
}
close $fh;
my $port = $env{$port_key};
my $pass = $env{$pass_key};
die "RCON configuration unavailable\n" unless defined $port && defined $pass && @cmd;
my $s = IO::Socket::INET->new(PeerAddr=>'127.0.0.1', PeerPort=>$port, Proto=>'tcp', Timeout=>5)
    or die "RCON connection failed\n";
sub packet { my($i,$t,$x)=@_; my $b=pack('l<l<',$i,$t).$x."\0\0"; return pack('l<',length $b).$b }
sub readn { my($n)=@_; my $b=''; while(length($b)<$n){ my $r=sysread($s,my $x,$n-length($b)); die "RCON read failed\n" unless $r; $b.=$x } return $b }
sub receive { my $n=unpack('l<',readn(4)); my $b=readn($n); my($i,$t)=unpack('l<l<',substr($b,0,8)); return($i,$t,substr($b,8,-2)) }
print $s packet(1,3,$pass);
while (1) { my($i,$t)=receive(); die "RCON authentication failed\n" if $i == -1; last if $t == 2 }
print $s packet(2,2,join(' ',@cmd));
my(undef,undef,$out)=receive(); print $out;
PERL

chmod 0755 /usr/local/lib/apexium/source_rcon.pl

cat > /usr/local/bin/apexium-console-command <<'EOF'
#!/usr/bin/env bash
exec /usr/local/lib/apexium/source_rcon.pl RCON_PORT ARK_ADMIN_PASSWORD "$@"
EOF

chmod 0755 /usr/local/bin/apexium-console-command

cat > /usr/local/bin/apexium-start-game <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=/opt/gameserver

# ARK/UE4 can keep ShooterGame.log buffered for a very long time when running
# headless under systemd. Force the engine to emit its full log directly to
# stdout so journald and the Apexium web console receive it live.
cd "$ROOT/ShooterGame/Binaries/Linux"
exec ./ShooterGameServer "TheIsland?listen?SessionName=$SERVER_NAME?Port=${GAME_PORT}?QueryPort=${QUERY_PORT}?MaxPlayers=$MAX_PLAYERS?RCONEnabled=True?RCONPort=$RCON_PORT?ServerAdminPassword=${ARK_ADMIN_PASSWORD}" -server -log -FORCELOGFLUSH

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
APP_ARGS=( +@sSteamCmdForcePlatformType linux )
if [ "$VERSION" = "latest" ]; then
    :
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +force_install_dir "$ROOT" +login anonymous +app_update 376030 validate +quit
elif [[ "$VERSION" == branch:* ]]; then
    BRANCH="${VERSION#branch:}"; printf '%s' "$BRANCH" | grep -Eq '^[A-Za-z0-9._+-]{1,64}$' || { echo "Ungültiger Steam-Branch" >&2; exit 2; }
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +force_install_dir "$ROOT" +login anonymous +app_update 376030 -beta "$BRANCH" validate +quit
elif [[ "$VERSION" == manifest:*:* ]]; then
    SPEC="${VERSION#manifest:}"; DEPOT="${SPEC%%:*}"; MANIFEST="${SPEC#*:}"
    printf '%s' "$DEPOT" | grep -Eq '^[0-9]+$' && printf '%s' "$MANIFEST" | grep -Eq '^[0-9]+$' || { echo "Ungültiger Steam-Manifest-Spec" >&2; exit 2; }
    runuser -u gameserver -- env HOME="$TMP/home" "$TMP/steamcmd/steamcmd.sh" "${APP_ARGS[@]}" +login anonymous +download_depot 376030 "$DEPOT" "$MANIFEST" +quit
    CONTENT="$TMP/home/Steam/steamapps/content/app_376030/depot_$DEPOT"; [ -d "$CONTENT" ] || { echo "Steam-Manifest-Inhalt fehlt" >&2; exit 2; }; cp -a "$CONTENT/." "$ROOT/"
else echo "Ungültige Steam-Version: $VERSION" >&2; exit 2; fi

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