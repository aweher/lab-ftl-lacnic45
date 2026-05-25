#!/usr/bin/env bash
# =============================================================================
# run.sh — TUI para el ciclo de vida del lab EVPN & VXLAN (LACNIC 45 / FTL)
# Requiere: docker, containerlab, gum
# =============================================================================
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
TOPO_FILE="${LAB_DIR}/topology.clab.yml"
LAB_NAME="evpn-ixp-lab"
LAB_PREFIX="clab-${LAB_NAME}"

NODES_SPINE=("spine1" "spine2")
NODES_LEAF=("leaf1" "leaf2" "leaf3")
NODES_CLIENT=("client-a" "client-b" "client-c" "client-d" "client-e" "client-f")
NODES_ALL=("${NODES_SPINE[@]}" "${NODES_LEAF[@]}" "${NODES_CLIENT[@]}")

DEMOS=(
  "01-underlay|Underlay BGP unnumbered"
  "02-evpn-type2-type3|EVPN Type-2 (MAC/IP) y Type-3 (IMET)"
  "03-evpn-type5-anycast|L3 simétrico (Type-5) + Anycast Gateway"
  "04-multitenancy|Multi-tenancy — dos VRFs aislados"
  "05-mh-esi-lag|Multi-Homing ESI-LAG all-active + failover"
  "06-peering-inter-asn|Peering entre ASNs sobre el fabric (caso IXP)"
  "07-vxlan-capture|Captura VXLAN UDP/4789 en el cable"
  "08-hardening|BFD, GTSM, maximum-prefix, mínimo privilegio"
  "09-eline|Servicio L2 punto a punto (E-Line, VNI 10300)"
)

# ─── Colores / helpers ───────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}!${NC} $*"; }
log_err()  { echo -e "${RED}✗${NC} $*"; }
log_info() { echo -e "${CYAN}→${NC} $*"; }

die() { log_err "$@"; exit 1; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

# ─── Detección de plataforma ─────────────────────────────────────────────────

detect_platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    i386|i686) ARCH="386" ;;
  esac
  case "${OS}" in
    linux)  PLATFORM="linux" ;;
    darwin) PLATFORM="darwin" ;;
    *)      PLATFORM="${OS}" ;;
  esac
}

# ─── Instalación / actualización de gum ──────────────────────────────────────

install_gum() {
  detect_platform
  echo ""

  if command -v brew &>/dev/null; then
    log_info "Instalando gum via Homebrew..."
    brew install gum
    return $?
  fi

  if [[ "${PLATFORM}" == "linux" ]]; then
    if command -v apt-get &>/dev/null; then
      log_info "Instalando gum via apt (charmbracelet repo)..."
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
      sudo apt-get update -qq && sudo apt-get install -y gum
      return $?
    elif command -v dnf &>/dev/null; then
      log_info "Instalando gum via dnf (charmbracelet repo)..."
      echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo >/dev/null
      sudo dnf install -y gum
      return $?
    elif command -v yum &>/dev/null; then
      log_info "Instalando gum via yum (charmbracelet repo)..."
      echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo >/dev/null
      sudo yum install -y gum
      return $?
    elif command -v pacman &>/dev/null; then
      log_info "Instalando gum via pacman..."
      sudo pacman -S --noconfirm gum
      return $?
    fi
  fi

  log_info "Instalando gum desde binario (GitHub releases)..."
  local tmp
  tmp="$(mktemp -d)"
  local url="https://github.com/charmbracelet/gum/releases/latest/download/gum_${PLATFORM}_${ARCH}.tar.gz"
  log_info "Descargando ${url} ..."
  if curl -fsSL "${url}" -o "${tmp}/gum.tar.gz"; then
    tar -xzf "${tmp}/gum.tar.gz" -C "${tmp}"
    local bin
    bin="$(find "${tmp}" -name gum -type f | head -1)"
    if [[ -n "${bin}" ]]; then
      sudo install -m 0755 "${bin}" /usr/local/bin/gum
      log_ok "gum instalado en /usr/local/bin/gum"
    else
      die "No se encontró el binario gum en el tarball"
    fi
  else
    die "No se pudo descargar gum. Instalalo manualmente: https://github.com/charmbracelet/gum#installation"
  fi
  rm -rf "${tmp}"
}

upgrade_gum() {
  detect_platform
  if command -v brew &>/dev/null; then
    log_info "Actualizando gum via Homebrew..."
    brew upgrade gum 2>/dev/null || log_ok "gum ya está en la última versión"
  elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install --only-upgrade -y gum
  elif command -v dnf &>/dev/null; then
    sudo dnf upgrade -y gum
  elif command -v pacman &>/dev/null; then
    sudo pacman -Syu --noconfirm gum
  else
    log_warn "No se detectó package manager. Reinstalando desde binario..."
    install_gum
  fi
}

# ─── Chequeo de dependencias ─────────────────────────────────────────────────

check_tool() {
  local tool="$1"
  local desc="$2"
  local install_hint="$3"
  if command -v "${tool}" &>/dev/null; then
    local ver
    ver="$("${tool}" --version 2>/dev/null | head -1 || echo "?")"
    log_ok "${tool} encontrado — ${ver}"
    return 0
  else
    log_err "${tool} no encontrado — ${desc}"
    log_info "  Instalá con: ${install_hint}"
    return 1
  fi
}

check_dependencies() {
  local missing=0

  echo ""
  gum style --bold --foreground 212 --border double --padding "0 2" --margin "0 0" \
    "Verificando dependencias del sistema..."
  echo ""

  check_tool "docker" \
    "Motor de contenedores" \
    "https://docs.docker.com/engine/install/" || ((missing++))

  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    log_warn "Docker está instalado pero no accesible (¿servicio detenido o permisos?)"
    ((missing++))
  fi

  check_tool "containerlab" \
    "Herramienta de labs de red en contenedores" \
    "bash -c \"\$(curl -sL https://get.containerlab.dev)\"" || ((missing++))

  check_tool "ping" \
    "Herramienta de red básica" \
    "apt install iputils-ping / brew install inetutils" || true

  check_tool "tcpdump" \
    "Captura de paquetes" \
    "apt install tcpdump / brew install tcpdump" || true

  check_tool "jq" \
    "Procesador de JSON (opcional pero recomendado)" \
    "apt install jq / brew install jq" || true

  echo ""

  if [[ ${missing} -gt 0 ]]; then
    gum style --foreground 196 --bold \
      "Faltan ${missing} dependencia(s) crítica(s). Resolvelás antes de continuar."
    echo ""
    gum confirm "¿Continuar de todos modos?" || exit 1
  else
    gum style --foreground 46 --bold "Todas las dependencias críticas están disponibles."
  fi
  echo ""
}

# ─── Chequeo inicial de gum ──────────────────────────────────────────────────

ensure_gum() {
  if command -v gum &>/dev/null; then
    return 0
  fi

  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  gum no está instalado${NC}"
  echo -e "  gum (charmbracelet/gum) es necesario para la interfaz TUI."
  echo -e "  Más info: ${CYAN}https://github.com/charmbracelet/gum${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  echo "¿Querés instalar gum ahora?"
  echo "  1) Sí, instalar gum"
  echo "  2) No, salir"
  read -rp "Opción [1]: " opt
  opt="${opt:-1}"

  if [[ "${opt}" == "1" ]]; then
    install_gum
    if ! command -v gum &>/dev/null; then
      die "La instalación de gum falló. Instalalo manualmente."
    fi
    log_ok "gum instalado correctamente."
  else
    die "gum es necesario para usar este script."
  fi
}

# ─── Estado del lab ──────────────────────────────────────────────────────────

lab_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${LAB_PREFIX}" 2>/dev/null
}

show_lab_status() {
  echo ""
  if lab_is_running; then
    gum style --bold --foreground 46 --border rounded --padding "0 2" \
      "Lab ${LAB_NAME} — ACTIVO"
    echo ""
    need_sudo
    ${SUDO} containerlab inspect -t "${TOPO_FILE}" 2>/dev/null || \
      docker ps --filter "name=${LAB_PREFIX}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  else
    gum style --bold --foreground 196 --border rounded --padding "0 2" \
      "Lab ${LAB_NAME} — DETENIDO"
  fi
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

# ─── Deploy / Destroy ────────────────────────────────────────────────────────

deploy_lab() {
  need_sudo

  # Siempre arrancamos de cero: destroy --cleanup garantiza que FRR relea
  # el frr.conf desde el archivo (un --reconfigure a secas a veces deja
  # estado viejo de FRR en memoria, p.ej. el peer-group/BFD sin recargar).
  if lab_is_running; then
    gum style --foreground 214 "El lab ya está corriendo."
    gum confirm "¿Querés destruirlo y volver a desplegarlo limpio?" || return 0
    destroy_lab_inner
  fi

  echo ""
  gum style --bold --foreground 212 "Desplegando el lab (arranque limpio)..."
  echo ""

  # --max-workers 2: el arranque en paralelo de los 11 nodos provoca una
  # race condition en el underlay (eBGP unnumbered + GTSM + BFD) que deja
  # sesiones colgadas en OpenSent/Idle. Serializar el arranque lo evita.
  gum spin --spinner dot --title "containerlab deploy en curso (max-workers 2)..." -- \
    ${SUDO} containerlab deploy -t "${TOPO_FILE}" --reconfigure --max-workers 2 2>&1
  echo ""

  if lab_is_running; then
    log_ok "Lab desplegado. Esperando convergencia de BGP/EVPN/BFD..."
    gum spin --spinner pulse --title "Esperando 25s a que el fabric converja..." -- \
      sleep 25
    echo ""
    ${SUDO} containerlab inspect -t "${TOPO_FILE}" 2>/dev/null || true
    echo ""
    # Chequeo rápido de convergencia: sesiones BGP del fabric establecidas
    local established
    established=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show bgp l2vpn evpn summary json" 2>/dev/null \
      | grep -o '"state":"Established"' | wc -l | tr -d ' ')
    if [[ "${established}" -ge 2 ]]; then
      log_ok "Underlay convergido — ${established} sesiones BGP EVPN establecidas en leaf1."
    else
      log_warn "El underlay aún no convergió (${established}/2 sesiones en leaf1)."
      log_info "Esperá unos segundos más y revisá 'Estado del lab', o probá un Nuke + Deploy."
    fi
  else
    log_err "Algo salió mal con el deploy. Revisá los logs de Docker."
  fi
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

destroy_lab_inner() {
  need_sudo
  gum spin --spinner dot --title "Destruyendo el lab..." -- \
    ${SUDO} containerlab destroy -t "${TOPO_FILE}" --cleanup 2>&1
}

destroy_lab() {
  if ! lab_is_running; then
    gum style --foreground 214 "El lab no está corriendo."
    echo ""
    gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
    return 0
  fi

  echo ""
  gum confirm --affirmative "Sí, destruir" --negative "Cancelar" \
    "¿Estás seguro de que querés destruir el lab?" || return 0

  echo ""
  destroy_lab_inner
  log_ok "Lab destruido."
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

nuke_lab() {
  echo ""
  gum style --bold --foreground 196 --border double --padding "1 2" \
    "☢  NUKE — Destruir todo y empezar desde cero" \
    "" \
    "Esto va a:" \
    "  1. Destruir el lab de containerlab" \
    "  2. Eliminar contenedores huérfanos del lab" \
    "  3. Eliminar redes Docker del lab" \
    "  4. Borrar archivos generados por containerlab" \
    "  5. (Opcional) Eliminar las imágenes Docker del lab"
  echo ""

  gum confirm --affirmative "Sí, destruir TODO" --negative "Cancelar" \
    "⚠  Esto es irreversible. ¿Estás seguro?" || return 0

  echo ""
  need_sudo

  # 1) Destruir el lab si está corriendo
  if lab_is_running; then
    log_info "Destruyendo el lab de containerlab..."
    ${SUDO} containerlab destroy -t "${TOPO_FILE}" --cleanup 2>&1 || true
    log_ok "containerlab destroy completado."
  else
    log_info "El lab no estaba corriendo."
  fi

  # 2) Matar contenedores huérfanos con el prefijo del lab
  local orphans
  orphans=$(docker ps -a --filter "name=${LAB_PREFIX}" --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "${orphans}" ]]; then
    log_info "Eliminando contenedores huérfanos..."
    echo "${orphans}" | xargs -r docker rm -f 2>/dev/null || true
    log_ok "Contenedores huérfanos eliminados."
  else
    log_info "Sin contenedores huérfanos."
  fi

  # 3) Eliminar redes Docker del lab
  local nets
  nets=$(docker network ls --filter "name=clab" --format '{{.Name}}' 2>/dev/null || true)
  if [[ -n "${nets}" ]]; then
    log_info "Eliminando redes Docker del lab..."
    echo "${nets}" | xargs -r docker network rm 2>/dev/null || true
    log_ok "Redes eliminadas."
  else
    log_info "Sin redes del lab."
  fi

  # 4) Borrar directorio generado por containerlab
  local clab_dir="${LAB_DIR}/${LAB_PREFIX}"
  if [[ -d "${clab_dir}" ]]; then
    log_info "Borrando directorio ${clab_dir} ..."
    ${SUDO} rm -rf "${clab_dir}"
    log_ok "Directorio ${LAB_PREFIX}/ eliminado."
  else
    log_info "Sin directorio generado por containerlab."
  fi

  # Borrar .clab.yml.bak si existe
  if ls "${LAB_DIR}"/*.clab.yml.bak &>/dev/null 2>&1; then
    rm -f "${LAB_DIR}"/*.clab.yml.bak
    log_ok "Archivos .clab.yml.bak eliminados."
  fi

  # 5) Opcionalmente eliminar imágenes Docker del lab
  echo ""
  if gum confirm --affirmative "Sí, borrar imágenes" --negative "No, conservarlas" \
    "¿Querés borrar también las imágenes Docker del lab? (quay.io/frrouting/frr:10.2.1)"; then
    log_info "Eliminando imágenes Docker del lab..."
    docker rmi quay.io/frrouting/frr:10.2.1 2>/dev/null || true
    docker image prune -f >/dev/null 2>&1 || true
    log_ok "Imágenes eliminadas."
  else
    log_info "Imágenes conservadas."
  fi

  echo ""
  gum style --foreground 46 --bold "☢  Nuke completo. Todo limpio para empezar de cero."
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

# ─── Demos ────────────────────────────────────────────────────────────────────

run_demo() {
  if ! lab_is_running; then
    gum style --foreground 196 "El lab no está corriendo. Desplegalo primero."
    echo ""
    gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
    return 0
  fi

  local options=()
  for d in "${DEMOS[@]}"; do
    local key="${d%%|*}"
    local desc="${d##*|}"
    options+=("${key}  —  ${desc}")
  done
  options+=("← Volver al menú")

  echo ""
  local choice
  choice=$(gum choose --height 14 --header "Seleccioná un script de demo:" "${options[@]}")

  [[ "${choice}" == *"Volver"* ]] && return 0

  local script_key="${choice%%  —*}"
  local script_path="${LAB_DIR}/scripts/${script_key}.sh"

  if [[ ! -x "${script_path}" ]]; then
    chmod +x "${script_path}" 2>/dev/null || true
  fi

  echo ""
  gum style --bold --foreground 212 --border rounded --padding "0 2" \
    "Ejecutando: ${script_key}.sh"
  echo ""

  bash "${script_path}" 2>&1 | gum pager

  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

run_all_demos() {
  if ! lab_is_running; then
    gum style --foreground 196 "El lab no está corriendo. Desplegalo primero."
    echo ""
    gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
    return 0
  fi

  gum confirm "¿Ejecutar los 9 scripts de demo en secuencia?" || return 0

  for d in "${DEMOS[@]}"; do
    local key="${d%%|*}"
    local desc="${d##*|}"
    local script_path="${LAB_DIR}/scripts/${key}.sh"

    echo ""
    gum style --bold --foreground 99 "━━━ ${key}: ${desc} ━━━"
    echo ""

    if [[ ! -x "${script_path}" ]]; then
      chmod +x "${script_path}" 2>/dev/null || true
    fi

    bash "${script_path}" 2>&1 || log_warn "El script ${key} terminó con error"
    echo ""

    if [[ "${key}" != "09-eline" ]]; then
      gum confirm --affirmative "Siguiente" --negative "Parar" \
        "¿Continuar con el siguiente demo?" || break
    fi
  done

  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

# ─── Conectar a nodo ─────────────────────────────────────────────────────────

connect_node() {
  if ! lab_is_running; then
    gum style --foreground 196 "El lab no está corriendo. Desplegalo primero."
    echo ""
    gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
    return 0
  fi

  local options=()
  for n in "${NODES_ALL[@]}"; do
    options+=("${n}")
  done
  options+=("← Volver al menú")

  echo ""
  local node
  node=$(gum choose --height 16 --header "Seleccioná un nodo para conectarte:" "${options[@]}")

  [[ "${node}" == *"Volver"* ]] && return 0

  echo ""
  local container="${LAB_PREFIX}-${node}"

  # client-e y client-f no tienen FRR — solo bash
  if [[ "${node}" == "client-e" || "${node}" == "client-f" ]]; then
    gum style --foreground 117 "Conectando a ${node} (bash)... exit para salir."
    gum style --foreground 214 "(${node} no tiene FRR — solo shell disponible)"
    echo ""
    docker exec -it "${container}" bash
  else
    local shell_choice
    shell_choice=$(gum choose --header "¿Qué shell querés usar?" \
      "vtysh  —  CLI de FRR" \
      "bash   —  Shell del contenedor" \
      "← Volver")

    [[ "${shell_choice}" == *"Volver"* ]] && return 0

    echo ""
    case "${shell_choice}" in
      vtysh*)
        gum style --foreground 117 "Conectando a ${node} (vtysh)... Ctrl+D para salir."
        echo ""
        docker exec -it "${container}" vtysh
        ;;
      bash*)
        gum style --foreground 117 "Conectando a ${node} (bash)... exit para salir."
        echo ""
        docker exec -it "${container}" bash
        ;;
    esac
  fi

  echo ""
}

# ─── Comandos útiles ──────────────────────────────────────────────────────────

useful_commands() {
  if ! lab_is_running; then
    gum style --foreground 196 "El lab no está corriendo. Desplegalo primero."
    echo ""
    gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
    return 0
  fi

  local options=(
    "Ver todas las VNIs activas (leaf1)"
    "Ver MACs aprendidas por overlay (leaf1)"
    "Ver ESI / Ethernet Segments (leaf2)"
    "Ver rutas Type-5 prefix (leaf1)"
    "Ver VTEPs remotos (leaf1)"
    "Ver BGP EVPN summary (spine1)"
    "Ver tabla de rutas VRF tenant-A (leaf1)"
    "Ver tabla de rutas VRF tenant-B (leaf3)"
    "Ver BFD peers activos (leaf1)"
    "Ver bridge E-Line VNI 10300 (leaf1)"
    "Ejecutar comando personalizado en un nodo"
    "← Volver al menú"
  )

  while true; do
    echo ""
    local choice
    choice=$(gum choose --height 16 --header "Comandos útiles:" "${options[@]}")

    [[ "${choice}" == *"Volver"* ]] && return 0

    echo ""
    local output=""
    case "${choice}" in
      *"VNIs activas"*)
        gum style --bold "show evpn vni detail @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show evpn vni detail" 2>&1)
        ;;
      *"MACs aprendidas"*)
        gum style --bold "show evpn mac vni all @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show evpn mac vni all" 2>&1)
        ;;
      *"ESI"*)
        gum style --bold "show evpn es detail @ leaf2"
        output=$(docker exec "${LAB_PREFIX}-leaf2" vtysh -c "show evpn es detail" 2>&1)
        ;;
      *"Type-5"*)
        gum style --bold "show bgp l2vpn evpn route type prefix @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show bgp l2vpn evpn route type prefix" 2>&1)
        ;;
      *"VTEPs"*)
        gum style --bold "bridge fdb @ leaf1 (VNI 10100)"
        output=$(docker exec "${LAB_PREFIX}-leaf1" bridge fdb show dev vni10100 2>&1 | grep dst || echo "(sin entradas)")
        ;;
      *"BGP EVPN summary"*)
        gum style --bold "show bgp l2vpn evpn summary @ spine1"
        output=$(docker exec "${LAB_PREFIX}-spine1" vtysh -c "show bgp l2vpn evpn summary" 2>&1)
        ;;
      *"tenant-A"*)
        gum style --bold "show ip route vrf tenant-A @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show ip route vrf tenant-A" 2>&1)
        ;;
      *"tenant-B"*)
        gum style --bold "show ip route vrf tenant-B @ leaf3"
        output=$(docker exec "${LAB_PREFIX}-leaf3" vtysh -c "show ip route vrf tenant-B" 2>&1)
        ;;
      *"BFD"*)
        gum style --bold "show bfd peers @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" vtysh -c "show bfd peers" 2>&1)
        ;;
      *"E-Line"*)
        gum style --bold "bridge fdb show dev vni10300 @ leaf1"
        output=$(docker exec "${LAB_PREFIX}-leaf1" bridge fdb show dev vni10300 2>&1 || echo "(sin entradas)")
        ;;
      *"personalizado"*)
        local node
        node=$(gum choose --header "Nodo:" "${NODES_ALL[@]}")
        local cmd
        cmd=$(gum input --placeholder "Comando vtysh (ej: show bgp summary)" --width 60)
        [[ -z "${cmd}" ]] && continue
        gum style --bold "${cmd} @ ${node}"
        output=$(docker exec "${LAB_PREFIX}-${node}" vtysh -c "${cmd}" 2>&1)
        ;;
    esac

    echo ""
    echo "${output}" | gum pager
  done
}

# ─── Gestión de gum ──────────────────────────────────────────────────────────

manage_gum() {
  echo ""
  local ver
  ver="$(gum --version 2>/dev/null || echo "desconocida")"

  local choice
  choice=$(gum choose --header "gum ${ver}" \
    "Actualizar gum a la última versión" \
    "← Volver al menú")

  [[ "${choice}" == *"Volver"* ]] && return 0

  upgrade_gum
  echo ""
  log_ok "gum actualizado: $(gum --version 2>/dev/null)"
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

# ─── Topología ASCII ─────────────────────────────────────────────────────────

show_topology() {
  echo ""
  gum style --border double --padding "1 2" --margin "0 0" --foreground 117 \
    "              EVPN & VXLAN — IXP-style Lab" \
    "" \
    "          +-----------+        +-----------+" \
    "          |  spine1   |        |  spine2   |" \
    "          |  AS 65001 |        |  AS 65002 |" \
    "          +-----+-----+        +-----+-----+" \
    "                |                    |" \
    "      +---------+--------+-----------+---------+" \
    "      |                  |                     |" \
    " +----+-----+       +----+-----+         +----+-----+" \
    " |  leaf1   |       |  leaf2   |         |  leaf3   |" \
    " | AS 65011 |       | AS 65012 |         | AS 65013 |" \
    " | VTEP .11 |       | VTEP .12 |         | VTEP .13 |" \
    " +--+-+-----+       +---+--+---+         +--+--+----+" \
    "    | |                 |  |   \\           /  |" \
    "    | |             client-b  client-c  client-d" \
    "    | |             AS64602   AS64603   AS64604" \
    "    | |            (single)  (ESI-LAG) (tenant-B)" \
    "    | |" \
    "    | +--- client-e (E-Line, VNI 10300)" \
    "    +--- client-a (AS 64601, single)" \
    "" \
    "         leaf2:eth5 --- client-f (E-Line, VNI 10300)"
  echo ""
  gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp ""
}

# ─── Banner ───────────────────────────────────────────────────────────────────

show_banner() {
  clear
  gum style \
    --foreground 212 --bold \
    --border double --border-foreground 99 \
    --padding "1 3" --margin "1 0" --align center \
    "EVPN & VXLAN" \
    "El nuevo idioma del peering moderno" \
    "" \
    "LACNIC 45 / FTL — Lab interactivo" \
    "Ariel Weher (Ayuda.LA)"

  if lab_is_running; then
    gum style --foreground 46 --bold --align center "● Lab ACTIVO"
  else
    gum style --foreground 196 --bold --align center "○ Lab DETENIDO"
  fi
}

# ─── Menú principal ──────────────────────────────────────────────────────────

main_menu() {
  while true; do
    show_banner
    echo ""

    local choice
    choice=$(gum choose --height 16 --cursor.foreground 212 \
      "🚀  Desplegar lab" \
      "💣  Destruir lab" \
      "☢️   Nuke — empezar desde cero" \
      "📊  Estado del lab" \
      "🗺   Ver topología" \
      "🎬  Ejecutar demo individual" \
      "⏩  Ejecutar todos los demos" \
      "🔌  Conectar a un nodo" \
      "🔍  Comandos útiles" \
      "🔧  Verificar dependencias" \
      "⬆️   Gestionar gum" \
      "❌  Salir")

    case "${choice}" in
      *"Desplegar"*)            deploy_lab ;;
      *"Destruir"*)             destroy_lab ;;
      *"Nuke"*)                 nuke_lab ;;
      *"Estado"*)               show_lab_status ;;
      *"topología"*)            show_topology ;;
      *"demo individual"*)      run_demo ;;
      *"todos los demos"*)      run_all_demos ;;
      *"Conectar"*)             connect_node ;;
      *"Comandos"*)             useful_commands ;;
      *"Verificar"*)            check_dependencies; gum input --placeholder "Enter para volver al menú..." >/dev/null 2>&1 || read -rp "" ;;
      *"gum"*)                  manage_gum ;;
      *"Salir"*)                echo ""; gum style --foreground 99 "¡Hasta la próxima!"; exit 0 ;;
    esac
  done
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────

ensure_gum
main_menu
