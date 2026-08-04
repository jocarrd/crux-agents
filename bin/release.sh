#!/usr/bin/env bash
# crux release — publicar una versión del kernel.
#
#   crux release <version>          enseña qué haría y verifica, sin tocar nada
#   crux release <version> --yes    etiqueta y publica
#
# El número de versión se sube en VERSION **por propuesta**, como cualquier otro
# cambio: este comando no commitea en la rama principal, solo comprueba que la
# versión ya está ahí y crea la etiqueta.
#
# Lo que distingue esto de un `git tag` es la tercera comprobación: **antes de
# publicar se verifica que los proyectos que consumen el kernel siguen
# conformes**. Cambiar el estándar y romper a quien lo usa sin enterarse es el
# fallo que un release debe impedir.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

# Publicar es una operación sobre el repositorio del kernel, no sobre la copia
# instalada: desde ella no hay ni git ni suite que ejecutar.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -z "$REPO" || ! -f "$REPO/test/run.sh" || ! -f "$REPO/STANDARD.md" ]]; then
  err "crux release se ejecuta desde el repositorio del kernel"
  info "estás en: $PWD"
  exit 1
fi

NUEVA="${1:-}"
[[ -n "$NUEVA" ]] || die "uso: crux release <version> [--yes]"
shift

CONFIRMADO=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) CONFIRMADO=1; shift ;;
    *) die "opción desconocida: $1" ;;
  esac
done

[[ "$NUEVA" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "la versión debe ser semver: 1.2.3"

ACTUAL="$(tr -d '[:space:]' < "$REPO/VERSION")"
ultimo_tag="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")"
version_mayor_que "$NUEVA" "${ultimo_tag:-0.0.0}" || die "$NUEVA no es posterior a la última publicada ($ultimo_tag)"

echo "release $ACTUAL → $NUEVA"
echo

FALLOS=0
fallo() { err "$*"; FALLOS=$((FALLOS + 1)); }

# --- 1. El repo del kernel ---------------------------------------------------

rama="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
[[ "$rama" == "main" ]] || fallo "estás en la rama $rama, no en main"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fallo "hay cambios sin commitear"
[[ -z "$(git -C "$REPO" log --oneline '@{u}..' 2>/dev/null)" ]] || fallo "hay commits sin pushear"
git -C "$REPO" rev-parse "v$NUEVA" >/dev/null 2>&1 && fallo "la etiqueta v$NUEVA ya existe"
[[ "$ACTUAL" == "$NUEVA" ]] || fallo "VERSION dice $ACTUAL: súbelo a $NUEVA por propuesta antes de etiquetar"
[[ $FALLOS -eq 0 ]] && ok "repo listo: main, limpio, al día y con VERSION en $NUEVA"

# --- 2. La suite -------------------------------------------------------------

# La suite prueba también este comando, así que sin esta guarda se llamarían
# el uno al otro sin fin.
if [[ -n "${CRUX_IN_TESTS:-}" ]]; then
  info "suite omitida: se está ejecutando desde la propia suite"
elif ( cd "$REPO" && ./test/run.sh >/tmp/crux-release-tests.$$ 2>&1 ); then
  ok "suite en verde ($(grep -oE '[0-9]+ aserciones' /tmp/crux-release-tests.$$ | tail -1))"
else
  fallo "la suite no pasa:"
  tail -5 /tmp/crux-release-tests.$$ | sed 's/^/      /'
fi
rm -f /tmp/crux-release-tests.$$

# --- 3. Los proyectos que consumen el kernel ---------------------------------
#
# Es la comprobación que justifica que esto sea un comando y no un `git tag`.

raiz="$(projects_root)"
consumidores=0
for docs in "$raiz"/*/*-docs; do
  [[ -f "$docs/crux.json" ]] || continue
  consumidores=$((consumidores + 1))
  nombre="$(basename "$docs")"
  if bash "$CRUX_HOME/bin/doctor.sh" "$docs" >/tmp/crux-release-doctor.$$ 2>&1; then
    ok "$nombre conforme"
  else
    fallo "$nombre deja de cumplir el estándar con esta versión:"
    grep -E "^error" /tmp/crux-release-doctor.$$ | head -5 | sed 's/^/      /'
  fi
  rm -f /tmp/crux-release-doctor.$$
done
[[ $consumidores -eq 0 ]] && warn "ningún proyecto consume el kernel en $raiz: nada que verificar"

# --- Notas -------------------------------------------------------------------

ultimo="$(git -C "$REPO" describe --tags --abbrev=0 2>/dev/null || echo "")"
rango="${ultimo:+$ultimo..}HEAD"

notas="$(git -C "$REPO" log --format='%s' "$rango" | node -e '
  const tipos = { feat: "Novedades", fix: "Arreglos", refactor: "Refactor",
                  docs: "Documentación", test: "Tests", chore: "Mantenimiento" };
  let d = "";
  process.stdin.on("data", (c) => (d += c)).on("end", () => {
    const grupos = new Map();
    for (const linea of d.split("\n").filter(Boolean)) {
      const m = linea.match(/^(\w+)(?:\([^)]*\))?!?:\s*(.+)$/);
      const tipo = m && tipos[m[1]] ? tipos[m[1]] : "Otros";
      const texto = m ? m[2] : linea;
      grupos.set(tipo, [...(grupos.get(tipo) || []), texto]);
    }
    // Orden fijo: lo que más le importa a quien actualiza va primero.
    const orden = ["Novedades", "Arreglos", "Refactor", "Documentación", "Tests", "Mantenimiento", "Otros"];
    const out = [];
    for (const t of orden) {
      if (!grupos.has(t)) continue;
      out.push(`### ${t}`, "", ...grupos.get(t).map((x) => `- ${x}`), "");
    }
    process.stdout.write(out.join("\n"));
  });
')"

echo
echo "Notas de la versión${ultimo:+ (desde $ultimo)}:"
echo
echo "$notas" | sed 's/^/  /'

# --- Publicar ----------------------------------------------------------------

echo
if [[ $FALLOS -gt 0 ]]; then
  err "$FALLOS comprobaciones fallan: no se publica"
  exit 1
fi

if [[ $CONFIRMADO -eq 0 ]]; then
  ok "todo listo para publicar $NUEVA"
  info "para hacerlo: crux release $NUEVA --yes"
  exit 0
fi

git -C "$REPO" tag -a "v$NUEVA" -m "$NUEVA

$notas"
git -C "$REPO" push -q origin "v$NUEVA"
ok "v$NUEVA publicada"

echo
info "los proyectos se alinean con 'crux upgrade' cuando les toque"
