#!/usr/bin/env bash
# crux doctor --machine — verifica que esta máquina puede ejecutar el sistema.
#
# Los proyectos se verifican con `crux doctor`. Esto verifica lo otro: las
# herramientas, autenticaciones y rutas de las que dependen las skills. Es la
# diferencia entre descubrir que falta algo ahora o a mitad de una incidencia.
#
# Lo imprescindible se reporta como error; lo que solo necesitan algunas
# skills, como aviso, diciendo qué se queda sin poder hacer.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ERRORS=0; WARNS=0
fail() { err "$*"; ERRORS=$((ERRORS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

tiene() { command -v "$1" >/dev/null 2>&1; }

necesario() {
  # necesario <comando> <para qué>
  if tiene "$1"; then ok "$1"; else fail "falta $1 — $2"; fi
}

opcional() {
  # opcional <comando> <qué se queda sin hacer>
  if tiene "$1"; then ok "$1"; else note "sin $1 — no podrás: $2"; fi
}

echo "verificando la máquina"
echo

# --- Imprescindible ----------------------------------------------------------

necesario git  "todo el sistema se apoya en git"
necesario node "los comandos del kernel leen el contrato con node"
necesario bash "los comandos del kernel son bash"

# --- El propio kernel --------------------------------------------------------

echo
CONFIG_MAQUINA="${CRUX_CONFIG:-$HOME/.crux/config}"
[[ -f "$CONFIG_MAQUINA" ]] && ok "config de máquina en $CONFIG_MAQUINA" \
  || fail "falta $CONFIG_MAQUINA — ejecuta install.sh"
tiene crux && ok "comando crux en el PATH" || note "crux no está en el PATH — añade ~/.local/bin"

SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
skills_enlazadas="$(ls "$SKILLS_DIR" 2>/dev/null | wc -l)"
skills_kernel="$(ls "$CRUX_HOME/skills" 2>/dev/null | wc -l)"
if [[ "$skills_enlazadas" -eq 0 ]]; then
  fail "ninguna skill materializada — ejecuta install.sh"
else
  ok "$skills_enlazadas skills disponibles ($skills_kernel en el kernel)"
fi

rotos="$(find "$SKILLS_DIR" -maxdepth 1 -xtype l 2>/dev/null | wc -l)"
[[ "$rotos" -gt 0 ]] && fail "$rotos enlaces de skill rotos — ejecuta install.sh"

# Un hook que apunta a un fichero inexistente no falla: no hace nada, y eso es
# peor, porque el sistema parece vigilado y no lo está.
AJUSTES="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if [[ -f "$AJUSTES" ]]; then
  hooks_rotos="$(node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let n = 0;
    for (const grupos of Object.values(s.hooks || {}))
      for (const g of grupos)
        for (const h of (g.hooks || [])) {
          const p = (h.command || "").replace(/^~/, process.env.HOME).split(" ")[0];
          if (p && !fs.existsSync(p)) n++;
        }
    process.stdout.write(String(n));
  ' "$AJUSTES" 2>/dev/null || echo 0)"
  [[ "$hooks_rotos" -gt 0 ]] && fail "$hooks_rotos hooks apuntan a ficheros que no existen — 'crux hooks status'"

  # Un hook roto se veía; ninguno, no. Y es el caso de una máquina nueva: se
  # instala el kernel, se traen los proyectos y no queda enganchado nada. Todo
  # lo que de verdad sostiene el estándar es automático, así que una máquina sin
  # hooks parece sana y no lo está.
  hooks_crux="$(node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let n = 0;
    for (const grupos of Object.values(s.hooks || {}))
      for (const g of grupos)
        for (const h of (g.hooks || []))
          if (/doc-sync|cycle-guard|memory-guard/.test(h.command || "")) n++;
    process.stdout.write(String(n));
  ' "$AJUSTES" 2>/dev/null || echo 0)"
  if [[ "${hooks_crux:-0}" -eq 0 ]]; then
    # Aviso y no error: `bootstrap` exige que esta comprobación pase, y es
    # precisamente él quien engancha los hooks al traer los proyectos. Un error
    # aquí dejaría una máquina nueva sin forma de arrancar.
    note "ningún hook de crux enganchado — 'crux hooks install'"
  else
    ok "$hooks_crux hooks de sesión enganchados"
  fi
else
  note "sin $AJUSTES: no hay ningún hook enganchado — 'crux hooks install'"
fi

# --- Lo que necesitan las skills --------------------------------------------

echo
opcional gh      "crear repos con crux init (usa --no-remote mientras tanto)"
if tiene gh; then
  gh auth status >/dev/null 2>&1 && ok "gh autenticado" || note "gh sin autenticar — 'gh auth login'"
fi

opcional python3 "visual-diff, render-loop y cualquier análisis de imagen"
if tiene python3; then
  python3 -c "import numpy, PIL" 2>/dev/null \
    && ok "numpy y Pillow" \
    || note "sin numpy o Pillow — no podrás: comparar ni medir imágenes"
fi

opcional pdftoppm "comparar PDFs con visual-diff"
opcional docker   "deploy-fallback y las bases de datos por espacio de trabajo"
opcional adb      "device-loop, probar en un dispositivo Android"
opcional rsync    "publicar una demo con crux stg"

if tiene google-chrome || tiene google-chrome-stable || tiene chromium; then
  ok "navegador para headless"
else
  note "sin Chrome ni Chromium — no podrás: visual-test"
fi

# --- Espacios de trabajo -----------------------------------------------------

registro="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
if [[ -f "$registro" ]]; then
  vivos="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const e = Object.entries(r.workspaces || {});
    const muertos = e.filter(([, w]) => !fs.existsSync(w.path)).map(([n]) => n);
    process.stdout.write(`${e.length}|${muertos.join(",")}`);
  ' "$registro" 2>/dev/null || echo "0|")"
  total="${vivos%%|*}"; muertos="${vivos#*|}"
  [[ "$total" -gt 0 ]] && ok "$(cuenta "$total" "espacio de trabajo registrado" "espacios de trabajo registrados")"
  [[ -n "$muertos" ]] && note "espacios en el registro sin directorio: $muertos — 'crux workspace gc'"

  # El registro y el disco también se separan al revés, y así no se ve nunca.
  raiz_ws="$(projects_root)"
  registrados="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(Object.values(r.workspaces || {}).map((w) => w.path).join("\n"));
  ' "$registro" 2>/dev/null || true)"
  sueltos=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registrados" | grep -qxF "$d" && continue
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
    sueltos=$((sueltos + 1))
  done < <(find "$raiz_ws" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null)
  [[ $sueltos -gt 0 ]] && note "$sueltos worktrees en disco que el registro no conoce — 'crux workspace gc'"
fi

# --- Resumen -----------------------------------------------------------------

echo
if [[ $ERRORS -eq 0 && $WARNS -eq 0 ]]; then
  echo "${C_GRN}lista${C_OFF} — esta máquina puede con todo"
else
  echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errores), $WARNS $([[ $WARNS -eq 1 ]] && echo aviso || echo avisos)"
  [[ $WARNS -gt 0 && $ERRORS -eq 0 ]] && echo "Los avisos no bloquean: solo limitan qué skills puedes usar."
fi
exit $(( ERRORS > 0 ? 1 : 0 ))
