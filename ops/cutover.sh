#!/bin/bash
# Moodle blue -> green cutover, run from the HA host (it has ssh access to both controllers).
# Phases: preflight | freeze | sync | golive | dns | finish
# No secrets in this file. Blue = old 22.04 stack (ssh alias "moodle"), green = new 24.04 stack.
set -u
GREEN_IP=172.160.74.43
GREEN_LB=135.116.250.247
GREEN_FQDN=lb-c3gvd6.swedencentral.cloudapp.azure.com
BLUE_FQDN=lb-k3d5l3.swedencentral.cloudapp.azure.com
RECORD_ID=758834697
b() { ssh -o ConnectTimeout=15 moodle "$@"; }
g() { ssh -i ~/.ssh/id_moodle -o ConnectTimeout=15 azureadmin@$GREEN_IP "$@"; }
ts() { date +%T; }
MAXCODE="cd /moodle/html/moodle && sudo -u www-data php admin/cli/maintenance.php"
EXCL="--exclude=moodledata/cache --exclude=moodledata/localcache --exclude=moodledata/temp --exclude=moodledata/sessions --exclude=moodledata/trashdir"

case "${1:-}" in
preflight)
  echo "== preflight $(ts)"
  echo "blue : $(b 'hostname; grep -E "^.release" /moodle/html/moodle/version.php | cut -c1-50; ls /moodle/moodledata/climaintenance.html 2>&1 | cut -c1-40' | tr '\n' ' ')"
  echo "green: $(g 'hostname; grep -E "^.release" /moodle/html/moodle/version.php | cut -c1-50; ls /moodle/moodledata/climaintenance.html 2>&1 | cut -c1-40' | tr '\n' ' ')"
  echo "green cron lines active: $(g 'grep -v "^#" /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php')  (expect 0 until golive)"
  echo "green noemailever: $(g 'grep -c noemailever /moodle/html/moodle/config.php')  (expect 1 until sync)"
  echo "green certbot timer: $(g 'systemctl is-enabled certbot.timer 2>&1')  blue certbot timer: $(b 'systemctl is-enabled certbot.timer 2>&1')"
  echo "blue cron lines active: $(b 'grep -v "^#" /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php')"
  echo "disk free: blue /var/backups $(b "df -h /var/backups | tail -1 | awk '{print \$4}'")  green /var/backups $(g "df -h /var/backups | tail -1 | awk '{print \$4}'")  HA /tmp $(df -h /tmp | tail -1 | awk '{print $4}')"
  echo "green db: $(g 'sudo mysql --defaults-extra-file=/root/.moodle-green.cnf -N -e "select count(*) from information_schema.tables where table_schema=\"moodle\""') tables"
  echo "green LB login: $(curl -sk -m 30 -o /dev/null -w '%{http_code} %{size_download}B' --resolve moodle.e-office.com:443:$GREEN_LB https://moodle.e-office.com/login/index.php)"
  echo "blue  LB login: $(curl -s -m 30 -o /dev/null -w '%{http_code} %{size_download}B' https://moodle.e-office.com/login/index.php)"
  ;;

freeze)
  echo "== FREEZE blue $(ts)"
  b "$MAXCODE --enable" 2>&1 | tail -n 2 | cut -c1-100
  b "sudo sed -i '/admin.cli.cron.php/{/^#/!s/^/#DISABLED-CUTOVER /}' /etc/cron.d/moodle-cron; echo blue cron active lines now: \$(grep -v '^#' /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php)"
  echo "waiting 60 s so all web servers see maintenance mode (NFS attribute cache) $(ts)"
  sleep 60
  echo "running cron processes on blue: $(b 'pgrep -fc "[a]dmin/cli/cron.php"')"
  b "date -u '+%Y-%m-%d %H:%M:%S'" > /tmp/freeze.utc
  echo "freeze time (UTC) $(cat /tmp/freeze.utc)"
  echo "== final dump on blue $(ts)"
  b 'sudo /usr/local/bin/moodle-db-backup.sh 2>&1 | cut -c1-100'
  b 'sudo cat /moodle/db-backup.sql.gz' > /tmp/final.sql.gz
  ls -l /tmp/final.sql.gz | awk '{print "final.sql.gz bytes:", $5}'
  gzip -t /tmp/final.sql.gz && echo "gzip ok"
  echo "last line: $(zcat /tmp/final.sql.gz | tail -1 | cut -c1-60)"
  echo "CREATE TABLE count: $(zcat /tmp/final.sql.gz | grep -c '^CREATE TABLE')"
  echo "== blue frozen $(ts)"
  ;;

sync)
  echo "== SYNC to green $(ts)"
  [ -s /tmp/final.sql.gz ] || { echo "no /tmp/final.sql.gz: run freeze first"; exit 1; }
  g 'sudo mysql --defaults-extra-file=/root/.moodle-green.cnf -e "DROP DATABASE moodle; CREATE DATABASE moodle CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"' 2>&1 | cut -c1-120
  zcat /tmp/final.sql.gz | sed -E '/^(LOCK|UNLOCK) TABLES/d' | g 'sudo mysql --defaults-extra-file=/root/.moodle-green.cnf --default-character-set=utf8mb4' 2>&1 | cut -c1-160
  echo "restore pipe exits: ${PIPESTATUS[*]}  $(ts)"
  echo "green tables: $(g 'sudo mysql --defaults-extra-file=/root/.moodle-green.cnf -N -e "select count(*) from information_schema.tables where table_schema=\"moodle\""') (expect 514)"
  echo "== moodledata delta since 2026-11-14 15:20 UTC $(ts)"
  b "sudo tar -C /moodle -c $EXCL --newer-mtime='2026-11-14 15:20:00' moodledata" | g 'sudo tar -C /moodle -x'
  echo "delta pipe exits: ${PIPESTATUS[*]}  $(ts)"
  g 'sudo chown www-data:www-data /moodle/moodledata; sudo chmod 770 /moodle/moodledata; for d in cache localcache temp sessions trashdir; do sudo install -d -o www-data -g www-data -m 770 /moodle/moodledata/$d; done; ls /moodle/moodledata/climaintenance.html 2>&1 | cut -c1-60'
  echo "== upgrade green DB (4.5.10 data -> 4.5.16 code) $(ts)"
  g 'cd /moodle/html/moodle && sudo -u www-data php admin/cli/upgrade.php --non-interactive > /tmp/upgrade2.log 2>&1; echo upgrade-exit=$?; tail -n 3 /tmp/upgrade2.log | cut -c1-140; echo errors: $(grep -c -i -E "error|exception|fatal" /tmp/upgrade2.log)'
  echo "== revert rehearsal settings on green $(ts)"
  g "sudo sed -i 's/^#DISABLED-REHEARSAL //' /etc/cron.d/moodle-cron; echo green cron active lines: \$(grep -v '^#' /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php); sudo sed -i '/noemailever/d' /moodle/html/moodle/config.php; echo noemailever left: \$(grep -c noemailever /moodle/html/moodle/config.php); php -l /moodle/html/moodle/config.php | cut -c1-60"
  g 'cd /moodle/html/moodle && sudo -u www-data php admin/cli/purge_caches.php 2>&1 | cut -c1-80; sudo /usr/local/bin/update_last_modified_time.moodle_on_azure.sh; echo stamp: $(cat /moodle/html/moodle/.last_modified_time.moodle_on_azure)'
  echo "== certbot timer: enable on green, disable on blue $(ts)"
  g 'sudo systemctl enable --now certbot.timer 2>&1 | tail -n 1 | cut -c1-80; systemctl is-active certbot.timer'
  b 'sudo systemctl disable --now certbot.timer 2>&1 | tail -n 1 | cut -c1-80; systemctl is-active certbot.timer'
  echo "== sync done $(ts): green still in maintenance mode; wait ~100 s for web VMs to resync, then run golive"
  ;;

golive)
  echo "== GO LIVE green (maintenance off) $(ts)"
  g "$MAXCODE --disable" 2>&1 | tail -n 2 | cut -c1-100
  sleep 5
  for i in 1 2 3; do curl -sk -m 40 -o /tmp/gl$i.html -w "green $i: %{http_code} %{size_download}B %{time_total}s\n" --resolve moodle.e-office.com:443:$GREEN_LB https://moodle.e-office.com/login/index.php; done
  echo "title: $(grep -o '<title>[^<]*' /tmp/gl3.html | head -1)  lang: $(grep -o 'lang="[a-z]*"' /tmp/gl3.html | head -1)"
  echo "cert: $(echo | openssl s_client -connect $GREEN_LB:443 -servername moodle.e-office.com 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
  ;;

dns)
  echo "== DNS flip: moodle -> green $(ts)"
  b "sudo bash -c \". /root/hookfn.sh; load_conf; api mod-record record-id=$RECORD_ID host=moodle record=$GREEN_FQDN ttl=60 | jq -c .; api records host=moodle type=CNAME | jq -c '.[]|{id,host,record,ttl,status}'\"" 2>&1 | cut -c1-220
  sleep 20
  for r in 1.1.1.1 8.8.8.8; do echo "resolver $r: $(nslookup moodle.e-office.com $r 2>/dev/null | grep -i -E 'canonical|cname|Address' | tail -n 3 | tr '\n' ' ' | cut -c1-200)"; done
  echo "public check (system resolver): $(curl -s -m 30 -o /dev/null -w '%{remote_ip} %{http_code} %{size_download}B' https://moodle.e-office.com/login/index.php)  (green LB is $GREEN_LB)"
  ;;

finish)
  echo "== cleanup on HA host $(ts)"
  rm -f /tmp/blue.sql.gz /tmp/final.sql.gz /tmp/gl*.html /tmp/freeze.utc
  ls /tmp/*.sql.gz 2>&1 | head -n 2
  ;;

*) echo "usage: $0 preflight|freeze|sync|golive|dns|finish" ;;
esac
