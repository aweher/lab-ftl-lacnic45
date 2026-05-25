#!/bin/bash
# Demo 4: Multi-tenancy real - mismo fabric, dos tenants aislados
# client-a/b/c -> tenant-A (100.64.0.0/24)
# client-d     -> tenant-B (172.16.100.0/24)
# Ningún anuncio cruza entre VRFs porque tienen Route Targets distintos.
set -e
echo ">>> [client-a] intenta llegar a client-d (DEBE FALLAR)"
docker exec clab-evpn-ixp-lab-client-a ping -W 2 -c 2 172.16.100.40 || echo "[OK] sin alcanzabilidad entre tenants"
echo
echo ">>> [leaf3] Rutas en tenant-A"
docker exec clab-evpn-ixp-lab-leaf3 vtysh -c "show ip route vrf tenant-A"
echo
echo ">>> [leaf3] Rutas en tenant-B (otro mundo)"
docker exec clab-evpn-ixp-lab-leaf3 vtysh -c "show ip route vrf tenant-B"
echo
echo ">>> [leaf1] Route Distinguishers / Route Targets por VRF"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn vni"
