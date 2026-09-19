#!/bin/bash
# VPN-only access to stack web UIs. Re-applied at boot (cron @reboot).
# Allows: VPN subnet 10.8.0.0/24 (wg-easy default) + localhost everywhere,
# Docker bridge 10.14.0.0/24 (inter-container + Pi-hole upstreams DNS),
# UDP 51821 from anywhere (WireGuard handshake). Drops everything else
# to app ports (3000,3001,3002,7681,8000,8081,8082,8443,9443,9898 TCP,
# 53 TCP/UDP).
#
# LAN-open on purpose: 80/tcp (Homer menu) and 8080/tcp (wg-easy UI), both
# with password auth and neither forwarded on the router. Everything else
# needs the VPN first.
set -e

IPT="iptables -w 5"   # -w waits for the xtables lock instead of failing

# DOCKER-USER is created by dockerd. If cron beats dockerd on a cold boot the
# chain does not exist yet and the flush below would abort under set -e, leaving
# every UI wide open. Create it ourselves; harmless if dockerd already made it.
$IPT -t filter -N DOCKER-USER 2>/dev/null || true

$IPT -t filter -F DOCKER-USER
$IPT -t filter -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -t filter -A DOCKER-USER -p udp --dport 51821 -j ACCEPT
$IPT -t filter -A DOCKER-USER -s 10.8.0.0/24 -j ACCEPT
$IPT -t filter -A DOCKER-USER -s 127.0.0.0/8 -j ACCEPT
$IPT -t filter -A DOCKER-USER -s 10.14.0.0/24 -j ACCEPT
# 80 and 8080 are deliberately absent: Homer and the wg-easy UI stay
# reachable from the LAN.
for p in 3000 3001 3002 7681 8000 8081 8082 8443 9443 9898; do
  $IPT -t filter -A DOCKER-USER -p tcp --dport "$p" -j DROP
done
$IPT -t filter -A DOCKER-USER -p udp --dport 53 -j DROP
$IPT -t filter -A DOCKER-USER -p tcp --dport 53 -j DROP
$IPT -t filter -A DOCKER-USER -j RETURN
