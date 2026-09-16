#!/usr/bin/env bash
# crux checks — espera a las comprobaciones de una propuesta y dice por qué falla.
#
#   crux checks [<numero>] [--wait] [--timeout <segundos>] [--lines <n>]
#
# Abrir la propuesta no es terminarla: el CI corre después, y si nadie lo mira
# el rojo se descubre cuando alguien va a fusionar. Esto espera, y cuando algo
# falla trae solo el final del log del trabajo que falló: el log entero de un
# CI son miles de líneas, y leerlo cuesta más que arreglar el fallo.
#
# Salida: 0 todo en verde · 1 algo falla · 2 no hay comprobaciones · 3 se agotó
# el tiempo con comprobaciones pendientes.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

NUM=""; ESPERA=0; TIMEOUT=900; LINEAS=60
INTERVALO="${CRUX_CHECKS_INTERVAL:-15}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) ESPERA=1; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --lines) LINEAS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "opción desconocida: $1" ;;
    *) NUM="$1"; shift ;;
  esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout son segundos enteros, no '$TIMEOUT'"
[[ "$LINEAS" =~ ^[0-9]+$ ]] || die "--lines es un entero, no '$LINEAS'"
[[ -z "$NUM" || "$NUM" =~ ^[0-9]+$ ]] || die "el número de la propuesta es un entero, no '$NUM'"

command -v gh >/dev/null || die "hace falta gh para leer las comprobaciones"
gh auth status >/dev/null 2>&1 || die "gh no está autenticado"

if [[ -z "$NUM" ]]; then
  NUM="$(gh pr view --json number -q .number 2>/dev/null || true)"
  [[ -n "$NUM" ]] || die "no hay propuesta abierta para esta rama — pásale el número"
fi

leer() {
  # Se lee del rollup de la propuesta y no de `gh pr checks --json`, que no
  # existe en las versiones de gh que aún circulan. El rollup mezcla dos formas
  # —trabajos de CI y estados de terceros— y aquí se dejan en una sola.
  local salida rc=0
  salida="$(gh pr view "$NUM" --json statusCheckRollup 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "no se pudieron leer las comprobaciones de #$NUM (código $rc)" >&2
    echo "$salida" | head -5 | sed 's/^/      /' >&2
    return 1
  fi
  printf '%s' "$salida" | node -e '
    let d;
    try { d = JSON.parse(require("fs").readFileSync(0, "utf8")).statusCheckRollup; } catch { process.exit(3); }
    if (!Array.isArray(d)) process.exit(3);
    const bucket = (c) => {
      const s = String(c.status || "").toUpperCase();
      const r = String(c.conclusion || c.state || "").toUpperCase();
      if (c.__typename === "CheckRun" || c.status) {
        if (s && s !== "COMPLETED") return "pending";
        if (["SUCCESS"].includes(r)) return "pass";
        if (["SKIPPED", "NEUTRAL"].includes(r)) return "skipping";
        if (["CANCELLED", "STALE"].includes(r)) return "cancel";
        return "fail";
      }
      if (r === "SUCCESS") return "pass";
      if (r === "PENDING" || r === "EXPECTED") return "pending";
      return "fail";
    };
    const out = d.map((c) => ({ name: c.name || c.context || "?", bucket: bucket(c), link: c.detailsUrl || c.targetUrl || "" }));
    process.stdout.write(JSON.stringify(out));
  ' || { err "gh devolvió algo que no es el rollup de #$NUM" >&2; return 1; }
}

resumen() {
  node -e '
    const d = JSON.parse(process.argv[1]);
    const cuenta = (b) => d.filter((c) => c.bucket === b).length;
    process.stdout.write([d.length, cuenta("pass") + cuenta("skipping"), cuenta("fail") + cuenta("cancel"), cuenta("pending")].join(" "));
  ' "$1"
}

log_del_fallo() {
  # `gh run view --log-failed` sale vacío en versiones de gh que siguen en
  # las distribuciones, así que se pide el log del trabajo a la API y se
  # recorta aquí: lo que precede al último error, sin la limpieza del final.
  local job="$1" repo log
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || { echo "(no se pudo saber el repositorio para pedir el log)"; return 0; }
  log="$(gh api "repos/$repo/actions/jobs/$job/logs" 2>/dev/null)" \
    || { echo "(el log ya no está disponible)"; return 0; }
  # Por la entrada y no como argumento: un argumento no pasa de 128 KB en Linux,
  # y el log de un CI los supera con facilidad.
  printf '%s' "$log" | node -e '
    const lineas = require("fs").readFileSync(0, "utf8").split("\n").map((l) => l.replace(/^\S+Z /, ""));
    const n = Number(process.argv[1]);
    let fin = -1;
    lineas.forEach((l, i) => { if (l.includes("##[error]")) fin = i; });
    if (fin < 0) {
      const limpieza = lineas.findIndex((l) => l.startsWith("Post job cleanup"));
      fin = (limpieza > 0 ? limpieza : lineas.length) - 1;
    }
    // Las pilas de llamadas se comen el recorte y el mensaje queda fuera: se
    // dejan dos líneas de cada pila y se cuenta el resto.
    const compacto = [];
    let pila = 0;
    for (let i = fin; i >= 0 && compacto.length < n; i--) {
      if (/^\s*at /.test(lineas[i])) {
        pila++;
        if (pila === 3) compacto.push(`    … (pila de llamadas recortada)`);
        if (pila > 2) continue;
      } else {
        pila = 0;
      }
      // Una línea minificada puede tener miles de caracteres: sin recortar el
      // ancho, sesenta líneas se convierten en decenas de miles de tokens.
      compacto.push(lineas[i].length > 300 ? lineas[i].slice(0, 300) + " …" : lineas[i]);
    }
    console.log(compacto.reverse().join("\n"));
  ' "$LINEAS"
}

inicio=$(date +%s)
vacias=0
while :; do
  datos="$(leer)" || exit 1
  read -r total _ rojas pendientes <<< "$(resumen "$datos")"

  if [[ $total -eq 0 ]]; then
    # Recién abierta o recién empujada, la propuesta tarda en mostrar el CI
    # aunque ya esté en cola: con un minuto de margen se rendía antes de verlo.
    if [[ $ESPERA -eq 1 && $vacias -lt 12 ]]; then
      vacias=$((vacias + 1)); sleep "$INTERVALO"; continue
    fi
    warn "#$NUM no tiene comprobaciones automáticas"
    info "nada la bloquea no es lo mismo que verificada"
    exit 2
  fi

  [[ $ESPERA -eq 1 && $pendientes -gt 0 && $rojas -eq 0 ]] || break
  if (( $(date +%s) - inicio >= TIMEOUT )); then break; fi
  sleep "$INTERVALO"
done

echo "comprobaciones de #$NUM"
node -e '
  const d = JSON.parse(process.argv[1]);
  const orden = { fail: 0, cancel: 1, pending: 2, pass: 3, skipping: 4 };
  d.sort((a, b) => (orden[a.bucket] ?? 5) - (orden[b.bucket] ?? 5));
  // Lo que está en verde no necesita leerse de uno en uno: con cientos de
  // comprobaciones, listarlas era casi toda la salida.
  const verdes = d.filter((c) => c.bucket === "pass" || c.bucket === "skipping").length;
  for (const c of d.filter((c) => c.bucket !== "pass" && c.bucket !== "skipping")) {
    console.log(`      ${c.bucket.padEnd(9)} ${c.name}`);
  }
  if (verdes) console.log(`      ${verdes} en verde u omitidas`);
' "$datos"

if [[ $rojas -gt 0 ]]; then
  echo
  # Solo los trabajos de GitHub Actions dan su log por gh. Del resto —un
  # despliegue de un tercero— se da el enlace, que es donde está el motivo.
  fallos=()
  while IFS= read -r linea; do [[ -n "$linea" ]] && fallos+=("$linea"); done < <(node -e '
    const d = JSON.parse(process.argv[1]);
    for (const c of d.filter((c) => c.bucket === "fail" || c.bucket === "cancel")) {
      console.log([c.name, c.link || ""].join("\t"));
    }
  ' "$datos")
  mostrados=0
  for f in "${fallos[@]}"; do
    nombre="${f%%$'\t'*}"; enlace="${f#*$'\t'}"
    if [[ "$enlace" =~ /actions/runs/([0-9]+)/job/([0-9]+) && $mostrados -lt 2 ]]; then
      mostrados=$((mostrados + 1))
      echo "${C_DIM}── $nombre: últimas $LINEAS líneas del log ${C_OFF}"
      log_del_fallo "${BASH_REMATCH[2]}" | sed 's/^/      /'
    else
      err "$nombre"
      [[ -n "$enlace" ]] && info "$enlace"
    fi
  done
  exit 1
fi

if [[ $pendientes -gt 0 ]]; then
  warn "$pendientes comprobaciones siguen pendientes"
  [[ $ESPERA -eq 1 ]] && info "se agotaron los ${TIMEOUT}s de espera"
  exit 3
fi

ok "todas en verde"
exit 0
