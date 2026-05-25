#!/bin/bash
# =============================================================================
# leaf1 init - underlay + VXLAN + VRFs
# AS 65011 / loopback 10.0.0.11
# VTEP source: 10.0.0.11
# =============================================================================
set -e

ip link set lo up
ip addr add 10.0.0.11/32 dev lo || true

# --- VRFs (tenants) -----------------------------------------------------------
ip link add tenant-A type vrf table 1000
ip link set tenant-A up
ip link add tenant-B type vrf table 1001
ip link set tenant-B up

# --- Bridges para los L2VNI ---------------------------------------------------
# br10100: VLAN Peering (clientes IXP)
ip link add br10100 type bridge stp_state 0
ip link set br10100 up
# br10200: mgmt interna (multi-tenant)
ip link add br10200 type bridge stp_state 0
ip link set br10200 up
# br-l3-A / br-l3-B: bridges para los L3VNI (IRB simétrico)
ip link add br-l3-A type bridge stp_state 0
ip link set br-l3-A master tenant-A
ip link set br-l3-A up
ip link add br-l3-B type bridge stp_state 0
ip link set br-l3-B master tenant-B
ip link set br-l3-B up

# --- VXLAN devices ------------------------------------------------------------
# L2VNI 10100
ip link add vni10100 type vxlan id 10100 dstport 4789 local 10.0.0.11 nolearning
ip link set vni10100 master br10100
ip link set vni10100 up
bridge link set dev vni10100 neigh_suppress on learning off

# L2VNI 10200 (tenant interno)
ip link add vni10200 type vxlan id 10200 dstport 4789 local 10.0.0.11 nolearning
ip link set vni10200 master br10200
ip link set vni10200 up
bridge link set dev vni10200 neigh_suppress on learning off

# L3VNI 5000 (tenant-A)
ip link add vni5000 type vxlan id 5000 dstport 4789 local 10.0.0.11 nolearning
ip link set vni5000 master br-l3-A
ip link set vni5000 up
bridge link set dev vni5000 neigh_suppress on learning off

# L3VNI 5001 (tenant-B)
ip link add vni5001 type vxlan id 5001 dstport 4789 local 10.0.0.11 nolearning
ip link set vni5001 master br-l3-B
ip link set vni5001 up
bridge link set dev vni5001 neigh_suppress on learning off

# --- Anycast SVIs (mismo MAC en todos los leafs = anycast gateway) ------------
# br10100 -> tenant-A (clientes IXP)
ip link set br10100 master tenant-A
ip link set br10100 address 44:38:39:ff:00:64
ip addr add 100.64.0.1/24 dev br10100
# br10200 -> tenant-A (mgmt comparte tenant-A en este lab)
ip link set br10200 master tenant-A
ip link set br10200 address 44:38:39:ff:00:c8
ip addr add 100.64.2.1/24 dev br10200

# --- Access ports (clientes) --------------------------------------------------
# eth3 -> client-a en VLAN Peering (L2VNI 10100)
ip link set eth3 master br10100
ip link set eth3 up

# --- E-Line: L2VNI 10300 dedicado (servicio punto a punto, sin gateway) -------
ip link add br10300 type bridge stp_state 0
ip link set br10300 up
ip link add vni10300 type vxlan id 10300 dstport 4789 local 10.0.0.11 nolearning
ip link set vni10300 master br10300
ip link set vni10300 up
bridge link set dev vni10300 neigh_suppress on learning off
ip link set eth5 master br10300
ip link set eth5 up

# --- BGP/EVPN suelto ----------------------------------------------------------
/usr/lib/frr/frrinit.sh start
