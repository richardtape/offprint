# The two machines of tests/rehearsal.sh, from one image: a Debian with sshd, node (for the store, from the system's
# own packages, as the printed set-up installs it) and Caddy (for the web server, copied from Caddy's own image).
# Never used for a real site.
FROM caddy:2 AS caddy
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server nodejs curl ca-certificates procps iproute2 systemd \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /srv /etc/caddy \
 && rm -f /etc/ssh/ssh_host_*
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
RUN : > /etc/caddy/site-extra.caddy
