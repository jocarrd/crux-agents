#!/usr/bin/env bash
# Lee las señales de producción que declara el proyecto y las resume.
#
#   signals.sh [--since <ventana>] [--all] [--max <n>] [fuente ...]
#
# Las fuentes se declaran en crux.json, en `observability.sources`: cada una es
# un comando de solo lectura con nombre. `{since}` se sustituye por la ventana
# (por defecto 1h).
#
# Un log de producción son miles de líneas casi iguales. Leídas tal cual no
# caben en ningún contexto, y lo que importa —qué error, cuántas veces, desde
# cuándo— se pierde entre ellas. Esto filtra lo que parece un problema y agrupa
# las líneas que solo cambian en números, fechas o identificadores.
#
# Salida: 0 leído (haya o no errores) · 1 no se pudo leer · 2 no hay fuentes.

set -uo pipefail

KERNEL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
source "$KERNEL/lib/common.sh"

SINCE="1h"; TODO=0; MAX=15; PEDIDAS=()
LIMITE="${CRUX_SIGNALS_TIMEOUT:-60}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --all) TODO=1; shift ;;
    --max) MAX="${2:-}"; shift 2 ;;
    -*) die "opción desconocida: $1" ;;
    *) PEDIDAS+=("$1"); shift ;;
  esac
done
[[ "$MAX" =~ ^[0-9]+$ ]] || die "--max es un entero, no '$MAX'"
[[ "$SINCE" =~ ^[0-9]+[smhd]$ ]] || die "--since es un número con s, m, h o d (1h, 30m), no '$SINCE'"

docs="$(find_docs_repo "$PWD")" || die "no encuentro el crux.json del proyecto"
contrato="$docs/crux.json"
json_valido "$contrato" || die "$contrato no se puede leer como JSON"

# Los comandos se ejecutan sin preguntar. El contrato es del propio equipo, así
# que no se bloquea, pero si alguien lo ha tocado sin commitear se dice antes.
if git -C "$docs" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && ! git -C "$docs" diff --quiet HEAD -- crux.json 2>/dev/null; then
  warn "$contrato tiene cambios sin commitear: se ejecutan sus comandos tal como están"
fi

rc=0
fuentes="$(node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const s = c.observability && c.observability.sources;
  if (!Array.isArray(s) || !s.length) process.exit(2);
  for (const f of s) {
    if (!f.name || !f.command) { process.stderr.write("una fuente sin name o sin command\n"); process.exit(3); }
    console.log([f.name, f.command].join("\t"));
  }
' "$contrato")" || rc=$?
case $rc in
  0) ;;
  2)
    warn "el proyecto no declara fuentes de producción"
    info "decláralas en $contrato → observability.sources: [{\"name\": ..., \"command\": ...}]"
    exit 2 ;;
  *) die "observability.sources de $contrato está mal formado" ;;
esac

leidas=0; fallidas=0
while IFS=$'\t' read -r nombre comando; do
  [[ -z "$nombre" ]] && continue
  if [[ ${#PEDIDAS[@]} -gt 0 && ! " ${PEDIDAS[*]} " == *" $nombre "* ]]; then
    continue
  fi
  comando="${comando//\{since\}/$SINCE}"

  echo "${C_DIM}── $nombre (últimas $SINCE) ${C_OFF}"
  salida_rc=0
  # </dev/null: un ssh leería la entrada del bucle y se comería las fuentes
  # que quedan por leer.
  salida="$(timeout "$LIMITE" bash -c "$comando" </dev/null 2>&1)" || salida_rc=$?
  if [[ $salida_rc -eq 124 ]]; then
    err "$nombre no respondió en ${LIMITE}s"; fallidas=$((fallidas + 1)); continue
  fi
  if [[ $salida_rc -ne 0 ]]; then
    err "$nombre falló con código $salida_rc"
    [[ -n "${salida//[[:space:]]/}" ]] && echo "$salida" | tail -3 | sed 's/^/      /'
    fallidas=$((fallidas + 1)); continue
  fi
  leidas=$((leidas + 1))

  # Por la entrada y no como argumento: un argumento no pasa de 128 KB en Linux,
  # y una hora de logs los supera.
  printf '%s' "$salida" | node -e '
    const texto = require("fs").readFileSync(0, "utf8");
    const todo = process.argv[1] === "1";
    const max = Number(process.argv[2]);
    const lineas = texto.split("\n").filter((l) => l.trim());
    const palabra = /\b(error|exception|fatal|panic|critical|crit|failed|failure|refused|timeout|timed out|unhandled|traceback|restarting|unhealthy|exited|oom|killed)\b/i;
    // Un 5xx solo cuenta con contexto de HTTP: un número suelto que empieza
    // por 5 es un tiempo, una coordenada o una versión de navegador.
    const http5xx = /(HTTP\/?[\d.]*\s+5\d\d\b|\bstatus(Code)?["\x27]?\s*[:=]\s*5\d\d\b|"\s5\d\d\s)/i;
    // En un log estructurado manda su nivel: una línea de info que menciona
    // la palabra "error" en una URL no es un error.
    const nivel = (l) => {
      const m = l.match(/"level"\s*:\s*("?)(\w+)\1/);
      if (!m) return null;
      const v = m[2].toLowerCase();
      if (/^\d+$/.test(v)) return Number(v) >= 50 ? "error" : "info";
      return ["error", "fatal", "critical", "crit", "panic"].includes(v) ? "error" : "info";
    };
    const problema = { test: (l) => {
      const n = nivel(l);
      if (n) return n === "error";
      return palabra.test(l) || http5xx.test(l);
    } };
    const elegidas = todo ? lineas : lineas.filter((l) => problema.test(l));
    if (!elegidas.length) {
      console.log(`      nada que parezca un problema en ${lineas.length} líneas`);
      process.exit(0);
    }
    // Dos líneas son el mismo problema si solo cambian en lo que cambia en
    // cada aparición: fechas, horas, números, identificadores y direcciones.
    const forma = (l) => l
      .replace(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?/g, "<fecha>")
      .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "<id>")
      .replace(/\b[0-9a-f]{12,}\b/gi, "<id>")
      .replace(/\b\d+(\.\d+){3}(:\d+)?\b/g, "<ip>")
      .replace(/\d+/g, "<n>")
      .trim();
    const grupos = new Map();
    for (const l of elegidas) {
      const k = forma(l);
      const g = grupos.get(k) || { n: 0, ejemplo: l.trim(), ultima: l.trim() };
      g.n++; g.ultima = l.trim();
      grupos.set(k, g);
    }
    const orden = [...grupos.values()].sort((a, b) => b.n - a.n);
    console.log(`      ${elegidas.length} líneas en ${grupos.size} grupos (de ${lineas.length} leídas)`);
    for (const g of orden.slice(0, max)) {
      console.log(`      ${String(g.n).padStart(5)}×  ${g.ultima.slice(0, 220)}`);
    }
    if (orden.length > max) console.log(`      … y ${orden.length - max} grupos más (--max para verlos)`);
  ' "$TODO" "$MAX"
done <<< "$fuentes"

if [[ $leidas -eq 0 ]]; then
  [[ $fallidas -gt 0 ]] && exit 1
  if [[ ${#PEDIDAS[@]} -gt 0 ]]; then
    die "ninguna fuente se llama así: ${PEDIDAS[*]}"
  fi
fi
[[ $fallidas -eq 0 ]] || exit 1
exit 0
