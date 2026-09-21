#!/usr/bin/env bash
# crux stg — publica una carpeta construida en un staging con clave, para
# enseñar trabajo que todavía no está en producción.
#
#   crux stg deploy <nombre> <carpeta>   sube la carpeta y la publica
#   crux stg list                        qué demos hay vivas, con su clave
#   crux stg url <nombre>                el enlace, el usuario y la clave
#   crux stg rm <nombre>                 la retira
#
# El destino no vive aquí: se declara una vez por máquina en
# ~/.crux/staging.env. El kernel no sabe de qué VPS se trata, así que mover el
# staging a otro sitio es cambiar ese fichero y no este comando.
#
#   CRUX_STG_SSH        host ssh del servidor (un alias de ~/.ssh/config)
#   CRUX_STG_DOMAIN     dominio base; cada demo cuelga como <nombre>.<dominio>
#   CRUX_STG_ROOT       raíz en el servidor (contiene sites/ y caddy/)
#   CRUX_STG_CONTAINER  contenedor de Caddy al que se le pide recargar
#
# Cada demo trae su propio usuario y su propia clave: el usuario es su nombre.
# Compartir un par para todas hace que retirar una no le quite el acceso a
# nadie, que es justo lo que se espera al retirarla.
#
# Un despliegue no reinicia nada: escribe la carpeta, escribe el bloque y
# recarga la configuración, que Caddy valida antes de aplicar. Si el bloque
# está mal, la config viva se queda como estaba.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
# shellcheck source=lib/common.sh
source "$CRUX_HOME/lib/common.sh"

CONFIG="${CRUX_STG_CONFIG:-$HOME/.crux/staging.env}"
CLAVES="$HOME/.crux/staging"

cargar_config() {
  if [ ! -f "$CONFIG" ]; then
    err "no hay configuración de staging en $CONFIG"
    info "créala con las cuatro variables que documenta la cabecera de este comando:"
    info "  crux stg --help"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CONFIG"
  for v in CRUX_STG_SSH CRUX_STG_DOMAIN CRUX_STG_ROOT CRUX_STG_CONTAINER; do
    eval "valor=\${$v:-}"
    [ -n "$valor" ] || die "falta $v en $CONFIG"
  done
}

# El nombre es una etiqueta de dominio y el nombre de una carpeta remota: se
# acota a lo que es legal en las dos cosas para no tener que confiar en quien
# lo escribe.
valida_nombre() {
  case "$1" in
    *[!a-z0-9-]* | -* | *- | "") die "nombre no válido: '$1' — minúsculas, dígitos y guiones" ;;
  esac
}

en_servidor() { ssh -o BatchMode=yes "$CRUX_STG_SSH" "$@"; }

clave_de() {
  # La clave en claro se guarda solo aquí, para poder repetir el enlace sin
  # tener que rotarla. En el servidor vive el hash.
  local nombre="$1"
  local f="$CLAVES/$nombre.pass"
  if [ ! -f "$f" ]; then
    mkdir -p "$CLAVES"
    ( umask 077 && LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20 > "$f" )
  fi
  cat "$f"
}

bloque_caddy() {
  # No importa el snippet de otro proyecto: si alguien lo renombra, el staging
  # se cae y el motivo no se ve por ningún lado.
  local nombre="$1" hash="$2"
  cat <<EOF
# Generado por \`crux stg deploy $nombre\`. No editar a mano.
$nombre.$CRUX_STG_DOMAIN {
    encode zstd gzip

    basic_auth {
        $nombre $hash
    }

    # Es trabajo sin publicar: no se indexa aunque alguien reparta el enlace.
    header {
        X-Robots-Tag "noindex, nofollow, noarchive"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    root * /srv/staging/$nombre
    file_server
}
EOF
}

recargar() {
  # Validar antes de recargar: Caddy rechaza una config rota y deja la viva en
  # pie, pero el error se lee mejor aquí que en el log del contenedor.
  en_servidor "sudo docker exec $CRUX_STG_CONTAINER caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile" >/dev/null 2>&1 ||
    die "la configuración de Caddy no valida; no se ha recargado nada"
  en_servidor "sudo docker exec -w /etc/caddy $CRUX_STG_CONTAINER caddy reload --config /etc/caddy/Caddyfile" >/dev/null 2>&1 ||
    die "Caddy no aceptó la recarga"
}

cmd_deploy() {
  local nombre="${1:-}" carpeta="${2:-}"
  [ -n "$nombre" ] && [ -n "$carpeta" ] || die "uso: crux stg deploy <nombre> <carpeta>"
  valida_nombre "$nombre"
  [ -d "$carpeta" ] || die "no existe la carpeta $carpeta"
  [ -f "$carpeta/index.html" ] || warn "$carpeta no tiene index.html en la raíz"

  local clave hash
  clave="$(clave_de "$nombre")"
  # Por la entrada estandar y no como argumento: `sudo` deja el comando entero
  # escrito en /var/log/auth.log del servidor, para siempre, y mientras dura el
  # hash cualquiera con una sesion ahi la ve en `ps`.
  # Caddy pide la clave y su confirmación: con una sola línea responde
  # "Error: EOF". El `|| die` va en la propia asignación porque, con set -e, un
  # fallo ahí terminaba el script sin llegar a decir qué había pasado.
  hash="$(printf '%s\n%s\n' "$clave" "$clave" |
    en_servidor "sudo docker exec -i $CRUX_STG_CONTAINER caddy hash-password")" ||
    die "caddy no calculó el hash de la clave en $CRUX_STG_SSH"
  [[ "$hash" == \$2* ]] || die "caddy devolvió algo que no es un hash bcrypt: $hash"

  en_servidor "mkdir -p '$CRUX_STG_ROOT/sites/$nombre'"
  rsync -a --delete -e "ssh -o BatchMode=yes" "$carpeta"/ "$CRUX_STG_SSH:$CRUX_STG_ROOT/sites/$nombre/"

  bloque_caddy "$nombre" "$hash" | en_servidor "cat > '$CRUX_STG_ROOT/caddy/$nombre.caddy'"
  recargar

  local url="https://$nombre.$CRUX_STG_DOMAIN"
  ok "publicado $nombre"
  info "$url"
  info "usuario $nombre · clave $clave"
  local peso
  peso="$(du -sh "$carpeta" | cut -f1)"
  info "$peso subidos"
}

cmd_list() {
  local nombres
  nombres="$(en_servidor "ls -1 '$CRUX_STG_ROOT/sites' 2>/dev/null" || true)"
  if [ -z "$nombres" ]; then
    info "no hay ninguna demo publicada"
    return 0
  fi
  echo "$nombres" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    local f="$CLAVES/$n.pass"
    if [ -f "$f" ]; then
      echo "  https://$n.$CRUX_STG_DOMAIN  ·  $n / $(cat "$f")"
    else
      echo "  https://$n.$CRUX_STG_DOMAIN  ·  clave no guardada en esta máquina"
    fi
  done
}

cmd_url() {
  local nombre="${1:-}"
  [ -n "$nombre" ] || die "uso: crux stg url <nombre>"
  valida_nombre "$nombre"
  en_servidor "test -d '$CRUX_STG_ROOT/sites/$nombre'" || die "no hay ninguna demo llamada $nombre"
  echo "https://$nombre.$CRUX_STG_DOMAIN"
  if [ -f "$CLAVES/$nombre.pass" ]; then
    echo "usuario $nombre · clave $(cat "$CLAVES/$nombre.pass")"
  else
    warn "la clave no está guardada en esta máquina; regenérala con un deploy"
  fi
}

cmd_rm() {
  local nombre="${1:-}"
  [ -n "$nombre" ] || die "uso: crux stg rm <nombre>"
  valida_nombre "$nombre"
  en_servidor "rm -f '$CRUX_STG_ROOT/caddy/$nombre.caddy' && rm -rf '$CRUX_STG_ROOT/sites/$nombre'"
  recargar
  rm -f "$CLAVES/$nombre.pass"
  ok "retirada $nombre"
}

sub="${1:-}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  deploy) cargar_config; cmd_deploy "$@" ;;
  list)   cargar_config; cmd_list "$@" ;;
  url)    cargar_config; cmd_url "$@" ;;
  rm)     cargar_config; cmd_rm "$@" ;;
  *)      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; [ -z "$sub" ] && exit 0 || exit 1 ;;
esac
