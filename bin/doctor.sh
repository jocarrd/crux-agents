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
fail() { err "$*"; ERRORS=$((ERRORS + 1)); }
note() { warn "$*"; WARNS=$((WARNS + 1)); }

# Un 'ok' solo se imprime si la sección no ha producido errores: decir "ok" y
# "error" de la misma comprobación es peor que no decir nada.
section() { SECTION_MARK=$ERRORS; }
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
for field in crux project profile; do
  json_has "$CONFIG" "$field" || fail "crux.json sin campo obligatorio: $field"
done

PROJECT="$(json_get "$CONFIG" project 2>/dev/null || echo "?")"
PROFILE="$(json_get "$CONFIG" profile 2>/dev/null || echo "?")"
DECLARED="$(json_get "$CONFIG" crux 2>/dev/null || echo "?")"
LANG_DECLARADO="$(json_get "$CONFIG" language 2>/dev/null || echo "es")"
KERNEL="$(crux_version)"

[[ -f "$CRUX_HOME/profiles/$PROFILE.json" ]] || fail "perfil desconocido: $PROFILE"
[[ "$DECLARED" == "$KERNEL" ]] || note "materializado con crux $DECLARED, el kernel es $KERNEL ('crux upgrade')"
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
declared=()
while IFS= read -r r; do [[ -n "$r" ]] && declared+=("$r"); done < <(json_get "$CONFIG" repos 2>/dev/null || true)

for repo in "${declared[@]:-}"; do
  [[ -n "$repo" ]] || continue
  [[ -d "$DOCS/repos/$repo" ]] || fail "repo declarado sin carpeta de doc: repos/$repo/"
  [[ -f "$DOCS/repos/$repo/README.md" ]] || note "repos/$repo/ sin README.md"
  [[ -d "$ROOT/$repo" ]] || note "repo declarado que no está en disco: $repo"
done

if [[ -d "$DOCS/repos" ]]; then
  for dir in "$DOCS"/repos/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    found=0
    for repo in "${declared[@]:-}"; do [[ "$repo" == "$name" ]] && found=1; done
    [[ $found -eq 1 ]] || note "repos/$name/ no está declarado en crux.json"
  done
fi
section_ok "repos: ${#declared[@]} declarados"

# --- 4. Reglas del perfil ----------------------------------------------------

section
WRITES_POINTERS="$(json_get "$CRUX_HOME/profiles/$PROFILE.json" 'pointers.write' 2>/dev/null || echo "true")"

if [[ "$WRITES_POINTERS" == "true" ]]; then
  for repo in "${declared[@]:-}"; do
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
  for repo in "${declared[@]:-}"; do
    [[ -d "$ROOT/$repo" ]] || continue
    for intruso in AGENTS.md CLAUDE.md; do
      [[ -e "$ROOT/$repo/$intruso" ]] && fail "perfil $PROFILE: $repo/$intruso no debería existir (código ajeno)"
    done
  done
fi
section_ok "reglas del perfil $PROFILE"

# --- 5. Secciones declaradas -------------------------------------------------

while IFS= read -r sect; do
  [[ -n "$sect" ]] || continue
  [[ -d "$DOCS/$sect" ]] || note "sección declarada sin carpeta: $sect/"
done < <(json_get "$CONFIG" sections 2>/dev/null || true)

# --- 6. Numeración de los ADRs ----------------------------------------------
#
# Dos sesiones en paralelo eligen el mismo "siguiente número" y el conflicto no
# lo detecta git: son líneas distintas del mismo fichero.

section
while IFS= read -r ledger; do
  [[ -f "$ledger" ]] || continue
  dup="$(grep -oE '^### ADR-[0-9]+' "$ledger" | sort | uniq -d | sed 's/^### //')"
  if [[ -n "$dup" ]]; then
    while IFS= read -r d; do
      fail "ADR duplicado en ${ledger#$DOCS/}: $d — renumera el más reciente"
    done <<< "$dup"
  fi
done < <(find "$DOCS/decisions" "$DOCS/repos" -name "*decisions*.md" -o -name "index.md" 2>/dev/null | grep -E "decisions" | sort -u)
section_ok "numeración de los ADRs"

# --- 7. Enlaces markdown -----------------------------------------------------

if node "$CRUX_HOME/lib/check-doc-paths.mjs" "$DOCS" >/tmp/crux-doctor-paths.$$ 2>&1; then
  ok "enlaces markdown resuelven"
else
  fail "enlaces markdown rotos:"
  sed 's/^/      /' /tmp/crux-doctor-paths.$$ | head -20
fi
rm -f /tmp/crux-doctor-paths.$$

# --- 8. Skills del proyecto --------------------------------------------------

section
skills=0
while IFS= read -r skill_md; do
  [[ -n "$skill_md" ]] || continue
  skills=$((skills + 1))
  name="$(basename "$(dirname "$skill_md")")"
  head -1 "$skill_md" | grep -q '^---$' || { fail "skill sin frontmatter: $name"; continue; }
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

# --- Resumen -----------------------------------------------------------------

echo
if [[ $ERRORS -eq 0 && $WARNS -eq 0 ]]; then
  echo "${C_GRN}conforme${C_OFF} — $(basename "$DOCS") cumple el estándar"
else
  echo "$ERRORS $([[ $ERRORS -eq 1 ]] && echo error || echo errores), $WARNS $([[ $WARNS -eq 1 ]] && echo aviso || echo avisos)"
fi
exit $(( ERRORS > 0 ? 1 : 0 ))
