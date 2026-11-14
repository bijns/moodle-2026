#!/bin/bash
# Roll back from green to blue. Run from the HA host. No secrets in this file.
# Phases: dns | blue-up | green-down | status
# QUICK ROLLBACK: blue's database and files are exactly as they were at the freeze, so anything written on green after
# go-live (quiz attempts, submissions, logins) is NOT on blue. Use it early, while the green period is short/quiet.
set -u
GREEN_IP=172.160.74.43
GREEN_FQDN=lb-c3gvd6.swedencentral.cloudapp.azure.com
BLUE_FQDN=lb-k3d5l3.swedencentral.cloudapp.azure.com
RECORD_ID=758834697
b() { ssh -o ConnectTimeout=15 moodle "$@"; }
g() { ssh -i ~/.ssh/id_moodle -o ConnectTimeout=15 azureadmin@$GREEN_IP "$@"; }
ts() { date +%T; }
MAXCODE="cd /moodle/html/moodle && sudo -u www-data php admin/cli/maintenance.php"

case "${1:-}" in
green-down)
  echo "== green: maintenance ON, cron OFF, certbot timer OFF $(ts)"
  g "$MAXCODE --enable" 2>&1 | tail -n 1 | cut -c1-100
  g "sudo sed -i '/admin.cli.cron.php/{/^#/!s/^/#DISABLED-ROLLBACK /}' /etc/cron.d/moodle-cron; echo green cron active lines: \$(grep -v '^#' /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php); sudo systemctl disable --now certbot.timer 2>&1 | tail -n 1 | cut -c1-60"
  ;;
blue-up)
  echo "== blue: cron ON, certbot timer ON, maintenance OFF $(ts)"
  b "sudo sed -i 's/^#DISABLED-CUTOVER //' /etc/cron.d/moodle-cron; echo blue cron active lines: \$(grep -v '^#' /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php); sudo systemctl enable --now certbot.timer 2>&1 | tail -n 1 | cut -c1-60; systemctl is-active certbot.timer"
  b "$MAXCODE --disable" 2>&1 | tail -n 2 | cut -c1-100
  sleep 3
  curl -s -m 30 -o /dev/null -w "blue LB direct: %{http_code} %{size_download}B\n" --connect-to moodle.e-office.com:443:$BLUE_FQDN:443 https://moodle.e-office.com/login/index.php
  ;;
dns)
  echo "== DNS flip: moodle -> BLUE $(ts)"
  b "sudo bash -c \". /root/hookfn.sh; load_conf; api mod-record record-id=$RECORD_ID host=moodle record=$BLUE_FQDN ttl=60 | jq -c .; api records host=moodle type=CNAME | jq -c '.[]|{id,host,record,ttl,status}'\"" 2>&1 | cut -c1-220
  sleep 20
  for r in 1.1.1.1 8.8.8.8; do echo "resolver $r: $(nslookup moodle.e-office.com $r 2>/dev/null | grep -i -E 'canonical|cname|Address' | tail -n 3 | tr '\n' ' ' | cut -c1-200)"; done
  echo "public check: $(curl -s -m 30 -o /dev/null -w '%{remote_ip} %{http_code} %{size_download}B' https://moodle.e-office.com/login/index.php)"
  ;;
status)
  echo "DNS record: $(b "sudo bash -c \". /root/hookfn.sh; load_conf; api records host=moodle type=CNAME | jq -c '.[]|{record,ttl,status}'\"" 2>&1 | cut -c1-160)"
  echo "blue  maintenance flag: $(b 'sudo ls /moodle/moodledata/climaintenance.html 2>&1 | cut -c1-50')  cron active: $(b 'grep -v "^#" /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php')"
  echo "green maintenance flag: $(g 'sudo ls /moodle/moodledata/climaintenance.html 2>&1 | cut -c1-50')  cron active: $(g 'grep -v "^#" /etc/cron.d/moodle-cron | grep -c admin/cli/cron.php')"
  ;;
*) echo "usage: $0 green-down|blue-up|dns|status   (quick rollback order: green-down, blue-up, dns)" ;;
esac
