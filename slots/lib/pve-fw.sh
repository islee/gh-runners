#!/bin/bash
# pve-fw.sh — the per-VM Proxmox firewall file that isolates a supabase-class VM from the LAN.
#
# Context: sourced (never executed) by slots/launch-pve.sh (every job VM) and
# images/build-supabase-pve.sh (the golden during its build), so the egress rules live in ONE place.
# Written to /etc/pve/firewall/<vmid>.fw; it only takes effect when the NIC has firewall=1 AND the
# datacenter firewall is enabled (cluster.fw `enable: 1`) -- launch-pve proves the result from inside
# the guest (LAN preflight) instead of trusting either.
#
# Semantics (first match wins; replies to established connections are accepted before the rules):
#   - inbound fully dropped (control is via the guest agent, which is not network traffic)
#   - outbound: IPv6 ICMP allowed (neighbour discovery), every private / link-local / CGNAT range
#     dropped, everything else (the public internet) allowed. DNS therefore goes to PUBLIC resolvers
#     (see PVE_NAMESERVER); there is no LAN exception. DHCP is covered by PVE's built-in `dhcp` option.
# NOTE: IPv4 is what the preflight probes; the IPv6 ranges below drop link-local and ULA only, so a
# globally routable IPv6 address on the LAN would not be blocked by this file.

# pve_fw_rules — print the firewall file contents.
pve_fw_rules() {
  cat <<'FW'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
[RULES]
OUT ACCEPT -p ipv6-icmp
OUT DROP -dest 10.0.0.0/8 -log nolog
OUT DROP -dest 172.16.0.0/12 -log nolog
OUT DROP -dest 192.168.0.0/16 -log nolog
OUT DROP -dest 100.64.0.0/10 -log nolog
OUT DROP -dest 169.254.0.0/16 -log nolog
OUT DROP -dest fe80::/10 -log nolog
OUT DROP -dest fc00::/7 -log nolog
FW
}
