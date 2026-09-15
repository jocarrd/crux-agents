#!/usr/bin/env bash
# crux doctor — verifica que un docs repo cumple el estándar.
#
# El estándar sirve de poco si solo se confía en que se cumple. Esto lo
# comprueba. Sale con código 1 si hay errores; los avisos no bloquean.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ERRORS=0
WARNS=0
SECTION_MARK=0
SECTION_WARNS=0
fail() { err "$*"; ERRORS=$((ERRORS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

# Un 'ok' solo se imprime si la sección no ha producido errores: decir "ok" y
# "error" de la misma comprobación es peor que no decir nada.
section() { SECTION_MARK=$ERRORS; SECTION_WARNS=$WARNS; }
section_ok() { [[ $ERRORS -eq $SECTION_MARK ]] && ok "$*"; return 0; }

if [[ "${1:-}" == "--machine" ]]; then
  exec bash "$CRUX_HOME/bin/machine.sh" "${@:2}"
fi

DOCS="$(find_docs_repo "${1:-$PWD}")" || die "no encuentro un docs repo desde ${1:-$PWD}"
CONFIG="$DOCS/crux.json"

echo "verificando $(basename "$DOCS")"
echo

# --- 1. El contrato ----------------------------------------------------------

if [[ ! -f "$CONFIG" ]]; then
  fail "falta crux.json — el proyecto no está adoptado ('crux adopt')"
  echo; echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errores), $WARNS $([[ $WARNS -eq 1 ]] && echo aviso || echo avisos)"; exit 1
fi

section
# Sin parar aquí, todo lo de abajo lee campos vacíos y los reporta como
# ausencias: errores falsos sobre lo que sí está.
if ! motivo="$(json_valido "$CONFIG")"; then
  fail "crux.json no es JSON válido: $motivo"
  echo; echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errores), $WARNS $([[ $WARNS -eq 1 ]] && echo aviso || echo avisos)"; exit 1
fi

for field in crux project profile; do
  json_has "$CONFIG" "$field" || fail "crux.json sin campo obligatorio: $field"
done

PROJECT="$(json_get "$CONFIG" project 2>/dev/null || echo "?")"
PROFILE="$(json_get "$CONFIG" profile 2>/dev/null || echo "?")"
DECLARED="$(json_get "$CONFIG" crux 2>/dev/null || echo "?")"
LANG_DECLARADO="$(json_get "$CONFIG" language 2>/dev/null || echo "es")"
KERNEL="$(crux_version)"

perfil_existe "$PROFILE" "$DOCS" || fail "perfil desconocido: $PROFILE"
# Solo la serie: un patch no trae plantillas ni comprobaciones, así que avisar
# por él manda a un upgrade que no cambia nada.
if [[ "${DECLARED%.*}" != "${KERNEL%.*}" ]]; then
  if version_mayor_que "$DECLARED" "$KERNEL"; then
    note "el proyecto va por delante del kernel ($DECLARED > $KERNEL): actualiza crux, no el proyecto"
  else
    note "materializado con crux $DECLARED, el kernel es $KERNEL ('crux upgrade')"
  fi
fi
[[ "$(basename "$DOCS")" == "$PROJECT-docs" ]] || note "el docs repo debería llamarse $PROJECT-docs"
section_ok "contrato: $PROJECT · perfil $PROFILE · crux $DECLARED"

# --- 2. Estructura obligatoria ----------------------------------------------

section
for f in README.md AGENTS.md decisions/README.md decisions/index.md repos/README.md; do
  [[ -f "$DOCS/$f" ]] || fail "falta $f"
done

if [[ -L "$DOCS/CLAUDE.md" ]]; then
  [[ "$(readlink "$DOCS/CLAUDE.md")" == "AGENTS.md" ]] || fail "CLAUDE.md debería enlazar a AGENTS.md"
elif [[ -f "$DOCS/CLAUDE.md" ]]; then
  note "CLAUDE.md es un fichero, no un symlink a AGENTS.md (dos fuentes que divergen)"
else
  fail "falta CLAUDE.md"
fi
section_ok "estructura obligatoria"

# --- 3. Repos declarados vs realidad ----------------------------------------

section
ROOT="$(dirname "$DOCS")"
origin_docs_early="$(git -C "$DOCS" remote get-url origin 2>/dev/null || true)"
declared=()
while IFS= read -r r; do [[ -n "$r" ]] && declared+=("$r"); done < <(json_get "$CONFIG" repos 2>/dev/null || true)

for repo in ${declared[@]+"${declared[@]}"}; do
  [[ -d "$DOCS/repos/$repo" ]] || fail "repo declarado sin carpeta de doc: repos/$repo/"
  [[ -f "$DOCS/repos/$repo/README.md" ]] || note "repos/$repo/ sin README.md"
  [[ -d "$ROOT/$repo" ]] || note "repo declarado que no está en disco: $repo"
done

if [[ -d "$DOCS/repos" ]]; then
  for dir in "$DOCS"/repos/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    found=0
    for repo in ${declared[@]+"${declared[@]}"}; do [[ "$repo" == "$name" ]] && found=1; done
    [[ $found -eq 1 ]] || note "repos/$name/ no está declarado en crux.json"
  done
fi

# El repo que está en disco y nadie declaró: se clona uno nuevo en el proyecto y
# se olvida el registro. Las comprobaciones de arriba van en la otra dirección
# —de lo declarado a lo que hay—, así que este caso pasaba como conforme.
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  [[ "$name" == "$(basename "$DOCS")" ]] && continue
  # Solo la raíz de un repo: dentro de un repo, cualquier subdirectorio
  # respondería que sí.
  toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$toplevel" && "$(cd "$dir" && pwd -P)" == "$(cd "$toplevel" && pwd -P)" ]] || continue
  # Los espacios de trabajo son worktrees hermanos: no son repos que declarar.
  es_worktree "$dir" && continue
  found=0
  for repo in ${declared[@]+"${declared[@]}"}; do [[ "$repo" == "$name" ]] && found=1; done
  [[ $found -eq 1 ]] || note "$name/ está en disco y no está declarado ('crux add-repo $name')"
done
# El repo que existe en el remoto y nadie clonó aquí: el bucle de arriba recorre
# el disco, así que un repo del proyecto que solo vive en GitHub es invisible en
# esta máquina, y así puede pasar medio año fuera del contrato sin que nadie
# se entere.
if [[ "$origin_docs_early" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  owner="$(echo "$origin_docs_early" | sed -E 's#^.*github\.com[:/]##; s#/.*$##')"
  while IFS= read -r remoto; do
    [[ -n "$remoto" ]] || continue
    [[ "$remoto" == "$(basename "$DOCS")" ]] && continue
    # Solo los que llevan el nombre del proyecto: el resto de la cuenta no es asunto suyo.
    shopt -s nocasematch
    if [[ "$remoto" == "$PROJECT" || "$remoto" == "$PROJECT-"* ]]; then
      found=0
      for repo in ${declared[@]+"${declared[@]}"}; do
        [[ "${repo,,}" == "${remoto,,}" ]] && found=1
      done
      [[ $found -eq 1 ]] || note "$remoto está en el remoto y no está declarado ('crux add-repo $remoto')"
    fi
    shopt -u nocasematch
  done < <(gh repo list "$owner" --limit 200 --json name --jq '.[].name' 2>/dev/null || true)
fi

section_ok "repos: ${#declared[@]} declarados"

# --- 4. Reglas del perfil ----------------------------------------------------

section
WRITES_POINTERS="$(perfil_get "$PROFILE" "$DOCS" pointers.write true)"

if [[ "$WRITES_POINTERS" == "true" ]]; then
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo" ]] || continue
    for fichero in AGENTS.md CLAUDE.md; do
      if [[ ! -f "$ROOT/$repo/$fichero" ]]; then
        note "$repo/ sin $fichero ('crux link')"
      elif ! grep -qF 'crux:begin' "$ROOT/$repo/$fichero"; then
        note "$repo/$fichero es anterior al bloque gestionado ('crux link --refresh')"
      fi
    done
  done
else
  # El perfil prohíbe escribir fuera del docs repo: comprobar que nadie lo hizo.
  #
  # Un AGENTS.md del propio cliente no es una intrusión: es material suyo, y
  # borrarlo sería justo lo que el perfil impide. La intrusión es el fichero que
  # pusimos nosotros, y se reconoce por el bloque gestionado o porque no está
  # versionado en su repo.
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo" ]] || continue
    for intruso in AGENTS.md CLAUDE.md; do
      fichero="$ROOT/$repo/$intruso"
      [[ -e "$fichero" ]] || continue
      if grep -qF 'crux:begin' "$fichero" 2>/dev/null ||
         ! git -C "$ROOT/$repo" ls-files --error-unmatch "$intruso" >/dev/null 2>&1; then
        fail "perfil $PROFILE: $repo/$intruso no debería existir (código ajeno)"
      else
        note "$repo/$intruso es del cliente — se respeta, no se toca"
      fi
    done
  done
fi
if [[ -n "$(perfil_get "$PROFILE" "$DOCS" rules "")" ]] &&
   ! grep -qF 'crux:begin perfil' "$DOCS/AGENTS.md" 2>/dev/null; then
  note "las reglas del perfil no están en AGENTS.md ('crux link')"
fi
section_ok "reglas del perfil $PROFILE"

# --- 5. Remoto declarado frente al real --------------------------------------
#
# Deriva silenciosa: todo funciona en esta máquina y el clonado falla en la
# siguiente, que es cuando menos ganas hay de depurarlo.

section
if ! git -C "$DOCS" rev-parse --git-dir >/dev/null 2>&1; then
  fail "el docs repo no está en git: la documentación no sobrevive al cambio de máquina"
elif json_has "$CONFIG" 'remote'; then
  for repo in ${declared[@]+"${declared[@]}"}; do
    [[ -d "$ROOT/$repo/.git" ]] || continue
    real="$(git -C "$ROOT/$repo" remote get-url origin 2>/dev/null || true)"
    [[ -n "$real" ]] || continue
    declarado="$(remote_url "$CONFIG" "$repo" 2>/dev/null || true)"
    if [[ -z "$declarado" ]]; then
      note "$repo: sin remoto en el contrato — 'crux clone' no sabrá de dónde traerlo"
    elif [[ "$(normalize_git_url "$declarado")" != "$(normalize_git_url "$real")" ]]; then
      note "$repo: el contrato dice $declarado y el origin es $real"
    fi
  done
  [[ $WARNS -eq $SECTION_WARNS ]] && section_ok "remoto coherente con el contrato"
else
  note "sin 'remote' en crux.json — 'crux clone' no podrá traer este proyecto"
fi

# --- 6. Visibilidad del docs repo --------------------------------------------
#
# Un docs repo público con documentación interna dentro es un incidente, no un
# descuido de configuración. Solo se puede comprobar donde hay API para
# preguntarlo; donde no, se dice que no se ha comprobado en vez de callar.

section
VIS_ESPERADA="$(json_get "$CONFIG" 'remote.visibility' 2>/dev/null || echo "private")"
origin_docs="$(git -C "$DOCS" remote get-url origin 2>/dev/null || true)"

if [[ "$origin_docs" == *github.com* ]] && command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  slug="$(echo "$origin_docs" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
  vis_real="$(gh repo view "$slug" --json visibility -q .visibility 2>/dev/null | tr 'A-Z' 'a-z' || echo "")"
  if [[ -z "$vis_real" ]]; then
    note "no pude consultar la visibilidad de $slug"
  elif [[ "$vis_real" == "public" && "$VIS_ESPERADA" != "public" ]]; then
    fail "el docs repo es PÚBLICO y el contrato espera $VIS_ESPERADA"
    [[ "$PROFILE" == "client-repo" ]] && err "y contiene documentación de un cliente"
  elif [[ "$vis_real" != "$VIS_ESPERADA" ]]; then
    note "visibilidad real '$vis_real', el contrato dice '$VIS_ESPERADA'"
  fi
  section_ok "visibilidad: $vis_real"
else
  info "visibilidad no comprobada (hace falta gh y un remoto de GitHub)"
fi

# --- 7. Secciones declaradas -------------------------------------------------

while IFS= read -r sect; do
  [[ -n "$sect" ]] || continue
  [[ -d "$DOCS/$sect" ]] || note "sección declarada sin carpeta: $sect/"
done < <(json_get "$CONFIG" sections 2>/dev/null || true)

# --- 8. Numeración de los ADRs ----------------------------------------------
#
# Dos sesiones en paralelo eligen el mismo "siguiente número" y el conflicto no
# lo detecta git: son líneas distintas del mismo fichero.

section
# El estado es lo que hace navegable el registro: un "Superseded" que no dice
# por quién corta la cadena justo donde alguien la estaba siguiendo.
decisions_out="/tmp/crux-doctor-decisions.$$"
node "$CRUX_HOME/lib/check-decisions.mjs" "$DOCS" >"$decisions_out" 2>&1
decisions_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    aviso:*) note "${line#aviso: }" ;;
    *) fail "$line" ;;
  esac
done <"$decisions_out"
if [[ $decisions_rc -gt 1 ]]; then
  fail "no se pudo verificar el estado de los ADRs"
fi
rm -f "$decisions_out"

section_ok "estado y numeración de los ADRs"

# --- 9. Enlaces markdown -----------------------------------------------------

if node "$CRUX_HOME/lib/check-doc-paths.mjs" "$DOCS" >/tmp/crux-doctor-paths.$$ 2>&1; then
  ok "enlaces markdown resuelven"
else
  fail "enlaces markdown rotos:"
  sed 's/^/      /' /tmp/crux-doctor-paths.$$ | head -20
fi
rm -f /tmp/crux-doctor-paths.$$

# --- 10. Skills del proyecto --------------------------------------------------

section
skills=0
while IFS= read -r skill_md; do
  [[ -n "$skill_md" ]] || continue
  skills=$((skills + 1))
  name="$(basename "$(dirname "$skill_md")")"
  head -1 "$skill_md" | grep -q '^---$' || { fail "skill sin frontmatter: $name"; continue; }
  # Sin la línea de cierre el frontmatter no es YAML válido y el agente carga
  # la skill entera como cuerpo, o no la carga.
  [[ "$(grep -c '^---$' "$skill_md")" -ge 2 ]] || { fail "skill con el frontmatter sin cerrar: $name"; continue; }
  grep -qE '^name:'        "$skill_md" || fail "skill sin 'name' en el frontmatter: $name"
  grep -qE '^description:' "$skill_md" || fail "skill sin 'description' en el frontmatter: $name"
  grep -qE '^name: *'"$name"'$' "$skill_md" || note "skill '$name': el 'name' del frontmatter no coincide con el directorio"

  # Una descripción sin situación de uso no se activa cuando toca: la skill
  # existe pero es invisible.
  # Solo el frontmatter: si se lee de más, el cuerpo de la skill contamina la
  # comprobación y esto nunca detecta nada.
  desc="$(awk '/^---$/{n++; next} n==1 && /^description:/{p=1} n==1 && p && /^[a-z_]+:/ && !/^description:/{p=0} n==1 && p{print} n>=2{exit}' "$skill_md" | tr '\n' ' ')"
  echo "$desc" | grep -qiE '\b(usa|use|úsala|usar|invoca)\b' \
    || note "skill '$name': la descripción no dice cuándo usarla — no se activará sola"

  # La descripción decide la activación, así que tiene que estar en el idioma en
  # que se pide el trabajo. Una mezcla activa peor justo donde más duele.
  if [[ "$LANG_DECLARADO" == "es" ]]; then
    n_en="$(echo "$desc" | grep -oiwE 'the|when|this|with|your|after|before|that|from|which' | wc -l)"
    n_es="$(echo "$desc" | grep -oiwE 'cuando|para|que|con|desde|antes|después|del|las|los|una' | wc -l)"
    [[ "$n_en" -gt "$n_es" ]] && note "skill '$name': la descripción parece estar en inglés y el proyecto declara español"
  fi
done < <(find "$DOCS/.claude/skills" -name SKILL.md 2>/dev/null | sort)
[[ $skills -gt 0 ]] && section_ok "skills del proyecto: $skills"

# --- 11. Credenciales escritas en la documentación ---------------------------
#
# Un secreto commiteado queda en el historial y en cada clon, también después de
# borrarlo. Esto no decide por nadie: dice dónde está para que sea una decisión
# y no un descuido, y por eso avisa en lugar de bloquear.

section
secretos_out="/tmp/crux-doctor-secretos.$$"
node "$CRUX_HOME/lib/check-secrets.mjs" "$DOCS" >"$secretos_out" 2>&1
secretos_rc=$?
if [[ $secretos_rc -gt 0 ]]; then
  note "no se pudo revisar la documentación en busca de credenciales"
else
  while IFS= read -r linea; do
    [[ -n "$linea" ]] || continue
    note "credencial en la documentación: $linea"
  done <"$secretos_out"
fi
[[ ! -s "$secretos_out" ]] && section_ok "sin credenciales a la vista en la documentación"
rm -f "$secretos_out"

# Un runbook con la marca puesta hace medio año no es falso, pero tampoco se
# sabe si sigue siendo cierto. Solo se mira operations/: es donde equivocarse
# cuesta caro y donde nadie lo nota hasta que el comando falla.
while IFS= read -r linea; do
  [[ -n "$linea" ]] || continue
  note "$linea"
done < <(node "$CRUX_HOME/lib/check-staleness.mjs" "$DOCS" 2>/dev/null || true)

# --- 12. Documentos que no enlaza nadie --------------------------------------
#
# Una doc que ningún índice menciona no la abre ningún agente: ocupa sitio,
# envejece y termina contradiciendo a la que sí se lee.

section
huerfanos=0
while IFS= read -r doc; do
  [[ -n "$doc" ]] || continue
  rel="${doc#$DOCS/}"
  base="$(basename "$doc")"
  # Un README es el índice de su propia carpeta: no lo enlaza nadie por diseño.
  [[ "$base" == "README.md" || "$base" == "AGENTS.md" || "$base" == "CLAUDE.md" ]] && continue
  if ! grep -rlF --include="*.md" "$base" "$DOCS" 2>/dev/null | grep -qv "^$doc$"; then
    note "nadie enlaza $rel — añádelo a un índice o bórralo"
    huerfanos=$((huerfanos + 1))
  fi
done < <(find "$DOCS" -name "*.md" -not -path "*/.git/*" -not -path "*/.claude/*" 2>/dev/null | sort)
[[ $huerfanos -eq 0 ]] && section_ok "todos los documentos están en un índice"

# --- 13. Deriva entre el código y la documentación ---------------------------
#
# No mide si falta documentar algo —eso no se sabe desde git—, sino si el
# código lleva moviéndose sin que la documentación se haya movido. Es la única
# parte auditable de la disciplina de §7: el resto lo sostiene la puerta de
# cierre, y esto es lo que permite ver después si la puerta se está saltando.

section
deriva_out="/tmp/crux-doctor-deriva.$$"
if node "$CRUX_HOME/lib/check-doc-drift.mjs" "$DOCS" >"$deriva_out" 2>/dev/null; then
  while IFS= read -r linea; do
    [[ -n "$linea" ]] || continue
    note "deriva código ↔ doc: $linea"
  done <"$deriva_out"
  [[ ! -s "$deriva_out" ]] && section_ok "documentación al día con el código"
else
  note "no se pudo medir la deriva entre código y documentación"
fi
rm -f "$deriva_out"

# --- 14. Servidores MCP declarados -------------------------------------------
#
# Solo la forma y la deriva: que lo declarado se pueda escribir, que no lleve
# credenciales dentro —el .mcp.json se commitea— y que lo que hay en los repos
# siga siendo lo que dice el contrato. Que el servidor responda no se pregunta
# aquí: es red, y el doctor tiene que tardar lo mismo y decir lo mismo con wifi
# y sin ella. Eso lo contesta `crux mcp status`, que se ejecuta cuando importa.

section
while IFS= read -r linea; do
  [[ -n "$linea" ]] || continue
  case "$linea" in
    error\ *) fail "mcp: ${linea#error }" ;;
    aviso\ *) note "mcp: ${linea#aviso }" ;;
    *)        note "mcp: $linea" ;;
  esac
done < <(node "$CRUX_HOME/lib/check-mcp.mjs" "$DOCS" 2>/dev/null || true)
if json_has "$DOCS/crux.json" 'mcp && Object.keys(root.mcp).length'; then
  section_ok "servidores MCP declarados y escritos donde tocan"
fi

# --- Resumen -----------------------------------------------------------------

echo
if [[ $ERRORS -eq 0 && $WARNS -eq 0 ]]; then
  echo "${C_GRN}conforme${C_OFF} — $(basename "$DOCS") cumple el estándar"
else
  echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errores), $WARNS $([[ $WARNS -eq 1 ]] && echo aviso || echo avisos)"
fi
exit $(( ERRORS > 0 ? 1 : 0 ))
