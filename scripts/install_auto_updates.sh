#!/bin/bash
# Automatic OS updates for a Moodle VM, staggered so the VMs never update or reboot at the same moment.
# Usage (as root): install_auto_updates.sh controller|web
#   controller: install 01:45, reboot (only if an update asks for it) 03:00 (pauses the shared NFS storage for ~1-2 min)
#   web:        slot = VM number mod 4: install 02:30/02:40/02:50/03:00, reboot 03:30/03:50/04:10/04:30.
#               A web server is first drained from the load balancer (probe blocked 45 s), so no request is dropped.
# Security and regular (-updates) packages install by themselves; reboots only happen when /var/run/reboot-required exists.
set -u
ROLE=${1:-web}
N=$(hostname | grep -o '[0-9]*$' | sed 's/^0*//')
N=${N:-0}
if [ "$ROLE" = controller ]; then
  IM=105; RM=180
else
  S=$((N % 4)); IM=$((150 + S * 10)); RM=$((210 + S * 20))
fi
UP=$(printf '%02d:%02d' $((IM / 60)) $((IM % 60)))
RB=$(printf '%02d:%02d' $((RM / 60)) $((RM % 60)))

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* $UP
RandomizedDelaySec=0
EOF

cat > /usr/local/sbin/graceful-reboot.sh <<'EOF'
#!/bin/bash
# Reboots this VM only if an installed update asks for it. Web servers are drained from the load balancer first.
[ -f /var/run/reboot-required ] || exit 0
logger -t graceful-reboot "reboot required ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)); starting"
if [ -f /etc/graceful-reboot.web ]; then
  iptables -I INPUT 1 -s 168.63.129.16 -p tcp -m multiport --dports 80,443 -j DROP
  sleep 45
fi
systemctl reboot
EOF
chmod 755 /usr/local/sbin/graceful-reboot.sh
if [ "$ROLE" = controller ]; then rm -f /etc/graceful-reboot.web; else touch /etc/graceful-reboot.web; fi
echo "$((RM % 60)) $((RM / 60)) * * * root /usr/local/sbin/graceful-reboot.sh" > /etc/cron.d/graceful-reboot
chmod 644 /etc/cron.d/graceful-reboot

systemctl daemon-reload
systemctl enable --now unattended-upgrades > /dev/null 2>&1
systemctl restart apt-daily-upgrade.timer
echo "host $(hostname) role $ROLE: updates install at $UP, reboot (if needed) at $RB"
systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null | sed -n 2p | cut -c1-90
cat /etc/cron.d/graceful-reboot
