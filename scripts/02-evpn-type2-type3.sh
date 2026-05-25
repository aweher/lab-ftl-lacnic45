#!/bin/bash
# Demo 2: L2 stretch — EVPN Type-2 (MAC/IP) y Type-3 (IMET)
# Caso: client-a y client-b están en la MISMA VLAN Peering (L2VNI 10100),
# pero conectados a leafs distintos.
set -e
echo ">>> [client-a] ping al MAC de client-b (mismo subnet, distinto leaf)"
docker exec clab-evpn-ixp-lab-client-a ping -c 3 100.64.0.20
echo
echo ">>> [leaf1] Tabla MAC del bridge br10100"
docker exec clab-evpn-ixp-lab-leaf1 bridge fdb show br br10100 | grep -v permanent | head -20
echo
echo ">>> [leaf1] EVPN Type-2 (MAC/IP) y Type-3 (IMET) en la VNI 10100"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn route vni 10100"
echo
echo ">>> [leaf1] Resumen de VNIs activas"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni"
