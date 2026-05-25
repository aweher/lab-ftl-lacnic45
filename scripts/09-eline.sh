#!/bin/bash
# Demo 9: Servicio L2 punto a punto (E-Line) sobre un VNI dedicado
# client-e (sede A, leaf1) y client-f (sede B, leaf2) viven en el VNI 10300,
# un L2VNI dedicado SIN gateway: el fabric los une como si fuera un cable directo.
#
# Es el equivalente a un E-Line/EVPN-VPWS pero en EVPN-VXLAN puro (lo que FRR
# soporta nativamente). El VNI 10300 solo tiene esos dos puertos de acceso.
# ---------------------------------------------------------------------------
set -e

echo ">>> [leaf1] VNI 10300 dedicado (L2, sin SVI/gateway)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni 10300" | head -8
echo

echo ">>> [leaf1] MACs del VNI 10300 (local en eth5 + remota via VTEP de leaf2)"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn mac vni 10300"
echo

echo ">>> [client-e] ping a client-f (203.0.113.2) por el E-Line"
docker exec clab-evpn-ixp-lab-client-e ping -c 3 -W 2 203.0.113.2 || true
echo

echo ">>> El VNI 10300 NO toca a los demas tenants: es un servicio aislado."
