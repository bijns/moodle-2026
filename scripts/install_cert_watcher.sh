#!/bin/bash
# Installs the nginx certificate watcher on an existing web server (same logic as the block at the end of
# setup_webserver.sh). Run as root. Prints the stamp so you can see it is active.
set -u
cat > /usr/local/bin/nginx-cert-watch.sh <<'CERTWATCH'
#!/bin/bash
# Reloads nginx on this web server when /moodle/certs/nginx.crt changed since the last load.
STAMP=/run/nginx-cert.sha256
CRT=/moodle/certs/nginx.crt
[ -r "$CRT" ] || exit 0
NEW=$(sha256sum "$CRT" | cut -d' ' -f1)
if [ ! -s "$STAMP" ]; then echo "$NEW" > "$STAMP"; exit 0; fi
OLD=$(cat "$STAMP")
[ "$OLD" = "$NEW" ] && exit 0
if nginx -t > /dev/null 2>&1; then
  systemctl reload nginx && echo "$NEW" > "$STAMP" && logger -t nginx-cert-watch "reloaded nginx: certificate changed"
else
  logger -t nginx-cert-watch "nginx -t failed; certificate not reloaded"
fi
CERTWATCH
chmod 755 /usr/local/bin/nginx-cert-watch.sh
echo '* * * * * root timeout 30 /usr/local/bin/nginx-cert-watch.sh' > /etc/cron.d/nginx-cert-watch
chmod 644 /etc/cron.d/nginx-cert-watch
/usr/local/bin/nginx-cert-watch.sh
echo "host: $(hostname) stamp: $(cut -c1-12 /run/nginx-cert.sha256 2>/dev/null) crt: $(sha256sum /moodle/certs/nginx.crt | cut -c1-12)"
echo "nginx: $(systemctl is-active nginx), config test: $(nginx -t 2>&1 | tail -1 | cut -c1-60)"
cat /etc/cron.d/nginx-cert-watch
