#!/bin/bash
# Demo 6: Peering entre ASNs sobre el fabric EVPN (caso IXP)
# Los clientes (cada uno con su ASN) hacen eBGP entre sí en la VLAN Peering
# 100.64.0.0/24 que está estirada por EVPN/VXLAN.
# Punto fuerte: el fabric NO ve los anuncios BGP de los clientes - solo
# transporta L2 entre ellos. Es el mismo paradigma que la LAN del IXP,
# pero ahora la LAN está distribuida en N leafs.
set -e
echo ">>> [client-a] sesiones eBGP a sus pares en el IXP"
docker exec clab-evpn-ixp-lab-client-a vtysh -c "show bgp summary"
echo
echo ">>> [client-a] tabla BGP (debería ver loopbacks de B y C)"
docker exec clab-evpn-ixp-lab-client-a vtysh -c "show ip bgp"
echo
echo ">>> [client-a] traceroute al loopback de client-b"
docker exec clab-evpn-ixp-lab-client-a traceroute -n 192.0.2.20 || true
echo
echo ">>> [leaf1] BGP NO ve los prefijos de clientes (porque va por L2)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp ipv4 unicast" | head -20
