#!/bin/bash
# client-d (AS 64604) - single-homed a leaf3, VRF tenant-B
# OJO: este cliente vive en otro VRF -> NO debería ver a A/B/C aunque
# comparta fabric. Es el demo de multi-tenancy.
set -e
ip link set eth1 up
ip addr add 172.16.100.40/24 dev eth1
ip route add default via 172.16.100.1
ip link add lo-cust type dummy
ip link set lo-cust up
ip addr add 192.0.2.40/32 dev lo-cust
/usr/lib/frr/frrinit.sh start
