# Guía detallada de los scripts del lab

Cada uno de los scripts que viven en `lab/scripts/` está pensado para ser corrido en orden durante la charla, mientras se va explicando un concepto. Pero si los corrés sueltos, sin contexto, te perdés la mitad de lo interesante. Esta guía es para entender **qué pasa por dentro** en cada uno, qué línea hace qué, qué tenés que mirar en pantalla, y qué cosas se rompen cuando se rompen.

No es la documentación oficial de FRR, ni la del RFC 7432, ni la del 8365. Es lo que me hubiera gustado tener al lado mío la primera vez que armé un lab de EVPN/VXLAN. Si llegaste acá sin haber leído el [README](./README.md), empezá por ahí — esta guía asume que ya entendiste la topología.

---

## Convención común a todos los scripts

Todos los scripts hacen `docker exec` contra los contenedores que levantó containerlab. Los nombres siguen el patrón `clab-<labname>-<nodename>`, en nuestro caso `clab-evpn-ixp-lab-leaf1`, `clab-evpn-ixp-lab-client-a`, etc. Si alguna vez tenés que ejecutar algo a mano sin acordarte del nombre, `sudo containerlab inspect -t topology.clab.yml` te lo tira.

Dentro de cada contenedor FRR, todo se interactúa por `vtysh`. Es el shell unificado de FRR, equivalente al IOS de Cisco. Acepta los mismos comandos que cargás en el `frr.conf`.

```bash
# Para entrar interactivo a un nodo
docker exec -it clab-evpn-ixp-lab-leaf1 vtysh

# Para ejecutar un comando único
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp summary"
```

---

## Script 01 — `01-underlay.sh` — Underlay BGP unnumbered

### Qué hace

Te muestra el plano de control de **abajo de todo**: cómo los spines y los leafs se ven entre sí en IP, sin VXLAN ni EVPN todavía. Esto es lo que un operador de red tradicional debería reconocer al primer vistazo: es **BGP IPv4 plano**, sin OSPF, sin IS-IS, sin nada más.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-spine1 vtysh -c "show bgp summary"
```

Le pide a spine1 el resumen de todas sus sesiones BGP. Sin la familia EVPN todavía — eso lo vemos en el script 02.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp summary"
```

Lo mismo desde un leaf. El detalle clave: el comentario del script dice **"mira que el peer es 'eth1' no una IP"**.

### Qué tenés que mirar en pantalla

Cuando aparezca la tabla de neighbors, no busques una IP del lado peer. Vas a ver algo así:

```
Neighbor        V         AS   MsgRcvd   MsgSent   ...   State/PfxRcd
leaf1(eth1)     4      65011        45        50   ...             3
leaf2(eth2)     4      65012        47        50   ...             3
leaf3(eth3)     4      65013        46        50   ...             3
```

El peer es **una interfaz**, no una IP. Esto es **BGP unnumbered**. ¿Cómo funciona? FRR usa **IPv6 link-local** (las direcciones `fe80::...` que aparecen solas cuando levantás una interfaz) para establecer la sesión TCP, y dentro de esa sesión negocia la `capability extended-nexthop` para poder anunciar prefijos IPv4 con next-hop IPv6. Resultado: **cero direccionamiento punto a punto que mantener**.

### ¿Por qué es relevante?

*"en el peering moderno, el underlay desaparece de la conversación"*. No hay subnets /30 ni /31, no hay un script de IPAM para los enlaces internos, no hay un mapa de IPs que mantener. El día que agregás un leaf nuevo, lo enchufás y arranca.

### Errores comunes

- **No ver loopbacks aprendidas:** `show ip route bgp` devuelve vacío. Eso suele ser porque el `redistribute connected` no está, o porque el peer-group no tiene `activate` en la familia IPv4. Mirá `frr.conf` del spine afectado.
- **BGP up pero EVPN no:** las sesiones IPv4 aparecen "Established" pero `show bgp l2vpn evpn summary` está vacío. Falta `neighbor FABRIC activate` dentro de `address-family l2vpn evpn`.

---

## Script 02 — `02-evpn-type2-type3.sh` — Los tipos de ruta EVPN

### Qué hace

Acá entra en escena lo que diferencia a EVPN de cualquier solución L2 anterior: **las MACs se anuncian por BGP**, no se aprenden por flooding. Este script te lo demuestra.

Antes de los comandos hace un ping de client-a a client-b. Ese ping fuerza que client-a tenga que aprender el MAC de client-b. Como están en leafs distintos (leaf1 y leaf2), ese aprendizaje **viaja por BGP EVPN**, no por flooding hacia un switch central.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-client-a ping -c 3 100.64.0.20
```

Tres pings de client-a (.10) a client-b (.20). Si el lab está sano, te tienen que dar latencias sub-millisegundo. Si ves más de 1ms, algo está mal.

```bash
docker exec clab-evpn-ixp-lab-leaf1 bridge fdb show br br10100 | grep -v permanent | head -20
```

La tabla FDB del bridge `br10100` en leaf1. Acá vas a ver el MAC de client-a aprendido localmente en `eth3`, y el MAC de client-b **detrás del dispositivo VXLAN** apuntando al VTEP remoto (10.0.0.12). Esto es lo concreto: el bridge no se enteró del MAC remoto porque alguien le mandó un frame, se enteró porque **BGP se lo contó**.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn route vni 10100"
```

Las rutas EVPN que viven en el L2VNI 10100. Acá es donde se ve la magia. Cada entrada tiene un tipo:

- **Type-2 (MAC/IP advertisement):** un MAC (y opcionalmente su IP) anunciado por un VTEP. Esto es **el reemplazo directo del flood-and-learn**.
- **Type-3 (Inclusive Multicast Ethernet Tag):** uno por cada VTEP que tiene la VNI activa. Sirve para **BUM traffic** (Broadcast, Unknown unicast, Multicast). Si en algún momento aparece un broadcast en la VNI, se replica unicast a todos los VTEPs listados en los Type-3.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni"
```

Resumen de las VNIs activas. Te muestra cuántas MACs aprendió cada VNI, cuántos VTEPs remotos descubrió, y en qué VRF está encolada (cuando es L3VNI).

### Qué tenés que mirar en pantalla

Lo más vistoso es la salida de `show bgp l2vpn evpn route vni 10100`. Vas a ver líneas que arrancan con `[2]:...` (Type-2) y `[3]:...` (Type-3). El formato del prefijo Type-2 es:

```
[2]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]
```

Y la ruta trae el next-hop que es la **loopback del VTEP que originó el anuncio**. No la IP del cliente.

Esto es lo conceptual que tenés que vender: el cliente vive en `100.64.0.20`, pero en el **plano de control del fabric** lo que se anuncia es "el MAC `aa:bb:cc:dd:ee:ff` está detrás del VTEP `10.0.0.12`". La IP del cliente viaja **adentro** del anuncio del MAC, no es la clave del lookup.

### ¿Por qué es relevante?

EVPN convierte el aprendizaje L2 en **un problema de routing**. Y los problemas de routing los sabemos resolver hace 30 años con BGP. No hay loops, no hay STP, no hay flooding masivo cuando se cae un puerto.

### Errores comunes

- **`show bgp l2vpn evpn route vni 10100` vacío:** las VTEPs no se descubrieron entre sí. Mirá `show evpn vni 10100 detail` y verificá que aparezcan VTEPs remotos. Si no aparecen, los Type-3 no están llegando — chequeá la sesión EVPN con los spines.
- **MAC aprendido como "local" en dos leafs distintos:** alguien sin querer puso a un cliente single-homed en dos leafs sin ESI. Eso causa MAC flapping en EVPN (vas a ver el contador `Seq #`s subiendo solo).

---

## Script 03 — `03-evpn-type5-anycast.sh` — L3 simétrico y anycast gateway

### Qué hace

Acá pasamos del L2 al L3. Hasta el script 02, los clientes se hablaban dentro de la misma subnet (`100.64.0.0/24`). Ahora vamos a ver cómo **enrutar entre VNIs distintas** sin tener que mandar el tráfico a un firewall central o a un router único.

Dos cosas a la vez:

1. **Anycast Gateway**: el SVI `br10100` que actúa como default gateway tiene **la misma IP y la misma MAC en los tres leafs**. Para el cliente, hay un solo gateway en `100.64.0.1`. En realidad le contesta el leaf más cercano siempre.

2. **EVPN Type-5 + IRB simétrico**: los prefijos IP enrutados entre VRFs se anuncian como rutas Type-5 (IP Prefix). El leaf que recibe el paquete del cliente lo enruta localmente al L3VNI correcto, encapsula en VXLAN con el VNI L3, y manda al VTEP remoto. Eso es **simétrico**: enrutás en ingreso y en egreso (a diferencia del IRB asimétrico, donde el leaf de ingreso ruteaba y el de egreso solo bridgeaba).

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-leaf1 ip -d -br link show br10100
docker exec clab-evpn-ixp-lab-leaf2 ip -d -br link show br10100
docker exec clab-evpn-ixp-lab-leaf3 ip -d -br link show br10100
```

Te muestra el bridge `br10100` en los tres leafs. Lo importante es la columna del medio: la **MAC address**. Tienen que ser **idénticas** (`44:38:39:ff:00:64`). Esa es la magia del anycast: el cliente arpea el gateway y le contesta el primero que reciba el ARP. Como los tres leafs tienen el mismo MAC, **no importa cuál conteste**.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn route type prefix"
```

Las rutas Type-5 recibidas. El formato del prefijo es:

```
[5]:[EthTag]:[IPlen]:[IP]
```

Y la ruta trae como atributo extended community el `Router MAC` del VTEP destino — eso es lo que el leaf usa para reescribir la MAC del paquete antes de meterlo en el VXLAN del L3VNI.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show ip route vrf tenant-A"
```

La tabla de ruteo del VRF tenant-A. Acá vas a ver las connecteds locales y las recibidas vía EVPN (que aparecen como `B>` con la flag de external).

### Qué tenés que mirar en pantalla

La línea más vendedora es esta:

```
br10100 ... link/ether 44:38:39:ff:00:64
```

Aparece **igual** en los tres leafs. Cualquier ingeniero de red con experiencia mira eso y dice "eso debería romper todo, dos interfaces no pueden tener el mismo MAC en el mismo broadcast domain". Y vos contestás: *"el broadcast domain está estirado por EVPN, y EVPN sabe que el MAC anycast es local en todos los leafs, así que nunca lo anuncia como Type-2"*. Boom.

### ¿Por qué es relevante?

El anycast gateway elimina el problema del "default gateway lejos". En una red tradicional, si tu cliente está en el rack 5 y el gateway está en el core del datacenter, cada paquete enrutado va y vuelve por todo el fabric. Con anycast, el primer hop L3 es **el leaf donde está el cliente**. Latencia mínima, sin tromboning.

### Errores comunes

- **MAC distinto entre leafs:** el cliente va a ver MAC flapping en su tabla ARP. La causa: alguien se olvidó del `ip link set br10100 address 44:38:39:ff:00:64` en el `init.sh` de algún leaf.
- **Type-5 sin Router MAC:** el VRF no tiene un L3VNI asociado, o el `advertise ipv4 unicast` no está dentro del `router bgp <ASN> vrf <VRF> address-family l2vpn evpn`.

---

## Script 04 — `04-multitenancy.sh` — Multi-tenancy real con VRFs

### Qué hace

Demuestra que **dos clientes pueden vivir en el mismo hardware, en el mismo fabric, y no verse**. No por una ACL, no por un firewall — por **separación de tablas de ruteo** (VRFs) y separación de plano de control (Route Targets en BGP EVPN).

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-client-a ping -W 2 -c 2 172.16.100.40 || echo "[OK] sin alcanzabilidad entre tenants"
```

Ping de client-a (que vive en tenant-A, subnet 100.64.0.0/24) a client-d (que vive en tenant-B, subnet 172.16.100.0/24). **Tiene que fallar**. Si funciona, hay algo mal con los Route Targets.

```bash
docker exec clab-evpn-ixp-lab-leaf3 vtysh -c "show ip route vrf tenant-A"
docker exec clab-evpn-ixp-lab-leaf3 vtysh -c "show ip route vrf tenant-B"
```

Las dos tablas de ruteo del mismo leaf. Son **mundos distintos**. La 100.64.0.0/24 aparece en tenant-A y no en tenant-B. La 172.16.100.0/24 aparece en tenant-B y no en tenant-A.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn vni"
```

Te muestra los Route Distinguishers y Route Targets de cada VNI. Por default FRR genera `RD = <router-id>:<vni>` y `RT = <ASN>:<vni>` (formato `auto`). Lo importante es que **dos VNIs en VRFs distintos tienen RTs distintos**, así que un leaf que está en ambos VRFs **no importa los anuncios de un VRF al otro**.

### Qué tenés que mirar en pantalla

Lo primero es el ping fallando. Hacelo dramático: pausá un segundo después del "100% packet loss", mirá a la cámara, decí *"esto es lo que un IXP no puede hacer hoy con una LAN compartida"*.

Después mostrá las dos tablas de ruteo lado a lado. Lo conceptual que tenés que vender: **el mismo router, el mismo hardware, el mismo cable, dos mundos completamente aislados**.

### ¿Por qué es relevante?

Hoy un IXP típico tiene UNA LAN compartida. Todos los miembros están en el mismo broadcast domain. Si querés separar un grupo (servicios públicos vs. privados, peering distinto por región, etc.), tenés que armar **otra LAN física o virtual** con su propio switch o su propia VLAN, y mantenerla aparte.

Con EVPN, un IXP puede ofrecer **20 LANs separadas sobre el mismo fabric** sin pelear con spanning-tree, sin VLANs duplicadas, sin desplegar hardware nuevo. Cada cliente vive en su VRF, no se entera de los demás, y el operador mantiene un solo plano de control.

### Errores comunes

- **El ping funciona y no debería:** se mezclaron los Route Targets. Algún VRF está importando RTs del otro. Mirá `show bgp l2vpn evpn vni <vni>` y verificá los `Import RTs` / `Export RTs`.
- **Las tablas de ruteo están vacías en uno de los VRFs:** falta el `vni <l3vni>` dentro de la stanza `vrf <name>`, o falta el `router bgp <ASN> vrf <name>` con el `advertise ipv4 unicast`.

---

## Script 05 — `05-mh-esi-lag.sh` — Multi-homing all-active sin MLAG

### Qué hace

Este es el script más vistoso de toda la demo. Demuestra que un cliente puede estar conectado a **dos leafs distintos al mismo tiempo**, con **ambos links activos** (LACP all-active), sin spanning-tree, sin MLAG propietario, sin VPC, sin nada. Y si se cae un link, el tráfico no se entera.

### Por qué hay un cooldown

La primera línea funcional del script (después del comentario) es un check de timestamp. Si el script se ejecutó hace menos de 60 segundos, aborta con un mensaje claro. ¿Por qué?

Porque tirar un link y subirlo deja a FRR, LACP y al fabric EVPN haciendo trabajo durante varios segundos después: re-elección de DF, re-anuncio de Type-2, renegociación LACP. Si dispararas el script otra vez en el medio de esa re-convergencia, el lab puede quedar en un estado raro (lo aprendí a fuerza de romperlo: una vez bgpd murió en un leaf y no se reinició solo).

Si lo necesitás forzar (porque sabés lo que hacés), `FORCE=1 ./scripts/05-mh-esi-lag.sh` lo dispara igual. Si bajás el cooldown para un test, `COOLDOWN=10 ./scripts/05-mh-esi-lag.sh`.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-leaf2 vtysh -c "show evpn es"
```

Lista de **Ethernet Segments** (ES) locales en leaf2. Vas a ver una sola entrada con el ESI `03:02:00:00:00:00:0c:00:00:01` — los dos primeros bytes (`03`) indican que es un ESI tipo "Auto-generated based on LACP", y los siguientes 9 bytes son el system-MAC LACP del peer (que en este lab forzamos a `02:00:00:00:00:0c` en leaf2 y leaf3 con `ad_actor_system`).

```bash
docker exec clab-evpn-ixp-lab-leaf2 vtysh -c "show bgp l2vpn evpn route type ead"
```

Las rutas **Type-1 (Ethernet A-D)**. Hay dos sub-tipos:

- **EAD-per-EVI**: una ruta por cada combinación (ES × EVI), usada para fast convergence
- **EAD-per-ES**: una ruta por ES, usada para alias y mass-withdraw

Cuando se cae un link a un ES, el leaf afectado **retira la EAD-per-ES** y los otros leafs reciben ese retiro como una señal de "este VTEP ya no puede llegar a ese ES, sacálo del aggregate". Eso es lo que hace que el failover sea rápido.

```bash
docker exec -d clab-evpn-ixp-lab-client-a sh -c 'ping -i 0.2 100.64.0.30 > /tmp/ping.log 2>&1'
sleep 2
docker exec clab-evpn-ixp-lab-leaf2 ip link set eth4 down
```

Arranca un ping en background desde client-a a client-c (el multi-homed), espera 2 segundos para que se estabilice, y **baja el link** de client-c a leaf2.

```bash
sleep 5
docker exec clab-evpn-ixp-lab-leaf2 ip link set eth4 up
```

Cinco segundos de tráfico solo por leaf3, después restaura el link.

```bash
docker exec clab-evpn-ixp-lab-client-a tail -30 /tmp/ping.log | grep -E "packets transmitted|icmp_seq" | tail -10
```

Te muestra el resumen del ping. Si todo funciona bien, vas a ver muchos `icmp_seq` consecutivos y al final algo como **"X packets transmitted, X received, 0% packet loss"** — o cerca de 0% (el lab real mide ~150ms de pérdida total, lo que en un ping de 0.2s entre paquetes son 1-2 paquetes).

### Qué tenés que mirar en pantalla

Lo primero, en el `show evpn es`, mostrar el **ESI no-cero**. Una conexión single-homed tiene ESI = `00:00:00:00:00:00:00:00:00:00`. Una multi-homed tiene un ESI **único, generado por LACP, idéntico en los leafs que comparten el ES**.

Después, durante el failover, el ping no debería interrumpirse de forma visible. Si en tu demo en vivo el ping sigue corriendo sin dejar de imprimir respuestas, **ese es el momento aplausos**.

### ¿Por qué es relevante?

Multi-chassis link aggregation siempre fue una solución vendor-specific: MLAG en Arista, VPC en Cisco, MC-LAG en Juniper. Cada uno con su propio protocolo de sincronización entre los dos switches, sus bugs, sus limitaciones. Y casi todos sufren del problema del "split-brain": si los dos switches dejan de hablarse, ambos creen que el otro está muerto y empiezan a forwardear desde los dos lados → loop garantizado.

EVPN multi-homing **no necesita comunicación directa entre los leafs**. Toda la coordinación pasa por BGP EVPN. El ESI auto-generado por LACP hace que los leafs "se reconozcan" como parte del mismo ES sin haber sido configurados explícitamente como par. **Es un estándar (RFC 7432), corre en cualquier vendor que lo implemente, y no tiene split-brain.**

### El detalle escondido que casi me arruina la demo

LACP entre client-c y los dos leafs **necesita que los leafs anuncien el mismo system-id LACP** para que el cliente los agregue en el mismo bundle. Si no, el cliente ve dos peers LACP distintos y solo activa un puerto a la vez (failover de 3 segundos, no de 200ms).

En el `init.sh` de leaf2 y leaf3 esto se hace con:

```bash
ip link add bond-esi10 type bond mode 802.3ad miimon 100 lacp_rate fast \
  ad_actor_system 02:00:00:00:00:0c ad_actor_sys_prio 100
```

El `ad_actor_system 02:00:00:00:00:0c` es lo que LACP pone en el system-id del LACPDU. Si lo omitís, el kernel pone el MAC del bond (auto-asignado, distinto en cada leaf). Sin esto, **el lab "funciona" pero el failover no impresiona**.

### Errores comunes

- **El ping pierde 60+ paquetes durante el failover:** el bond del cliente solo tiene `Number of ports: 1`. Verificá en `cat /proc/net/bonding/bond0` del cliente que diga `Number of ports: 2` y `Partner Mac Address: 02:00:00:00:00:0c`.
- **El script se ejecuta dos veces y queda raro:** respetá el cooldown. Si pasó algo igual y el lab no anda, `./scripts/down.sh && ./scripts/up.sh`.
- **`show evpn es` no muestra el ESI:** el `evpn mh es-id` no está en la configuración FRR del leaf, o la interfaz `bond-esi10` no existe en zebra.

---

## Script 06 — `06-peering-inter-asn.sh` — Peering entre ASNs sobre el fabric

### Qué hace

Este es **el caso de uso que da nombre a la charla**: clientes con ASNs distintos haciendo eBGP entre sí, como en cualquier IXP del mundo, pero sobre un fabric EVPN/VXLAN en lugar de una LAN física compartida.

La gracia es que **el fabric no participa**. Las sesiones BGP de los clientes son TCP/179 que viajan **encapsuladas en VXLAN como cualquier otro paquete**. Para BGP, es como si los clientes estuvieran en el mismo cable.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-client-a vtysh -c "show bgp summary"
```

El estado de las sesiones BGP de client-a. Vas a ver dos vecinos: client-b (AS 64602) y client-c (AS 64603). Ambos en estado "Established" con uptime razonable.

```bash
docker exec clab-evpn-ixp-lab-client-a vtysh -c "show ip bgp"
```

La tabla BGP de client-a. Tiene que ver los loopbacks de los otros clientes:

```
*>  192.0.2.10/32    0.0.0.0                  0         32768 i   <- propia
*>  192.0.2.20/32    100.64.0.20              0             0 64602 i
*   192.0.2.20/32    100.64.0.20                            0 64603 64602 i  <- alt path
*>  192.0.2.30/32    100.64.0.30              0             0 64603 i
*   192.0.2.30/32    100.64.0.30                            0 64602 64603 i  <- alt path
```

Cada loopback aparece con dos paths: directo (un solo AS en el path) y por el otro peer en transit (dos ASes). El best path se elige por la AS-PATH más corta, como siempre.

```bash
docker exec clab-evpn-ixp-lab-client-a traceroute -n 192.0.2.20 || true
```

Un traceroute al loopback de client-b. **Tiene que dar un solo hop visible** — el primer y único salto es la IP de client-b en la VLAN Peering. El fabric (leafs y spines) **no aparece** porque están bridgeando, no enrutando, los paquetes entre clientes.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp ipv4 unicast" | head -20
```

La tabla BGP del leaf — la del fabric, no la de los clientes. **No tiene que ver los prefijos de los clientes** (192.0.2.x/32). El leaf solo aprende loopbacks del fabric (10.0.0.x/32). Esto es lo más importante de mostrar.

### Qué tenés que mirar en pantalla

El golpe está en la comparación: la tabla BGP de client-a tiene los prefijos de los otros clientes. La tabla BGP del leaf **no los tiene**. **El fabric ni se entera de las sesiones BGP de sus clientes.**

Esto es lo que un IXP necesita: ofrecer conectividad L2 entre miembros sin meter las narices en lo que ellos hacen arriba.

### ¿Por qué es relevante?

Hoy un IXP tiene **un servicio**: la LAN de peering. Si querés ofrecer un servicio adicional (un closed user group, una LAN privada entre dos miembros, una LAN para servicios DNS root), tenés que armar otra LAN física o virtual.

Con EVPN, un IXP puede ofrecer **N LANs distintas sobre el mismo fabric**, cada una con sus propios miembros, sus propias políticas, sus propios route servers si quisiera. **Un solo plano de control para el operador, N servicios para el cliente.**

### Errores comunes

- **Las sesiones BGP entre clientes no levantan:** los clientes están en la misma subnet pero no se ven en L2. Eso significa que el L2VNI no está bien — empezá por el script 02 para descartar.
- **El leaf ve los prefijos de los clientes en BGP IPv4:** alguien metió un `redistribute connected` que está agarrando rutas que no debería, o un cliente está peerando contra el SVI del leaf en vez de contra otro cliente. Mirá las configs FRR de los clientes.

---

## Script 07 — `07-vxlan-capture.sh` — El "idioma" en el cable

### Qué hace

Captura paquetes VXLAN en el cable y te los muestra crudos. Es el cierre de la charla: después de hablar de planos de control, families EVPN, multi-tenancy y demás, ahora le mostrás a la audiencia **qué hay realmente viajando en los enlaces del fabric**.

### Línea por línea

```bash
docker exec -d clab-evpn-ixp-lab-spine1 sh -c 'tcpdump -i eth1 -nn -e -c 10 "udp port 4789" > /tmp/vxlan.pcap 2>&1'
```

Arranca `tcpdump` en el enlace spine1↔leaf1 (eth1 desde el lado del spine), filtrando solo paquetes **UDP destino 4789** (el puerto IANA de VXLAN). Captura 10 paquetes y los guarda en `/tmp/vxlan.pcap`.

```bash
docker exec clab-evpn-ixp-lab-client-a ping -c 5 100.64.0.20 >/dev/null
```

Dispara 5 pings desde client-a a client-b. Como están en leafs distintos (leaf1 y leaf2), el tráfico va a tener que pasar por los spines, encapsulado en VXLAN. Eso le da material a tcpdump para capturar.

```bash
docker exec clab-evpn-ixp-lab-spine1 cat /tmp/vxlan.pcap
```

Te imprime la captura.

### Qué tenés que mirar en pantalla

Cada línea de tcpdump te muestra un paquete completo. Buscá uno que tenga este formato (los detalles cambian pero la estructura es siempre la misma):

```
14:23:45.123456 02:42:0a:00:00:0b > 02:42:0a:00:00:01, ethertype IPv4, 
  10.0.0.11.45678 > 10.0.0.12.4789: VXLAN, flags [I] (0x08), vni 10100
  aa:c1:ab:11:22:33 > aa:c1:ab:44:55:66, ethertype IPv4,
  100.64.0.10 > 100.64.0.20: ICMP echo request
```

Acá hay **dos paquetes Ethernet en el mismo frame**:

1. **El outer**: viaja entre las loopbacks de los leafs (10.0.0.11 → 10.0.0.12), puerto UDP 4789. Es **lo que ve el underlay**.
2. **El inner**: el ICMP original del cliente (100.64.0.10 → 100.64.0.20), con sus MACs y todo. Es **lo que el cliente cree que está mandando**.

En el medio del paquete está el header VXLAN, que contiene el **VNI** (`vni 10100` en la salida). Eso es lo que le dice al leaf de destino en qué bridge tiene que poner el frame al des-encapsular.

### ¿Por qué es relevante?

Esta es la diapositiva donde decís: *"todo lo que vimos hasta acá es BGP contándonos cosas. Pero el plano de datos es esto: IP que transporta Ethernet, sin más."*

VXLAN es **brutalmente simple** comparado con MPLS-EVPN: no hay LSPs, no hay LDP, no hay restricciones de MTU dolorosas (siempre que tu underlay tenga jumbo frames habilitados — recordá los 50+ bytes de overhead de VXLAN). Y como es UDP, **funciona sobre cualquier red IP**, incluso una WAN.

### Detalle importante para tu MTU

VXLAN agrega **50 bytes de overhead** (14 outer eth + 20 outer IP + 8 UDP + 8 VXLAN). Si tu underlay tiene MTU 1500, los clientes solo pueden mandar 1450. **Siempre configurá jumbo frames (9000 o más) en el underlay**. En el lab los enlaces tienen MTU 9500 por eso.

### Errores comunes

- **La captura sale vacía:** el ping no generó tráfico VXLAN porque client-a y client-b están en el mismo leaf, o porque la captura se hizo en el enlace equivocado. Verificá con `containerlab inspect` qué enlace une qué nodos.
- **Solo aparecen paquetes EVPN BGP, no VXLAN data:** el filtro `udp port 4789` está bien, pero tcpdump podría estar viendo solo BGP control plane si nunca se dispara tráfico real. Asegurate de que el ping corra **después** de arrancar tcpdump.

---

## Script 08 — `08-hardening.sh` — Hardening del underlay y BGP

### Qué hace

Muestra las **protecciones del plano de control** que vienen configuradas en el peer-group FABRIC. Nada de esto interrumpe el fabric: son medidas defensivas que limitan el blast radius y detectan fallas sub-segundo.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show running-config" \
  | grep -E "neighbor FABRIC (bfd|ttl-security|maximum-prefix)|no bgp default"
```

Extrae del running-config de leaf1 las líneas relevantes del peer-group FABRIC:
- `bfd` — Bidirectional Forwarding Detection activo
- `ttl-security hops 1` — GTSM (RFC 5082): solo acepta paquetes BGP con TTL=255 (a 1 salto)
- `maximum-prefix 5000` — si un leaf anuncia más de 5000 prefijos, se corta la sesión (contiene compromisos)
- `no bgp default ipv4-unicast` — mínimo privilegio en address-families (nada se activa sin `activate` explícito)

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bfd peers" \
  | grep -iE "Status:|interval|multiplier" | head -6
```

Estado de los peers BFD en leaf1. Te muestra los timers: **150ms × 3 = detección de falla sub-segundo**. Eso significa que si se pierde un enlace, BGP se entera en ~450ms, no en los 90 o 180 segundos del holdtime BGP por default.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show bgp l2vpn evpn summary" \
  | grep -E "spine|Total"
```

Las sesiones BGP EVPN siguen estables **a pesar** de todo el hardening. El punto es: podés tener seguridad sin romper nada.

### Qué tenés que mirar en pantalla

Lo primero es la línea del `ttl-security hops 1`. Ese es el control anti-spoofing más simple y efectivo para BGP entre vecinos directos. Si alguien inyecta un paquete TCP/179 con TTL < 255 (es decir, desde más de 1 salto), el kernel lo descarta.

Lo segundo es BFD: los timers sub-segundo. En un fabric EVPN con multi-homing, detectar una falla en 450ms es lo que hace que el failover del script 05 sea tan rápido.

### ¿Por qué es relevante?

EVPN no endurece el underlay solo. Hay operadores que despliegan EVPN/VXLAN sin BFD, sin GTSM, sin maximum-prefix. Funciona, pero es frágil: un leaf comprometido o un software bug puede contaminar todo el fabric con miles de rutas falsas. El hardening es trabajo aparte y complementario.

El mensaje para la audiencia: *"EVPN te resuelve el plano de datos y el control-plane de MACs/IPs, pero la seguridad del underlay es tu responsabilidad."* En producción agregar TCP-AO (RFC 5925) y CoPP/lpts.

### Errores comunes

- **BFD no levanta:** el perfil BFD no está creado en FRR, o `bfd` no está bajo el peer-group. Mirá `show bfd profile FABRIC`.
- **Sesiones flapping con GTSM:** si hay un middlebox (un firewall transparente, un switch L3 en medio del enlace), el TTL llega decrementado y GTSM lo rechaza. Solo funciona en enlaces directos.

---

## Script 09 — `09-eline.sh` — Servicio L2 punto a punto (E-Line)

### Qué hace

Demuestra un servicio **L2 punto a punto dedicado**: client-e (en leaf1) y client-f (en leaf2) se conectan como si estuvieran en el mismo cable, a través de un **VNI exclusivo** (10300) sin gateway, sin SVI, sin nada más compartiendo ese VNI.

Es el equivalente a un **E-Line** (EVPN-VPWS) pero implementado en EVPN-VXLAN puro (lo que FRR soporta nativamente). El VNI 10300 solo tiene esos dos puertos de acceso.

### Línea por línea

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn vni 10300" | head -8
```

Te muestra el VNI 10300 como L2VNI dedicado en leaf1. No tiene SVI ni gateway — es pura conectividad L2.

```bash
docker exec clab-evpn-ixp-lab-leaf1 vtysh -c "show evpn mac vni 10300"
```

Las MACs aprendidas: el MAC de client-e como "local" (está en `eth5` de leaf1) y el MAC de client-f como "remote" (detrás del VTEP 10.0.0.12).

```bash
docker exec clab-evpn-ixp-lab-client-e ping -c 3 -W 2 203.0.113.2 || true
```

Ping de client-e (203.0.113.1/30) a client-f (203.0.113.2/30). Si funciona, el E-Line está activo: el fabric une a los dos endpoints como un cable virtual.

### Qué tenés que mirar en pantalla

El VNI 10300 es **completamente independiente** del VNI 10100 (peering), del 20100 (tenant-B), etc. Podés tener un servicio E-Line corriendo al lado de los demás servicios sin interferencia.

Los clientes client-e y client-f no corren FRR ni BGP — son endpoints L2 puros con una IP en un /30.

### ¿Por qué es relevante?

Un IXP moderno puede querer ofrecer **más que una LAN de peering compartida**. Con EVPN sobre el mismo fabric podés vender:
- LAN de peering (VNI 10100)
- LANs privadas entre grupos de miembros
- **Enlaces punto a punto** (E-Lines) entre dos sedes del mismo cliente

Todo sobre el mismo hardware, el mismo plano de control, los mismos spines y leafs. Un solo operador manteniendo un solo fabric, múltiples servicios.

### Errores comunes

- **El ping no funciona entre client-e y client-f:** verificá que el VNI 10300 exista en ambos leafs (`show evpn vni 10300`). Si falta en uno, el bridge `br10300` no se creó en el `init.sh` de ese leaf.
- **El VNI 10300 tiene MACs de otros clientes:** alguien mezcló puertos en el bridge equivocado. Cada bridge debe tener solo sus puertos de acceso específicos.

---

## Scripts auxiliares: `up.sh` y `down.sh`

Son triviales pero importantes. `up.sh` hace `containerlab deploy`, `down.sh` hace `containerlab destroy --cleanup`. Los dos usan `sudo` porque containerlab necesita root para manipular network namespaces, bridges y veth pairs.

Si tenés `sudo` sin password configurado para tu usuario, los scripts corren transparente. Si no, te va a pedir password.

El `--cleanup` del destroy es importante: sin él, containerlab deja el directorio `clab-evpn-ixp-lab/` con los configs renderizados, los logs, etc. Con `--cleanup` limpia todo y dejás el repo igual que antes de levantar el lab.

---

## Script auxiliar: `validate.sh`

Pipeline de validación automática. Despliega el lab, espera 25 segundos para que BGP/EVPN converjan, y ejecuta los 9 scripts de demo en secuencia (sin abortar si alguno falla). Útil para verificar que el lab quedó sano después de cambios en configs.

```bash
cd lab/
./scripts/validate.sh 2>&1 | tee validate.log
```

Internamente hace `set +e` para que una falla en un script no aborte la ejecución de los siguientes. Al final muestra el detalle de todas las VNIs activas desde leaf1.

---

## `run.sh` — TUI interactiva

El punto de entrada principal para operar el lab. Es un menú interactivo basado en [gum](https://github.com/charmbracelet/gum) que ofrece:

- **Deploy / destroy / nuke** del lab
- **Estado y topología** ASCII
- **Correr demos individuales o todos** (01–09)
- **Shell interactivo** en cualquier nodo
- **Comandos útiles** (cheat sheet)
- **Chequeo de dependencias** e instalación de gum

```bash
cd lab/
./run.sh
```

Requiere `docker`, `containerlab` y `gum`. Si `gum` no está instalado, ofrece instalarlo automáticamente.

---

## Orden recomendado de ejecución

Para la charla de Ariel Weher:

1. Mostrar la topología (sin correr nada), 2 min
2. `01-underlay.sh` + comentar, 2 min
3. `02-evpn-type2-type3.sh`, 4 min
4. `03-evpn-type5-anycast.sh`, 3 min
5. `04-multitenancy.sh`, 3 min
6. `05-mh-esi-lag.sh`, 4 min
7. `06-peering-inter-asn.sh`, 4 min
8. `07-vxlan-capture.sh`, 2 min
9. `08-hardening.sh` — muestra en 1 minuto que el fabric tiene BFD, GTSM y maximum-prefix. Sirve para responder "¿y la seguridad?".
10. `09-eline.sh` — muestra en 1 minuto un servicio extra sobre el mismo fabric. Sirve para responder "¿y servicios punto a punto?".

---

Espero les sirva.
