#!/bin/bash
# Demo 8: Hardening del underlay y BGP
# Muestra las protecciones que trae el fabric en el peer-group FABRIC:
#   - BFD profile FABRIC con timers agresivos (150ms x3 = deteccion sub-segundo)
#   - GTSM / ttl-security hops 1 (RFC 5082): solo acepta BGP a 1 salto (TTL=255)
#   - maximum-prefix 5000: contiene el blast radius de un leaf comprometido
#   - no bgp default ipv4-unicast: minimo privilegio en las address-families
#
# Nada de esto interrumpe el fabric: son protecciones del plano de control.
# ---------------------------------------------------------------------------
set -e

echo ">>> [leaf1] Config del peer-group FABRIC (hardening aplicado)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show running-config" \
  | grep -E "neighbor FABRIC (bfd|ttl-security|maximum-prefix)|no bgp default"
echo

echo ">>> [leaf1] BFD: timers 150ms x3 (deteccion sub-segundo)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bfd peers" \
  | grep -iE "Status:|interval|multiplier" | head -6
echo

echo ">>> [leaf1] Sesiones BGP estables pese al hardening"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn summary" \
  | grep -E "spine|Total"
echo

echo ">>> En produccion agregar: TCP-AO (RFC 5925) y CoPP/lpts."
echo ">>> EVPN no endurece el underlay solo: el hardening es trabajo aparte."
