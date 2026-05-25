# Lab: EVPN & VXLAN — *El nuevo idioma del peering moderno*

> Material abierto desarrollado por **[Ayuda.LA](https://ayuda.la)** y compartido con la comunidad de networking de América Latina y el Caribe.
> Presentado en el **Foro Técnico Latinoamericano (FTL)** de [LACNIC 45](https://lacnic.net/lacnic45) — Panamá, mayo .
> Contribución al ecosistema de **[LACNOG](https://nog.lat)**.

---

Escenario containerlab completamente funcional y reproducible, diseñado para que cualquier operador de la región pueda experimentar con EVPN/VXLAN en un entorno seguro sin hardware dedicado. Todo el plano de control y datos se construye sobre **FRR 10.2.1** corriendo en contenedores Linux.

---

## 1. Topología (IXP-style)

```
             +---------+           +---------+
             | spine1  |           | spine2  |
             | AS65001 |           | AS65002 |
             +----+----+           +----+----+
                  |                      |
        +---------+----------+-----------+---------+
        |                    |                     |
   +----+----+          +----+----+          +----+----+
   |  leaf1  |          |  leaf2  |          |  leaf3  |
   | AS65011 |          | AS65012 |          | AS65013 |
   | VTEP .11|          | VTEP .12|          | VTEP .13|
   +--+-+----+          +---+--+--+          +--+--+---+
      | |                   |    \          /    |
      | |               client-b   client-c   client-d
      | |               AS 64602   AS 64603   AS 64604
      | |               (single)  (ESI-LAG)  (tenant-B)
      | |
      | +--- client-e (E-Line, VNI 10300)
      +--- client-a (AS 64601, single)

              leaf2:eth5 --- client-f (E-Line, VNI 10300)
```

**6 nodos cliente** — todos corren FRR y hacen eBGP real contra sus pares o contra el fabric.

### Underlay

eBGP unnumbered entre spines y leafs (IPv6 link-local, extended nexthop IPv4). Los spines son **route reflectors** para `l2vpn evpn`.

### Overlay

EVPN sobre VXLAN, MAC-VRF + IP-VRF.


| VNI   | Tipo | Función                                             | VRF      |
| ----- | ---- | --------------------------------------------------- | -------- |
| 10100 | L2   | "VLAN Peering" del IXP (client-a/b/c)               | tenant-A |
| 10200 | L2   | Mgmt interna del IXP (multi-tenant demo)            | tenant-A |
| 20100 | L2   | LAN del tenant-B (client-d)                         | tenant-B |
| 5000  | L3   | IP-VRF tenant-A (Type-5 + anycast GW 100.64.0.1)    | tenant-A |
| 5001  | L3   | IP-VRF tenant-B (Type-5, aislado de A)              | tenant-B |
| 10300 | L2   | E-Line dedicado punto a punto (client-e ↔ client-f) | default  |


### Anycast Gateway

Los SVIs `br10100` en leaf1/leaf2/leaf3 tienen **la misma IP y el mismo MAC** (`44:38:39:ff:00:64`). Para los clientes hay un solo default GW, sin importar a qué leaf estén conectados.

### E-Line (VNI 10300)

Servicio L2 punto a punto entre dos sedes de un cliente (client-e en leaf1, client-f en leaf2), sin gateway. Equivale a un E-Line/EVPN-VPWS pero en EVPN-VXLAN puro. El VNI solo tiene esos dos puertos de acceso.

### Hardening del underlay

El peer-group `FABRIC` corre con:

- **BFD** (profile FABRIC, 150 ms × 3 = detección sub-segundo)
- **GTSM** (`ttl-security hops 1`, RFC 5082)
- `**maximum-prefix 5000`** en la address-family EVPN
- `**no bgp default ipv4-unicast`** (mínimo privilegio)

En producción sumar: TCP-AO (RFC 5925) y CoPP/lpts.

---

## 2. Requisitos

- Linux con kernel ≥ 5.10 (soporte VRF + EVPN MH).
- Docker ≥ 24.
- [containerlab](https://containerlab.dev) ≥ 0.55.
- Recursos: ~4 GB RAM y 2 vCPUs alcanzan.
- (Opcional) [gum](https://github.com/charmbracelet/gum) para la TUI interactiva (`run.sh`).

Los configs no modifican nada fuera del directorio `lab/`.

---

## 3. Levantar / bajar el lab

### Opción A: TUI interactiva

```bash
./run.sh
```

Menú con `gum` que ofrece deploy, destroy, correr demos, abrir vtysh en cualquier nodo y más. Instala `gum` automáticamente si no está presente.

### Opción B: Scripts directos

```bash
./scripts/up.sh          # containerlab deploy
# ... demos ...
./scripts/down.sh        # containerlab destroy --cleanup
```

### Validación completa

```bash
./scripts/validate.sh 2>&1 | tee validate.log
```

Levanta el lab, espera convergencia y corre las 9 demos secuencialmente. Útil para validar el entorno de punta a punta.

---

Para entrar a la CLI de FRR en cualquier nodo:

```bash
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh
```

---

## 4. Scripts de demo

Los scripts de `scripts/` están numerados en el orden lógico de la charla:


| #   | Script                     | Qué demuestra                                          |
| --- | -------------------------- | ------------------------------------------------------ |
| 01  | `01-underlay.sh`           | BGP unnumbered, vecindarios vía interfaz, loopbacks    |
| 02  | `02-evpn-type2-type3.sh`   | Type-2 (MAC/IP) y Type-3 (IMET) por VNI                |
| 03  | `03-evpn-type5-anycast.sh` | Routing simétrico L3 (Type-5) + anycast gateway        |
| 04  | `04-multitenancy.sh`       | Aislamiento entre VRFs (tenant-A vs tenant-B)          |
| 05  | `05-mh-esi-lag.sh`         | Multi-Homing ESI-LAG all-active + failover sin STP     |
| 06  | `06-peering-inter-asn.sh`  | Peering eBGP entre clientes sobre el fabric (caso IXP) |
| 07  | `07-vxlan-capture.sh`      | Captura VXLAN UDP/4789 en el cable                     |
| 08  | `08-hardening.sh`          | BFD, GTSM, maximum-prefix, minimum-privilege           |
| 09  | `09-eline.sh`              | Servicio L2 punto a punto (E-Line, VNI 10300)          |


---

## 5. Mapeo scripts ↔ slides de la charla


| Módulo de la charla             | Scripts                                                    |
| ------------------------------- | ---------------------------------------------------------- |
| 1 · Por qué evolucionar         | (contexto, mostrar topología)                              |
| 2 · Qué aportan EVPN/VXLAN      | `01-underlay`, `07-vxlan-capture`                          |
| 3 · Arquitecturas típicas       | `02-evpn-type2-type3`, `03-evpn-type5-anycast`             |
| 4 · Casos de uso                | `04-multitenancy`, `05-mh-esi-lag`, `06-peering-inter-asn` |
| 5 · IXP virtual + E-Line        | `06-peering-inter-asn`, `09-eline`                         |
| 6 · Hardening y recomendaciones | `08-hardening`                                             |


---

## 6. Comandos útiles

```bash
# Todas las VNIs activas en un leaf
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni detail"

# MACs aprendidas por overlay
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn mac vni all"

# Ethernet Segments y quién es DF
docker exec -it clab-evpn-ixp-lab-leaf2 vtysh -c "show evpn es detail"

# Ruta Type-5 puntual
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn route type prefix"

# VTEP remoto descubierto
docker exec -it clab-evpn-ixp-lab-leaf1 bridge fdb show dev vni10100 | grep dst

# BFD peers activos
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh -c "show bfd peers"
```

---

## 7. Captura en vivo con Edgeshark

Para mostrar tráfico desde otra ubicación geográfica (ej: charla en Panamá, lab en Argentina), levantamos [Edgeshark](https://github.com/siemens/edgeshark):

```bash
cd edgeshark
cp env.example .env        # ajustar puerto si es necesario
docker compose up -d
```

Por defecto escucha en `127.0.0.1:19831`. Exponerlo a internet requiere un túnel (ngrok, Cloudflare Tunnel, etc.). Detalles en `[edgeshark/README.md](./edgeshark/README.md)`.

---

## 8. Estructura del directorio

```
lab/
├── topology.clab.yml            # topología containerlab (6 clientes, 3 leafs, 2 spines)
├── run.sh                       # TUI interactiva (gum) — ciclo de vida completo
├── README.md
├── SCRIPTS_GUIDE.md             # guía detallada de cada script
├── .gitignore
├── configs/
│   ├── _common/                 # daemons y vtysh.conf compartidos
│   ├── spine1/  spine2/         # configs FRR de spines
│   ├── leaf1/  leaf2/  leaf3/   # configs FRR + init.sh de leafs
│   ├── client-a/ ... client-d/  # configs FRR + init.sh de clientes BGP
│   └── client-e/  client-f/     # init.sh para E-Line (sin FRR config)
├── scripts/
│   ├── up.sh / down.sh          # deploy / destroy
│   ├── validate.sh              # corre todo secuencialmente (CI / pre-charla)
│   ├── 01-underlay.sh
│   ├── 02-evpn-type2-type3.sh
│   ├── 03-evpn-type5-anycast.sh
│   ├── 04-multitenancy.sh
│   ├── 05-mh-esi-lag.sh
│   ├── 06-peering-inter-asn.sh
│   ├── 07-vxlan-capture.sh
│   ├── 08-hardening.sh
│   └── 09-eline.sh
└── edgeshark/                   # Wireshark remoto para la demo
    ├── docker-compose.yml
    ├── env.example
    └── README.md
```

---

## Licencia y atribución

Este laboratorio es un aporte de **[Ayuda.LA](https://ayuda.la)** a la comunidad de operadores de redes de América Latina y el Caribe, en el marco de las actividades de **[LACNOG](https://nog.lat)**.

Fue presentado originalmente en el **Foro Técnico Latinoamericano (FTL)** durante [LACNIC 45](https://lacnic.net/lacnic45).

Usalo, adaptalo y compartilo. Si te sirvió, contanos en los canales de LACNOG.