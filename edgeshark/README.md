# Edgeshark — "Wireshark remoto" para el lab

[Edgeshark](https://github.com/siemens/edgeshark) (de Siemens) es un stack
de contenedores que descubre todas las interfaces de red de containers en el
host y deja capturar tráfico desde una UI web — o directamente desde tu
Wireshark local con un plugin extcap.

Lo usamos para la presentación de LACNIC 45 / FTL para mostrar tráfico
del lab containerlab en vivo, capturando desde Panamá un lab que corre en
Argentina.

---

## ¿Por qué este stack y no otro?

- **Es lo más cercano a "Wireshark nativo" en una demo remota.** El streaming
  pcap viaja por websocket y tolera bien la latencia intercontinental.
- **No requiere tocar el `topology.clab.yml`.** Edgeshark se levanta como
  stack aparte y descubre los containers de containerlab via el daemon de
  Docker del host.
- **No requiere reiniciar los containers del lab para capturar.** La captura
  se inicia/detiene en caliente.
- **Tolera cortes de red.** Si se cae el túnel mientras estás capturando,
  Wireshark muestra lo capturado hasta el momento; reabrís la sesión y seguís.

Está mantenido por Siemens y se demostró en SharkFest 2023.

---

## Topología del setup

```
   [Panamá]                              [Argentina, 198.19.1.81]
   .........                             ......................................
   :       :   HTTPS (443)               :                                    :
   :  Vos  :  ─────────────────────►  Cloudflare Tunnel                       :
   :       :  via Cloudflare              │                                   :
   :.......:                              │ proxy local                       :
                                          ▼                                   :
                              127.0.0.1:19831 (loopback)                      :
                                          │                                   :
                                          ▼                                   :
                                  ┌──────────────────┐                        :
                                  │  edgeshark UI    │  ◄── descubre ──┐      :
                                  │  + packetflix    │                 │      :
                                  └────────┬─────────┘                 │      :
                                           │                           │      :
                                  ┌────────▼─────────┐         /var/run/      :
                                  │     gostwire     │         docker.sock    :
                                  │   (discovery)    │                 │      :
                                  └────────┬─────────┘                 │      :
                                           │                           │      :
                                           ▼                           ▼      :
                                  containers del lab containerlab             :
                                  (clab-evpn-ixp-lab-spine1, leaf1, ...)      :
                                  ..............................................
```

---

## Levantar el stack

Pre-requisitos en el server del lab:
- Docker ≥ 24 con plugin compose v2 (lo mismo que necesita containerlab).
- Kernel ≥ 5.6 (lo mismo que necesita el lab).

```bash
cd lab/edgeshark
cp env.example .env        # editá EDGESHARK_PORT si querés otro puerto
docker compose up -d
docker compose ps          # gostwire y edgeshark deberían estar 'running'
```

Verificar que escucha en loopback:

```bash
ss -tlnp | grep 19831      # debe figurar 127.0.0.1:19831
```

Probar la UI localmente (con `ssh -L` si estás afuera del server):

```bash
ssh -L 19831:127.0.0.1:19831 root@198.19.1.81
# en otra terminal local: open http://127.0.0.1:19831
```

---

## Acceso desde Panamá (Cloudflare Tunnel)

El stack escucha SOLO en `127.0.0.1:19831`. Configurá Cloudflare Tunnel a mano
con algo del tipo:

```yaml
# ~/.cloudflared/config.yml (en el server del lab)
tunnel: <tunnel-uuid>
credentials-file: /root/.cloudflared/<tunnel-uuid>.json

ingress:
  - hostname: edgeshark.tudominio.com
    service: http://127.0.0.1:19831
    originRequest:
      noTLSVerify: true
      # IMPORTANTE: websockets habilitados (default en cloudflared moderno).
  - service: http_status:404
```

Edgeshark usa **websockets** para el streaming. Cloudflare los soporta
nativamente; no requiere config extra.

> Tip: protegé el hostname con Cloudflare Access (email/Google) antes del
> evento. No exposés un capturador raw a internet sin auth.

---

## Capturar tráfico

### Opción A — desde el navegador (más simple)

1. Abrís `https://edgeshark.tudominio.com` (o el localhost si estás tunelizando
   por SSH).
2. La UI lista todos los containers del host. Buscás los `clab-evpn-ixp-lab-*`.
3. Clic en el container (ej. `clab-evpn-ixp-lab-leaf1`) → ves sus interfaces.
4. Clic en el icono 🦈 al lado de la interfaz que querés capturar.
5. Te ofrece descargar un `.pcap` o abrirlo en Wireshark si tenés el plugin.

### Opción B — desde tu Wireshark local (recomendado para demo)

1. **Una vez**, instalá el plugin
   [`cshargextcap`](https://github.com/siemens/cshargextcap/releases) en tu
   máquina (Mac/Windows/Linux). Es un extcap, no toca Wireshark mismo.
2. En la UI web, clic en el icono 🦈 al lado de la interfaz.
3. El navegador dispara un handler `packetflix://...` → Wireshark se abre
   capturando esa interfaz en vivo.

Para macOS hay un paso extra (registrar el URL handler) descrito en el
[README de cshargextcap](https://github.com/siemens/cshargextcap?tab=readme-ov-file#installation).

---

## Interfaces clave para la demo EVPN/VXLAN

Mapeo rápido de qué interfaz mirar según el script de la charla de Ariel Weher:

| Script                          | Container                  | Interfaz       | Qué vas a ver                          |
| ------------------------------- | -------------------------- | -------------- | -------------------------------------- |
| `01-underlay.sh`                | `clab-evpn-ixp-lab-leaf1`  | `eth1`, `eth2` | BGP unnumbered, tráfico de control     |
| `02-evpn-type2-type3.sh`        | `clab-evpn-ixp-lab-leaf1`  | `eth1`         | BGP EVPN updates, Type-2 y Type-3      |
| `07-vxlan-capture.sh`           | `clab-evpn-ixp-lab-leaf1`  | `eth1` o `eth2`| **UDP/4789** (VXLAN) — el "idioma"    |
| `05-mh-esi-lag.sh`              | `clab-evpn-ixp-lab-leaf2`  | `eth4`         | LACP + tráfico de cliente multi-homed  |
| `06-peering-inter-asn.sh`       | `clab-evpn-ixp-lab-client-a` | `eth1`       | BGP entre clientes (lo que ve el peer) |

Sugerencia para el escenario: dejá Wireshark pre-abierto en `eth1` de `leaf1`
con filtro `udp.port == 4789 or bgp`, y cuando corras `07-vxlan-capture.sh`
mostrás el frame encapsulado en vivo.

---

## Troubleshooting

**La UI no descubre los containers del lab.**
- Verificá que `gostwire` tenga acceso al socket de docker. El compose
  pone `pid: host` + las caps necesarias; si modificaste algo, restaurá.

**Los iconos 🦈 no aparecen en las interfaces.**
- Suele ser que `packetflix` no levantó. `docker compose logs edgeshark`.

**Wireshark no abre al clickear el shark.**
- Plugin `cshargextcap` no instalado o, en macOS, falta el handler de URL.
- Como workaround, usá la opción A (descarga `.pcap`).

**No veo tráfico, la interfaz está "vacía".**
- En containerlab, el tráfico de control (BGP unnumbered, EVPN) corre sobre
  las interfaces `ethN` de cada nodo. Si capturás en `lo` o `mgmt` no vas a
  ver el underlay.
- Tip: corré simultáneamente algún script (ej. `02-evpn-type2-type3.sh`) para
  generar movimiento.

**Cloudflare devuelve 502 / la captura se corta a los pocos segundos.**
- Asegurate que el tunnel permite websockets (default en versiones recientes).
- Aumentá el timeout de conexión idle si tu plan de Cloudflare lo permite.

---

## Bajar el stack

```bash
cd lab/edgeshark
docker compose down
```

No afecta a containerlab ni al lab. Podés levantar/bajar Edgeshark
independientemente del lab.

---

## Plan B si Edgeshark falla en escenario

El README principal del lab tiene la sección "Plan B" con outputs
pre-capturados y `.pcap` listos para Wireshark local. Si Edgeshark se
cuelga en mitad de demo, abrís el `.pcap` y seguís sin que se note.

---

## Referencias

- [Edgeshark Hub](https://github.com/siemens/edgeshark)
- [Manual online](https://siemens.github.io/edgeshark)
- [cshargextcap (plugin Wireshark)](https://github.com/siemens/cshargextcap)
- [Charla SharkFest 2023](https://www.youtube.com/watch?v=53dUH6cZ9rc)
