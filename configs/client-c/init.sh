#!/bin/bash
# client-c (AS 64603) - MULTI-HOMED ESI-LAG a leaf2 + leaf3
# eth1 -> leaf2, eth2 -> leaf3. Bond LACP all-active.
set -e
ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast
ip link set eth1 down && ip link set eth1 master bond0 && ip link set eth1 up
ip link set eth2 down && ip link set eth2 master bond0 && ip link set eth2 up
ip link set bond0 up
ip addr add 100.64.0.30/24 dev bond0
ip link add lo-cust type dummy
ip link set lo-cust up
ip addr add 192.0.2.30/32 dev lo-cust
/usr/lib/frr/frrinit.sh start
