#!/usr/bin/env bash
# crux status — qué hay abierto ahora mismo, en todos los proyectos.
#
#   crux status            los proyectos, sus espacios y el trabajo sin publicar
#   crux status --check    además, pasa el doctor de cada proyecto
#
# `doctor` responde por un proyecto. Esto responde por la mañana: dónde quedó
# el trabajo, qué espacios siguen vivos y qué no está subido a ningún sitio.
# Sin red: lo que no se puede saber en local no se pregunta.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

COMPROBAR=0
[[ "${1:-}" == "--check" ]] && COMPROBAR=1

RAIZ="$(projects_root)"
REGISTRY="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"

echo "proyectos en $RAIZ"
echo

proyectos=0
for docs in "$RAIZ"/*/*-docs; do
  [[ -f "$docs/crux.json" ]] || continue
  proyectos=$((proyectos + 1))
  nombre="$(basename "$(dirname "$docs")")"
  version="$(json_get "$docs/crux.json" crux 2>/dev/null || echo "?")"
  repos="$(json_get "$docs/crux.json" repos 2>/dev/null | wc -l | tr -d ' ')"

  estado=""
  if [[ $COMPROBAR -eq 1 ]]; then
    estado="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1 | tail -1)"
    [[ "$estado" == conforme* ]] && estado="conforme"
  fi
  printf '  %-14s crux %-8s %s repos%s\n' "$nombre" "$version" "$repos" "${estado:+  ·  $estado}"
done
[[ $proyectos -eq 0 ]] && info "ninguno bajo esa raíz ('install.sh --projects-dir' si no es la tuya)"

echo
echo "espacios de trabajo"
echo
if [[ -f "$REGISTRY" ]]; then
  node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const filas = Object.entries(r.workspaces || {});
    if (!filas.length) { console.log("  ninguno"); process.exit(0); }
    for (const [n, w] of filas) {
      const vivo = fs.existsSync(w.path) ? "" : "  (sin worktree)";
      console.log(`  ${n.padEnd(14)} ${w.branch.padEnd(24)} slot ${w.slot}${vivo}`);
    }
  ' "$REGISTRY"
else
  echo "  ninguno"
fi

echo
echo "trabajo sin publicar"
echo

pendiente=0
for repo in "$RAIZ"/*/*/; do
  repo="${repo%/}"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || continue
  git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || continue
  es_worktree "$repo" && continue

  nombre="$(basename "$(dirname "$repo")")/$(basename "$repo")"
  rama="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  sucio="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  sin_subir=0
  if git -C "$repo" rev-parse '@{u}' >/dev/null 2>&1; then
    sin_subir="$(git -C "$repo" log --oneline '@{u}..' 2>/dev/null | wc -l | tr -d ' ')"
  else
    sin_subir="$(git -C "$repo" log --oneline "$(rama_principal "$repo")..$rama" 2>/dev/null | wc -l | tr -d ' ')"
  fi

  [[ "$sucio" -eq 0 && "$sin_subir" -eq 0 ]] && continue
  pendiente=$((pendiente + 1))
  detalle=""
  [[ "$sin_subir" -gt 0 ]] && detalle="$sin_subir commits sin subir"
  [[ "$sucio" -gt 0 ]] && detalle="${detalle:+$detalle, }$sucio ficheros tocados"
  printf '  %-34s %-22s %s\n' "$nombre" "$rama" "$detalle"
done
if [[ $pendiente -eq 0 ]]; then
  echo "  nada: todo está subido"
fi
