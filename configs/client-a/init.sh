#!/bin/bash
# client-a (AS 64601) - single-homed a leaf1, VLAN Peering 100.64.0.10
set -e
ip link set eth1 up
ip addr add 100.64.0.10/24 dev eth1
# Loopback simulando un prefijo del cliente que se anuncia al fabric
ip link add lo-cust type dummy
ip link set lo-cust up
ip addr add 192.0.2.10/32 dev lo-cust
/usr/lib/frr/frrinit.sh start
