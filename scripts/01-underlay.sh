#!/bin/bash
# Demo 1: Underlay BGP unnumbered (slide "Por qué evolucionar el peering")
# Mostrar: spines y leafs se descubren v6-LL y arman eBGP IPv4 sin direccionar p2p.
set -e
echo ">>> [spine1] BGP summary"
docker exec clab-evpn-ixp-lab-spine1 vtysh -c "show bgp summary"
echo
echo ">>> [leaf1] BGP summary (mira que el peer es 'eth1' no una IP)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp summary"
echo
echo ">>> [leaf1] Loopbacks aprendidas por underlay"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show ip route bgp"
