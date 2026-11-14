#!/bin/bash
# Rate-limits Moodle login attempts in nginx: POST /login/index.php, 10 per minute per client IP (burst 10), then HTTP 429.
# Page views (GET) and every other URL are not limited (the map key is empty for them). Run as root on a web server.
set -u
F=/etc/nginx/conf.d/moodle-login-limit.conf
cat > "$F" <<'CONF'
# Login brute-force protection (added 2026-11-14). Only POST /login/index.php gets a key; other requests are exempt.
map $request_method$request_uri $moodle_login_key {
    default "";
    ~^POST/login/index[.]php $binary_remote_addr;
}
limit_req_zone $moodle_login_key zone=moodlelogin:10m rate=10r/m;
limit_req zone=moodlelogin burst=10 nodelay;
limit_req_status 429;
CONF
if ! nginx -t > /dev/null 2>&1; then
  echo "nginx -t FAILED, reverting"; rm -f "$F"; nginx -t 2>&1 | tail -n 3 | cut -c1-150; exit 1
fi
if ! nginx -T 2>/dev/null | grep -q moodlelogin; then
  echo "conf.d is NOT included by nginx.conf: limit not active"; rm -f "$F"; exit 1
fi
systemctl reload nginx && echo "login rate limit active on $(hostname): $(nginx -T 2>/dev/null | grep -c moodlelogin) directives loaded"
