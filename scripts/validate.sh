#!/bin/bash
# =============================================================================
# validate.sh - corre toda la secuencia de validación y la deja en un log
# Uso:
#   cd lab/
#   ./scripts/validate.sh 2>&1 | tee validate.log
# =============================================================================
set +e   # no abortar si una demo falla, queremos verlo todo

cd "$(dirname "$0")/.."
LAB_DIR="$(pwd)"
LOG="/tmp/lab/validate.log"

banner () { echo; echo "============================================================"; echo "== $1"; echo "============================================================"; }

banner "0. Entorno"
hostname
uname -a
docker --version
containerlab version 2>&1 | head -3

banner "1. Deploy del lab"
sudo containerlab deploy -t "$LAB_DIR/topology.clab.yml"

banner "2. Esperando 25s para que BGP/EVPN convergan"
sleep 25

banner "3. Estado de los contenedores"
sudo containerlab inspect -t "$LAB_DIR/topology.clab.yml"

banner "4. Demo 01 - Underlay"
"$LAB_DIR/scripts/01-underlay.sh"

banner "5. Demo 02 - EVPN Type-2/Type-3"
"$LAB_DIR/scripts/02-evpn-type2-type3.sh"

banner "6. Demo 03 - Type-5 + Anycast GW"
"$LAB_DIR/scripts/03-evpn-type5-anycast.sh"

banner "7. Demo 04 - Multi-tenancy"
"$LAB_DIR/scripts/04-multitenancy.sh"

banner "8. Demo 05 - MH / ESI-LAG"
"$LAB_DIR/scripts/05-mh-esi-lag.sh"

banner "9. Demo 06 - Peering inter-ASN"
"$LAB_DIR/scripts/06-peering-inter-asn.sh"

banner "10. Demo 07 - Captura VXLAN"
"$LAB_DIR/scripts/07-vxlan-capture.sh"

banner "11. Demo 08 - Hardening underlay y BGP"
"$LAB_DIR/scripts/08-hardening.sh"

banner "12. Demo 09 - E-Line (VNI 10300 punto a punto)"
"$LAB_DIR/scripts/09-eline.sh"

banner "13. Estado final - todas las VNIs vistas desde leaf1"
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni detail" 2>&1 | head -80

banner "FIN. Para destruir el lab: ./scripts/down.sh"
