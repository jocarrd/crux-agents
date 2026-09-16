#!/usr/bin/env bash
# Comprueba que un despliegue ha llegado y que sus rutas responden.
#
#   smoke.sh [--url <base>] [--expect <texto>] [--timeout <seg>] [ruta ...]
#
# Sin --url, lee del contrato del proyecto `deploy.url` y `deploy.paths`, o
# `deploy.repos.<repo>` si el proyecto tiene varios repos desplegables.
#
# --expect espera a que la primera ruta contenga un texto que solo tiene la
# versión nueva. Sin eso, un 200 no dice nada: puede estar respondiendo todavía
# la versión anterior mientras la nueva se construye.
#
# Salida: 0 todo responde · 1 alguna ruta falla · 3 la versión nueva no llegó.

set -uo pipefail

KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
source "$KERNEL/lib/common.sh"

URL=""; EXPECT=""; TIMEOUT=600; RUTAS=()
INTERVALO="${CRUX_SMOKE_INTERVAL:-10}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -*) die "opción desconocida: $1" ;;
    *) RUTAS+=("$1"); shift ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout son segundos enteros, no '$TIMEOUT'"
command -v curl >/dev/null || die "hace falta curl"

if [[ -z "$URL" ]]; then
  docs="$(find_docs_repo "$PWD")" || die "sin --url y sin crux.json del que leer deploy.url"
  contrato="$docs/crux.json"
  json_valido "$contrato" || die "$contrato no se puede leer como JSON"

  repo=""
  comun="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$comun" ]] && repo="$(basename "$(cd "$(dirname "$comun")" && pwd)")"

  rc=0
  bloque="$(node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const d = c.deploy;
    if (!d) process.exit(2);
    const b = (d.repos && d.repos[process.argv[2]]) || (d.url ? d : null);
    if (!b || !b.url) process.exit(3);
    console.log(b.url);
    for (const p of b.paths || ["/"]) console.log(p);
  ' "$contrato" "$repo")" || rc=$?
  case $rc in
    0) ;;
    2) die "el contrato no declara 'deploy': pásale --url o declara deploy.url en $contrato" ;;
    3) die "'deploy' no tiene url para el repo '${repo:-?}' en $contrato" ;;
    *) die "no se pudo leer 'deploy' de $contrato" ;;
  esac
  URL="$(echo "$bloque" | sed -n 1p)"
  if [[ ${#RUTAS[@]} -eq 0 ]]; then
    while IFS= read -r r; do [[ -n "$r" ]] && RUTAS+=("$r"); done < <(echo "$bloque" | sed -n '2,$p')
  fi
fi

URL="${URL%/}"
[[ "$URL" =~ ^https?:// ]] || die "la url tiene que empezar por http:// o https://, no '$URL'"
[[ ${#RUTAS[@]} -gt 0 ]] || RUTAS=("/")

cuerpo="$(mktemp)"; trap 'rm -f "$cuerpo"' EXIT

pedir() {
  # pedir <url>: deja el cuerpo en $cuerpo e imprime "código segundos"
  curl -sS -L --max-time 20 -o "$cuerpo" -w '%{http_code} %{time_total}' "$1" 2>/dev/null || echo "000 0"
}

if [[ -n "$EXPECT" ]]; then
  primera="$URL${RUTAS[0]}"
  inicio=$(date +%s)
  while :; do
    pedir "$primera" >/dev/null
    grep -qF -- "$EXPECT" "$cuerpo" && { ok "la versión nueva ya responde en $primera"; break; }
    if (( $(date +%s) - inicio >= TIMEOUT )); then
      err "tras ${TIMEOUT}s, $primera sigue sin contener «$EXPECT»"
      info "o el despliegue no ha terminado, o ha fallado y sigue la versión anterior"
      exit 3
    fi
    sleep "$INTERVALO"
  done
fi

fallos=0
echo "rutas en $URL"
for r in "${RUTAS[@]}"; do
  [[ "$r" == /* ]] || r="/$r"
  read -r codigo segundos <<< "$(pedir "$URL$r")"
  ms="$(awk -v s="$segundos" 'BEGIN { printf "%d", s * 1000 }')"
  if [[ "$codigo" == "000" ]]; then
    err "$r no responde"; fallos=$((fallos + 1)); continue
  fi
  if [[ "$codigo" -ge 400 ]]; then
    err "$r → $codigo (${ms} ms)"; fallos=$((fallos + 1)); continue
  fi
  # Un 200 con la página de error del framework dentro también es un fallo:
  # algunos sirven el error con código de éxito.
  if grep -qiE 'Application error: a (client|server)-side exception|Internal Server Error|__NEXT_ERROR__|Traceback \(most recent call last\)' "$cuerpo"; then
    err "$r → $codigo pero el cuerpo es una página de error (${ms} ms)"; fallos=$((fallos + 1)); continue
  fi
  if [[ "$ms" -gt 3000 ]]; then
    warn "$r → $codigo, lento: ${ms} ms"
  else
    ok "$r → $codigo (${ms} ms)"
  fi
done

[[ $fallos -eq 0 ]] || exit 1
exit 0
