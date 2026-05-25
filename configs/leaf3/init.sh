#!/bin/bash
# =============================================================================
# leaf3 init - AS 65013 / VTEP 10.0.0.13
# Tiene:
#   - eth3 -> client-c (segundo leg ESI-LAG con leaf2)
#   - eth4 -> client-d (single-homed, VRF tenant-B)
# =============================================================================
set -e

ip link set lo up
ip addr add 10.0.0.13/32 dev lo || true

ip link add tenant-A type vrf table 1000
ip link set tenant-A up
ip link add tenant-B type vrf table 1001
ip link set tenant-B up

# Bridge para VLAN Peering (br10100) en tenant-A
ip link add br10100 type bridge stp_state 0
ip link set br10100 up
ip link add br10200 type bridge stp_state 0
ip link set br10200 up

# Bridge para tenant-B (donde vive client-d)
ip link add br20100 type bridge stp_state 0
ip link set br20100 up

# Bridges L3VNI
ip link add br-l3-A type bridge stp_state 0
ip link set br-l3-A master tenant-A
ip link set br-l3-A up
ip link add br-l3-B type bridge stp_state 0
ip link set br-l3-B master tenant-B
ip link set br-l3-B up

# VXLAN devices
ip link add vni10100 type vxlan id 10100 dstport 4789 local 10.0.0.13 nolearning
ip link set vni10100 master br10100
ip link set vni10100 up
bridge link set dev vni10100 neigh_suppress on learning off

ip link add vni10200 type vxlan id 10200 dstport 4789 local 10.0.0.13 nolearning
ip link set vni10200 master br10200
ip link set vni10200 up
bridge link set dev vni10200 neigh_suppress on learning off

# L2VNI nuevo 20100 -> tenant-B (client-d)
ip link add vni20100 type vxlan id 20100 dstport 4789 local 10.0.0.13 nolearning
ip link set vni20100 master br20100
ip link set vni20100 up
bridge link set dev vni20100 neigh_suppress on learning off

ip link add vni5000 type vxlan id 5000 dstport 4789 local 10.0.0.13 nolearning
ip link set vni5000 master br-l3-A
ip link set vni5000 up
bridge link set dev vni5000 neigh_suppress on learning off

ip link add vni5001 type vxlan id 5001 dstport 4789 local 10.0.0.13 nolearning
ip link set vni5001 master br-l3-B
ip link set vni5001 up
bridge link set dev vni5001 neigh_suppress on learning off

# Anycast SVIs
ip link set br10100 master tenant-A
ip link set br10100 address 44:38:39:ff:00:64
ip addr add 100.64.0.1/24 dev br10100
ip link set br10200 master tenant-A
ip link set br10200 address 44:38:39:ff:00:c8
ip addr add 100.64.2.1/24 dev br10200
# br20100 vive en tenant-B (aislado de tenant-A)
ip link set br20100 master tenant-B
ip link set br20100 address 44:38:39:ff:01:64
ip addr add 172.16.100.1/24 dev br20100

# eth3 -> client-c via bond-esi10 (segundo leg ESI-LAG)
# ad_actor_system = MISMO que leaf2 -> el cliente ve UN solo peer LACP
# y bundlea eth1+eth2 en el mismo aggregator (all-active de verdad).
ip link add bond-esi10 type bond mode 802.3ad miimon 100 lacp_rate fast \
  ad_actor_system 02:00:00:00:00:0c ad_actor_sys_prio 100
ip link set eth3 down
ip link set eth3 master bond-esi10
ip link set eth3 up
ip link set bond-esi10 master br10100
ip link set bond-esi10 up
ip link set bond-esi10 address 02:00:00:00:00:0c

# eth4 -> client-d single-homed en tenant-B
ip link set eth4 master br20100
ip link set eth4 up

/usr/lib/frr/frrinit.sh start
