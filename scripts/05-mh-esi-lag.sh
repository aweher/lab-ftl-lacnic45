#!/bin/bash
# Demo 5: Multi-Homing all-active (ESI-LAG) y failover
# client-c está conectado por LACP a leaf2 + leaf3.
# Vamos a mostrar:
#   1) Que el MAC de client-c se anuncia con un ESI no-cero (Type-1 + Type-2).
#   2) Que tirar el link a leaf2 NO interrumpe el tráfico (queda por leaf3).
#
# ---------------------------------------------------------------------------
# COOLDOWN: este script es "destructivo" para el lab — tira un link y lo sube.
# Ejecutarlo dos veces seguidas sin dejarle al fabric tiempo de re-converger
# puede dejar a bgpd o LACP en un estado raro. Si se ejecuta muy rápido,
# el script aborta e indica cuánto falta para poder correrlo de nuevo.
#
# Variables configurables:
#   COOLDOWN     - segundos mínimos entre ejecuciones (default 60)
#   FORCE=1      - saltea el cooldown
# ---------------------------------------------------------------------------
set -e

COOLDOWN="${COOLDOWN:-60}"
LOCK="/tmp/clab-evpn-ixp-mh-esi-lag.lock"

if [ "${FORCE:-0}" != "1" ] && [ -f "$LOCK" ]; then
  LAST_RUN=$(cat "$LOCK" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  ELAPSED=$(( NOW - LAST_RUN ))
  if [ "$ELAPSED" -lt "$COOLDOWN" ]; then
    REMAINING=$(( COOLDOWN - ELAPSED ))
    cat <<EOF >&2
[!] Este script se ejecutó hace ${ELAPSED}s. Necesita ${COOLDOWN}s entre corridas
    para que LACP, EVPN y FRR re-converjan limpiamente.

    Esperá ${REMAINING}s más antes de volver a correrlo, o exportá FORCE=1
    si estás seguro (puede dejar al lab en un estado inconsistente).

    Si el lab ya quedó raro, lo más rápido es:
        ./scripts/down.sh && ./scripts/up.sh
EOF
    exit 2
  fi
fi

# Marco que estamos por correr -- aunque el script falle, contamos como "se corrió"
date +%s > "$LOCK"
trap 'date +%s > "$LOCK"' EXIT

echo ">>> [leaf2] ESIs locales"
docker exec clab-evpn-ixp-lab-leaf2 vtysh -c "show evpn es"
echo
echo ">>> [leaf2] EVPN Type-1 (ES auto-discovery) recibidas"
docker exec clab-evpn-ixp-lab-leaf2 vtysh -c "show bgp l2vpn evpn route type ead"
echo
echo ">>> [client-a] ping continuo a client-c en background"
docker exec -d clab-evpn-ixp-lab-client-a sh -c 'ping -i 0.2 100.64.0.30 > /tmp/ping.log 2>&1'
sleep 2
echo ">>> Tirando el link client-c <-> leaf2 ..."
docker exec clab-evpn-ixp-lab-leaf2 ip link set eth4 down
sleep 5
echo ">>> Restaurando ..."
docker exec clab-evpn-ixp-lab-leaf2 ip link set eth4 up
sleep 2
# El ping de la imagen FRR es busybox: SOLO imprime la línea de resumen
# ("N packets transmitted, ... loss") si se lo termina con SIGINT, no con un
# kill brusco. Por eso usamos kill -INT en vez de "pkill ping".
docker exec clab-evpn-ixp-lab-client-a sh -c 'kill -INT $(pgrep -f "ping -i") 2>/dev/null' || true
sleep 1
echo
echo ">>> Resultado del failover (busybox ping usa 'seq=', no 'icmp_seq'):"
# Resumen de pérdida que imprime busybox al recibir SIGINT.
docker exec clab-evpn-ixp-lab-client-a grep -E "packets transmitted" /tmp/ping.log | tail -1
# Cálculo explícito de paquetes perdidos a partir de los seq= del log: si el
# all-active funciona, el tráfico nunca se corta y la pérdida es 0.
docker exec clab-evpn-ixp-lab-client-a sh -c '
  seqs=$(grep -oE "seq=[0-9]+" /tmp/ping.log | sed "s/seq=//" | sort -n)
  [ -z "$seqs" ] && { echo "(sin datos de ping)"; exit 0; }
  first=$(echo "$seqs" | head -1)
  last=$(echo "$seqs" | tail -1)
  got=$(echo "$seqs" | wc -l)
  expected=$(( last - first + 1 ))
  lost=$(( expected - got ))
  echo ">>> Pérdida durante el failover: ${lost} de ${expected} paquetes (${got} recibidos, seq ${first}..${last})"
  if [ "$lost" -le 1 ]; then
    echo ">>> all-active OK: el tráfico siguió por leaf3, failover sub-segundo."
  else
    echo ">>> Se perdieron ${lost} paquetes durante la reconvergencia."
  fi
'
echo
echo "[i] OK. Cooldown de ${COOLDOWN}s antes de poder correr este script de nuevo."
