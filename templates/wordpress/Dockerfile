# The official WordPress image plus WP-CLI (which it does not ship), for bin/wp.
FROM wordpress:php8.3-apache
# The checksum is the release's own (wp-cli-2.11.0.phar.sha256 beside it on GitHub): a changed download stops the
# build. A new WP_CLI_VERSION needs its checksum here too.
ARG WP_CLI_VERSION=2.11.0
ADD --checksum=sha256:a39021ac809530ea607580dbf93afbc46ba02f86b6cffd03de4b126ca53079f6 \
    https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar /usr/local/bin/wp
RUN chmod 755 /usr/local/bin/wp \
 && apt-get update && apt-get install -y --no-install-recommends less default-mysql-client \
 && rm -rf /var/lib/apt/lists/*
