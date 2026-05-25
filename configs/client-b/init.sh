#!/bin/bash
# client-b (AS 64602) - single-homed a leaf2, VLAN Peering 100.64.0.20
set -e
ip link set eth1 up
ip addr add 100.64.0.20/24 dev eth1
ip link add lo-cust type dummy
ip link set lo-cust up
ip addr add 192.0.2.20/32 dev lo-cust
/usr/lib/frr/frrinit.sh start
