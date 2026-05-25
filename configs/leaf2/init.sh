#!/bin/bash
# =============================================================================
# leaf2 init - AS 65012 / VTEP 10.0.0.12
# Tiene:
#   - eth3 -> client-b (VLAN Peering, single-homed)
#   - bond-esi10 (eth4) -> client-c (ESI-LAG con leaf3)
# =============================================================================
set -e

ip link set lo up
ip addr add 10.0.0.12/32 dev lo || true

# VRFs
ip link add tenant-A type vrf table 1000
ip link set tenant-A up
ip link add tenant-B type vrf table 1001
ip link set tenant-B up

# Bridges L2
ip link add br10100 type bridge stp_state 0
ip link set br10100 up
ip link add br10200 type bridge stp_state 0
ip link set br10200 up

# Bridges para L3VNI
ip link add br-l3-A type bridge stp_state 0
ip link set br-l3-A master tenant-A
ip link set br-l3-A up
ip link add br-l3-B type bridge stp_state 0
ip link set br-l3-B master tenant-B
ip link set br-l3-B up

# VXLAN devices
ip link add vni10100 type vxlan id 10100 dstport 4789 local 10.0.0.12 nolearning
ip link set vni10100 master br10100
ip link set vni10100 up
bridge link set dev vni10100 neigh_suppress on learning off

ip link add vni10200 type vxlan id 10200 dstport 4789 local 10.0.0.12 nolearning
ip link set vni10200 master br10200
ip link set vni10200 up
bridge link set dev vni10200 neigh_suppress on learning off

ip link add vni5000 type vxlan id 5000 dstport 4789 local 10.0.0.12 nolearning
ip link set vni5000 master br-l3-A
ip link set vni5000 up
bridge link set dev vni5000 neigh_suppress on learning off

ip link add vni5001 type vxlan id 5001 dstport 4789 local 10.0.0.12 nolearning
ip link set vni5001 master br-l3-B
ip link set vni5001 up
bridge link set dev vni5001 neigh_suppress on learning off

# Anycast SVIs (mismo MAC que leaf1/leaf3 = anycast GW)
ip link set br10100 master tenant-A
ip link set br10100 address 44:38:39:ff:00:64
ip addr add 100.64.0.1/24 dev br10100
ip link set br10200 master tenant-A
ip link set br10200 address 44:38:39:ff:00:c8
ip addr add 100.64.2.1/24 dev br10200

# eth3 -> client-b single-homed en VLAN Peering
ip link set eth3 master br10100
ip link set eth3 up

# eth4 -> client-c via bond-esi10 (ESI-LAG con leaf3)
# Bond LACP all-active, conectado al br10100
# ad_actor_system DEBE ser idéntico en leaf2 y leaf3 para que el cliente
# vea un solo "peer LACP" y bundlee ambos puertos en el mismo aggregator.
# Sin esto, el cliente trata cada leaf como un peer distinto y solo
# activa UN puerto a la vez -> failover de ~3s en vez de <200ms.
ip link add bond-esi10 type bond mode 802.3ad miimon 100 lacp_rate fast \
  ad_actor_system 02:00:00:00:00:0c ad_actor_sys_prio 100
ip link set eth4 down
ip link set eth4 master bond-esi10
ip link set eth4 up
ip link set bond-esi10 master br10100
ip link set bond-esi10 up
# MAC del bond device (= ESI sys-mac usado por FRR para anunciar el ES)
ip link set bond-esi10 address 02:00:00:00:00:0c

# --- E-Line: L2VNI 10300 dedicado (servicio punto a punto, sin gateway) -------
ip link add br10300 type bridge stp_state 0
ip link set br10300 up
ip link add vni10300 type vxlan id 10300 dstport 4789 local 10.0.0.12 nolearning
ip link set vni10300 master br10300
ip link set vni10300 up
bridge link set dev vni10300 neigh_suppress on learning off
ip link set eth5 master br10300
ip link set eth5 up

/usr/lib/frr/frrinit.sh start
