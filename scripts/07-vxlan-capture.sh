#!/bin/bash
# Demo 7: Mirar el "idioma" en el cable
# Capturamos UDP/4789 (VXLAN) en el VTEP de origen (leaf1) y disparamos un ping
# desde client-a para que se vea el frame encapsulado.
#
# ¿Por qué capturamos en leaf1 y no en un spine?
#   - El tráfico de datos VXLAN va VTEP->VTEP (leaf1->leaf2). El camino por el
#     underlay es ECMP: el flujo puede salir por la uplink hacia spine1 O hacia
#     spine2 según el hash. Capturar fijo en "spine1 eth1" sale vacío si el flujo
#     eligió el otro spine.
#   - Capturando en leaf1 con "-i any" vemos el encapsulado salga por la uplink
#     que salga (eth1 o eth2). Es a prueba de ECMP y además muestra la dirección
#     (Out/In) de cada paquete.
set -e

LEAF=clab-evpn-ixp-lab-leaf1

# La imagen FRR (Alpine) no trae tcpdump de fábrica. Lo instalamos on-demand
# dentro del contenedor la primera vez (apk, repos de Alpine). Idempotente:
# si ya está, no hace nada.
if ! docker exec "${LEAF}" sh -c 'command -v tcpdump' >/dev/null 2>&1; then
  echo ">>> tcpdump no está en ${LEAF}, instalándolo (apk add tcpdump)..."
  docker exec "${LEAF}" sh -c 'apk add --no-cache tcpdump' >/dev/null 2>&1 \
    || { echo "ERROR: no se pudo instalar tcpdump en ${LEAF}"; exit 1; }
fi

echo ">>> tcpdump VXLAN (UDP/4789) en leaf1 (VTEP origen, -i any), 10 paquetes"
docker exec -d "${LEAF}" sh -c 'tcpdump -i any -nn -e -c 10 "udp port 4789" > /tmp/vxlan.pcap 2>&1'
sleep 1
docker exec clab-evpn-ixp-lab-client-a ping -c 6 100.64.0.20 >/dev/null
sleep 2
docker exec "${LEAF}" cat /tmp/vxlan.pcap
