#!/bin/bash
# Demo 3: L3 simétrico (Type-5) + Anycast Gateway
# El SVI 100.64.0.1 vive en los TRES leafs con el mismo MAC.
# El cliente nunca sabe cuál es su default GW real.
set -e
echo ">>> [leaf1] SVI br10100 y MAC anycast (mismo en leaf1/leaf2/leaf3)"
docker exec clab-evpn-ixp-lab-leaf1 ip -d -br link show br10100
echo
echo ">>> [leaf2] mismo MAC"
docker exec clab-evpn-ixp-lab-leaf2 ip -d -br link show br10100
echo
echo ">>> [leaf3] mismo MAC"
docker exec clab-evpn-ixp-lab-leaf3 ip -d -br link show br10100
echo
echo ">>> [leaf1] Rutas Type-5 recibidas por overlay (VRF tenant-A)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn route type prefix"
echo
echo ">>> [leaf1] Tabla de rutas dentro del VRF tenant-A"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show ip route vrf tenant-A"
