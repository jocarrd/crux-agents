#!/usr/bin/env bash
# crux merge — mergea una propuesta comprobando antes que es la que crees.
#
#   crux merge <numero> [--admin]
#
# `gh pr merge` resuelve el repositorio por el directorio en que estás, así que
# un número correcto en el sitio equivocado mergea la propuesta de otro
# proyecto sin preguntar nada. Aquí se dice en voz alta qué se va a mergear,
# dónde, y se para si algo no cuadra.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

NUM="${1:-}"
[[ -n "$NUM" ]] || die "uso: crux merge <numero de la propuesta>"
[[ "$NUM" =~ ^[0-9]+$ ]] || die "el número de la propuesta es un entero, no '$NUM'"

command -v gh >/dev/null || die "hace falta gh para hablar con el remoto"
gh auth status >/dev/null 2>&1 || die "gh no está autenticado"

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_DIR" ]] || die "esto no es un repositorio git"

origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
[[ -n "$origin" ]] || die "el repositorio no tiene origin: no sé a dónde mirar"
slug="$(echo "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"

datos="$(gh pr view "$NUM" --repo "$slug" --json title,state,headRefName,baseRefName,isDraft,mergeable 2>/dev/null || true)"
[[ -n "$datos" ]] || die "la propuesta #$NUM no existe en $slug — ¿estás en el repo correcto?"

titulo="$(echo "$datos" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).title))')"
estado="$(echo "$datos" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).state))')"
rama="$(echo "$datos" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).headRefName))')"
base="$(echo "$datos" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).baseRefName))')"
borrador="$(echo "$datos" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).isDraft))')"

echo "$slug#$NUM · $titulo"
echo "  $rama → $base"
echo

[[ "$estado" == "OPEN" ]] || die "la propuesta está $estado, no abierta"
[[ "$borrador" != "true" ]] || die "la propuesta es un borrador"

sucio="$(git -C "$REPO_DIR" status --porcelain | wc -l)"
[[ "$sucio" -eq 0 ]] || warn "hay $(cuenta "$sucio" fichero ficheros) sin commitear en el repo (no impide el merge)"

gh pr merge "$NUM" --repo "$slug" --merge --delete-branch "${@:2}"
