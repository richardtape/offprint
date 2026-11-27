# The body of the script that sets up one site's pigeonhole on its server. Not run from here: the owner's Mac prints
# the whole script (offprint pigeonhole print-server store ADDRESS), which is a first part made for the site (the six
# values below, and store.js and pull.js themselves, as the two functions write_store_js and write_pull_js), then this
# file as it is. The owner reads it, and runs it as root on the server (Debian or Ubuntu). Offprint never runs it, and
# never touches a server itself.
#
#   PH_SITE     the site's name (site.json's "name"): the instance, its user (ph-NAME) and its folders are named by it
#   PH_PATH     the one path the store takes (site.json's pigeonhole.path)
#   PH_LISTEN   the address and port the store listens on, ADDRESS:PORT: this machine's own address on the private
#               network (site.json's pigeonhole.server and store_port), never every address
#   PH_KEY      the public half of the site's pull key, the only key that may fetch
#   PH_WEB      the web server's address on the private network: the one machine that may reach this one
#   PH_SSH_PORT the port this machine's ssh listens on (site.json's pigeonhole.server_port)
#
# What it makes, and nothing else. Run again, it makes the same (a newer store.js and pull.js replace the old):
#   ph-NAME                             a user for this site's instance alone, with no password
#   /opt/pigeonhole/{store,pull}.js     the store, and the one command the Mac may run (root's; nobody else can change)
#   /etc/pigeonhole/NAME.env            the instance's three settings
#   /var/lib/pigeonhole/NAME/store      what the instance holds (the user's own, mode 700)
#   /var/lib/pigeonhole/NAME/.ssh/authorized_keys   root's, so the instance's user can't change what its key may do:
#                                       the pull key, tied to pull.js for this store, with no shell, forwarding or terminal
#   /etc/systemd/system/pigeonhole@.service, and pigeonhole@NAME.service.d/network.conf
#                                       one unit for every site, an instance a site; shut in (no write but the store,
#                                       no privilege, no network but with the web server), and started
# One server can hold several sites' pigeonholes this way, each with its own user, port, folder and key; only one
# has been set up and tried.
#
# The firewall is the owner's to change, by hand: the script ends by printing the lines, and runs none of them.
set -eu
umask 022

die() { echo "pigeonhole set-up: $1" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "this must run as root."

# Every value again, as lib/config.php held it: this script may have been edited on its way here.
printf '%s' "$PH_SITE" | grep -Eqx '[a-z][a-z0-9-]{0,28}' || die "the site's name isn't one (or is over 29 characters: a user's name can't be longer)."
printf '%s' "$PH_PATH" | grep -Eqx '/[a-z0-9_-]{1,40}' || die "the path isn't a slash and one name."
printf '%s' "$PH_LISTEN" | grep -Eqx '(\[[0-9a-f:]+\]|[0-9.]+):[0-9]{1,5}' || die "the listening address isn't ADDRESS:PORT."
printf '%s' "$PH_KEY" | grep -Eqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}' || die "the pull key isn't an Ed25519 public key."
printf '%s' "$PH_WEB" | grep -Eqx '[0-9a-f:.]{2,45}' || die "the web server's address isn't an address."
printf '%s' "$PH_SSH_PORT" | grep -Eqx '[0-9]{1,5}' || die "the ssh port isn't a number."

USER_NAME="ph-$PH_SITE"
HOME_DIR="/var/lib/pigeonhole/$PH_SITE"
STORE_DIR="$HOME_DIR/store"

# node, from the system's own packages, so that its security updates come with the system's.
if ! command -v node > /dev/null 2>&1; then
  echo "Installing node from this system's packages (apt-get install nodejs)."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends nodejs
fi
NODE="$(command -v node)" || die "node isn't installed, and couldn't be."
case "$NODE" in /*) ;; *) die "node's path isn't a whole one." ;; esac
major="$("$NODE" -p 'process.versions.node.split(".")[0]')"
[ "$major" -ge 18 ] 2> /dev/null || die "this system's node is version $major; the store needs 18 or newer (Debian 12, Ubuntu 24.04)."

if ! id "$USER_NAME" > /dev/null 2>&1; then
  useradd --system --user-group --home-dir "$HOME_DIR" --no-create-home --shell /bin/sh "$USER_NAME"
fi
# No password at all (*), which is not the same as a locked account (!): ssh lets a key in, and nothing else.
usermod -p '*' "$USER_NAME"

install -d -m 755 -o root -g root /opt/pigeonhole /etc/pigeonhole /var/lib/pigeonhole "$HOME_DIR" "$HOME_DIR/.ssh"
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$STORE_DIR"

# Each file written beside its place, then moved there: never half a file where one is read.
put() {  # put MODE FILE: standard input, as root's FILE
  cat > "$2.new"
  chown root:root "$2.new"; chmod "$1" "$2.new"
  mv -f "$2.new" "$2"
}
write_store_js /opt/pigeonhole/store.js.new; chown root:root /opt/pigeonhole/store.js.new; chmod 644 /opt/pigeonhole/store.js.new
mv -f /opt/pigeonhole/store.js.new /opt/pigeonhole/store.js
write_pull_js /opt/pigeonhole/pull.js.new; chown root:root /opt/pigeonhole/pull.js.new; chmod 644 /opt/pigeonhole/pull.js.new
mv -f /opt/pigeonhole/pull.js.new /opt/pigeonhole/pull.js
"$NODE" --check /opt/pigeonhole/store.js || die "store.js didn't arrive whole."
"$NODE" --check /opt/pigeonhole/pull.js || die "pull.js didn't arrive whole."

put 644 "/etc/pigeonhole/$PH_SITE.env" <<ENV
PIGEONHOLE_STORE=$STORE_DIR
PIGEONHOLE_LISTEN=$PH_LISTEN
PIGEONHOLE_PATH=$PH_PATH
ENV

# The one key, and all it may do: run pull.js for this store, and only when the connection comes from the web
# server (the Mac's ssh arrives through it): so a copy of the key is no use from anywhere else, whatever the firewall
# lets through. "restrict" takes everything else away (a shell, a terminal, every kind of forwarding, the user's own
# rc file), now and for whatever ssh adds later.
put 644 "$HOME_DIR/.ssh/authorized_keys" <<KEYS
restrict,from="$PH_WEB",command="$NODE /opt/pigeonhole/pull.js $STORE_DIR" $PH_KEY offprint-pigeonhole-$PH_SITE
KEYS

put 644 /etc/systemd/system/pigeonhole@.service <<UNIT
[Unit]
Description=Offprint pigeonhole for %i
After=network-online.target
Wants=network-online.target

[Service]
User=ph-%i
Group=ph-%i
EnvironmentFile=/etc/pigeonhole/%i.env
ExecStart=$NODE /opt/pigeonhole/store.js
Restart=on-failure
RestartSec=5
UMask=0077
# It may write its own store and nothing else, anywhere.
ProtectSystem=strict
ReadWritePaths=/var/lib/pigeonhole/%i/store
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
# No privilege, and no way to one.
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
SystemCallArchitectures=native
SystemCallFilter=@system-service
# node's engine asks for a memory protection key as it starts, and that list leaves the call out: a program is
# killed at the first call outside the filter, so without this line the store dies at every start (signal SYS).
# The three touch its own memory alone.
SystemCallFilter=pkey_alloc pkey_mprotect pkey_free
# The internet's two families only (its one listening socket); who it may speak with is the instance's own file.
RestrictAddressFamilies=AF_INET AF_INET6
MemoryMax=256M
TasksMax=64

[Install]
WantedBy=multi-user.target
UNIT

# The instance's own: it speaks with the web server and with nobody else, in or out. (The store never starts a
# connection; this is what holds it to that, should it ever be made to try.)
install -d -m 755 -o root -g root "/etc/systemd/system/pigeonhole@$PH_SITE.service.d"
put 644 "/etc/systemd/system/pigeonhole@$PH_SITE.service.d/network.conf" <<NET
[Service]
IPAddressDeny=any
IPAddressAllow=$PH_WEB
NET

# start_store: the unit enabled and started, and called running only once it has stayed up. A store that dies as it
# starts is "active" again each time systemd starts it again (RestartSec, above), so asking systemd once says
# nothing: the look is at the process, which must be there, and the same one after longer than that wait.
start_store() {
  local unit="pigeonhole@$PH_SITE.service" pid now
  systemctl daemon-reload
  systemctl enable "$unit"
  systemctl restart "$unit"
  sleep 2
  pid="$(systemctl show "$unit" -p MainPID --value)" || pid=0
  sleep 8
  now="$(systemctl show "$unit" -p MainPID --value)" || now=0
  if ! systemctl is-active --quiet "$unit" || [ -z "$pid" ] || [ "$pid" = 0 ] || [ "$now" != "$pid" ]; then
    die "the store didn't stay up: systemd starts it and it stops, again and again. journalctl -u pigeonhole@$PH_SITE -n 20 says why (is $PH_LISTEN this machine's own address? A line with status=31/SYS means the unit's SystemCallFilter refused a call node made: journalctl -k | grep type=1326 names it). To stop systemd trying: systemctl stop pigeonhole@$PH_SITE."
  fi
  echo "The store is running: pigeonhole@$PH_SITE, taking $PH_PATH on $PH_LISTEN."
}

if [ -d /run/systemd/system ]; then
  start_store
else
  echo "systemd isn't running here, so the unit is written but nothing was started."
fi

echo
echo "This machine's ssh host key, for site.json's \"server_host_key\":"
if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
  echo "  $(cut -d ' ' -f 1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
else
  echo "  (no /etc/ssh/ssh_host_ed25519_key.pub here: ssh-keygen -A makes one)"
fi
echo
echo "The firewall is yours to set: only the web server ($PH_WEB) may reach this machine, on ssh and on the"
echo "store's port, and nothing else may reach it at all. With ufw, from a session that comes through the web"
echo "server (or its console), so that you are not shut out:"
echo "  ufw default deny incoming"
echo "  ufw allow from $PH_WEB to any port $PH_SSH_PORT proto tcp"
echo "  ufw allow from $PH_WEB to any port ${PH_LISTEN##*:} proto tcp"
echo "  ufw enable"
