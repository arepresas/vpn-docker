#!/bin/bash
# VPN-only access to stack web UIs. Re-applied at boot (cron @reboot).
# Allows: VPN subnet 10.8.0.0/24 (wg-easy default) + localhost everywhere,
# Docker bridge 10.14.0.0/24 (inter-container + Pi-hole upstreams DNS),
# UDP 51821 from anywhere (WireGuard handshake). Drops everything else
# to app ports (80,3000,3001,7681,8000,8081,8082,8443,9443 TCP, 53 TCP/UDP).
# wg-easy UI (8080/tcp) stays LAN-open on purpose: password auth + never
# forwarded on the router. VPN clients reach it via the ACCEPT above.
set -e
iptables -F DOCKER-USER
iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DOCKER-USER -p udp --dport 51821 -j ACCEPT
iptables -A DOCKER-USER -s 10.8.0.0/24 -j ACCEPT
iptables -A DOCKER-USER -s 127.0.0.0/8 -j ACCEPT
iptables -A DOCKER-USER -s 10.14.0.0/24 -j ACCEPT
for p in 80 3000 3001 3002 7681 8000 8081 8082 8443 9443 9898; do
  iptables -A DOCKER-USER -p tcp --dport "$p" -j DROP
done
iptables -A DOCKER-USER -p udp --dport 53 -j DROP
iptables -A DOCKER-USER -p tcp --dport 53 -j DROP
iptables -A DOCKER-USER -j RETURN
