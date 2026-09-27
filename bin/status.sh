#!/usr/bin/env bash
# crux status — qué hay abierto ahora mismo, en todos los proyectos.
#
#   crux status            los proyectos, sus espacios y el trabajo sin publicar
#   crux status --check    además, pasa el doctor de cada proyecto; sale 1 si algo falla
#
# `doctor` responde por un proyecto. Esto responde por la mañana: dónde quedó
# el trabajo, qué espacios siguen vivos y qué no está subido a ningún sitio.
# Sin red: lo que no se puede saber en local no se pregunta.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"
source "$CRUX_HOME/lib/registry.sh"

COMPROBAR=0
[[ "${1:-}" == "--check" ]] && COMPROBAR=1

RAIZ="$(projects_root)"

echo "proyectos en $RAIZ"
echo

proyectos=0
PROBLEMAS=0
for docs in "$RAIZ"/*/*-docs; do
  [[ -f "$docs/crux.json" ]] || continue
  proyectos=$((proyectos + 1))
  nombre="$(basename "$(dirname "$docs")")"

  if ! motivo="$(json_valido "$docs/crux.json")"; then
    printf '  %-14s %s\n' "$nombre" "contrato ilegible — $motivo"
    info "arréglalo o mira qué le pasa: crux doctor $docs"
    PROBLEMAS=$((PROBLEMAS + 1))
    continue
  fi

  version="$(json_get "$docs/crux.json" crux 2>/dev/null || echo "?")"
  repos="$(json_get "$docs/crux.json" repos 2>/dev/null | wc -l | tr -d ' ')"

  estado=""
  if [[ $COMPROBAR -eq 1 ]]; then
    salida="$(bash "$CRUX_HOME/bin/doctor.sh" "$docs" 2>&1)" || PROBLEMAS=$((PROBLEMAS + 1))
    estado="$(echo "$salida" | tail -1)"
    [[ "$estado" == conforme* ]] && estado="conforme"
  fi
  printf '  %-14s crux %-8s %s repos%s\n' "$nombre" "$version" "$repos" "${estado:+  ·  $estado}"
done
[[ $proyectos -eq 0 ]] && info "ninguno bajo esa raíz ('install.sh --projects-dir' si no es la tuya)"

echo
echo "espacios de trabajo"
echo
bash "$CRUX_HOME/bin/workspace.sh" heal --quiet 2>/dev/null | sed 's/^/  /' || true
if [[ -f "$REGISTRY" ]]; then
  if [[ -z "$(registry_entries)" ]]; then
    echo "  ninguno"
  else
    while IFS=$'\t' read -r n ruta rama slot; do
      vivo=""; [[ -d "$ruta" ]] || vivo="  (sin worktree)"
      printf '  %-14s %-24s slot %s%s\n' "$n" "$rama" "$slot" "$vivo"
    done < <(registry_entries)
  fi

  # Un espacio cuya rama ya no está en el remoto casi siempre es trabajo
  # fusionado que nadie cerró. Sin red: se mira lo que git ya sabe del remoto.
  registry_entries | while IFS=$'\t' read -r n path rama _slot; do
    [[ -d "$path" ]] || continue
    seguimiento="$(git -C "$path" for-each-ref --format='%(upstream:track)' "refs/heads/$rama" 2>/dev/null || true)"
    if [[ "$seguimiento" == *gone* ]]; then
      warn "'$n': su rama ya no está en el remoto, probablemente fusionada — ciérralo con 'crux workspace rm $n'"
    fi
  done

  # Un worktree que crux no conoce no sale en ninguna lista ni lo protege nada.
  registrados="$(registry_paths)"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    printf '%s\n' "$registrados" | grep -qxF "$d" && continue
    es_worktree "$d" || continue
    warn "$(basename "$d") es un worktree que crux no conoce — regístralo: crux workspace adopt $d"
  done < <(find "$RAIZ" -maxdepth 2 -type d -name '*-ws-*' 2>/dev/null | sort)

  # Una propuesta abierta desde una rama sin recibo es el atajo tomado por la
  # espalda: legítimo si lo pidió una persona, pero tiene que verse. Sin esto,
  # rodear la puerta no dejaba rastro en ningún sitio.
  registry_entries | while IFS=$'\t' read -r n path rama _slot; do
    [[ -d "$path" ]] || continue
    command -v gh >/dev/null || break
    origen="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origen" ]] || continue
    slug="$(echo "$origen" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
    abierta="$(gh pr list --repo "$slug" --head "$rama" --state open --json number \
      --jq '.[0].number' 2>/dev/null || true)"
    [[ -n "$abierta" && "$abierta" != "null" ]] || continue
    recibo="$path/.crux-ship"
    head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
    sellado=""
    [[ -f "$recibo" ]] && sellado="$(awk '/^sealed /{print $2}' "$recibo" | tail -1)"
    if [[ "$sellado" != "$head" ]]; then
      warn "$slug#$abierta ($n) está abierta y su rama no tiene recibo de la puerta"
    fi
  done
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
  [[ "$sin_subir" -gt 0 ]] && detalle="$(cuenta "$sin_subir" commit commits) sin subir"
  [[ "$sucio" -gt 0 ]] && detalle="${detalle:+$detalle, }$(cuenta "$sucio" "fichero tocado" "ficheros tocados")"
  printf '  %-34s %-22s %s\n' "$nombre" "$rama" "$detalle"
done
if [[ $pendiente -eq 0 ]]; then
  echo "  nada: todo está subido"
fi

# --check existe para engancharlo a algo automático: tiene que poder fallar.
[[ $COMPROBAR -eq 1 && $PROBLEMAS -gt 0 ]] && exit 1
exit 0
