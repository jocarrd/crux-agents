#!/usr/bin/env bash
# Hook de Claude Code (UserPromptSubmit).
#
# Recuerda el ciclo cuando se va a trabajar sobre la rama principal de un repo
# gestionado. Una vez por sesión, y en silencio el resto del tiempo.
#
# No adivina por el texto del prompt: la señal es el estado —dónde estás y en
# qué rama—, que es determinista. Adivinar la intención por palabras acaba
# avisando cuando no toca y callando cuando sí.
#
# Existe porque medimos que no bastaba con describirlo: la skill del ciclo
# estaba escrita, instalada y con su descripción, y en 31 sesiones se invocó
# cero veces. Una descripción compite por atención; un hook llega solo.

set -u

entrada="$(cat 2>/dev/null || true)"

silencio() { exit 0; }

git rev-parse --git-dir >/dev/null 2>&1 || silencio

# En un espacio de trabajo ya se está haciendo lo correcto.
[[ "$PWD" == *-ws-* ]] && silencio

rama="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || silencio
principal="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[[ -n "$principal" ]] || principal=main
[[ "$rama" == "$principal" ]] || silencio

# --- ¿Es un repo que gestiona crux? ------------------------------------------
#
# Lo es el propio kernel, un docs repo, o cualquier repo de código que cuelgue
# de <raíz>/<proyecto>/<repo> con su docs repo al lado. La raíz sale de la
# configuración, no de una carpeta asumida: en una máquina con otra convención
# esto no fallaba, simplemente no hacía nada, y el sistema parecía vigilado sin
# estarlo.

raiz="${CRUX_PROJECTS_DIR:-}"
kernel=""
if [[ -f "$HOME/.crux/config" ]]; then
  kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$raiz" ]] || raiz="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$raiz" || -z "$kernel" ]] || raiz="$(dirname "$kernel")"
fi

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || silencio
gestionado=0

[[ -n "$kernel" && "$toplevel" == "$kernel" ]] && gestionado=1

# El docs repo también tiene cerrada su rama principal, así que también le toca
# el aviso: si no, el bloqueo aparece al hacer push y ya es tarde.
[[ $gestionado -eq 0 && -f "$toplevel/crux.json" ]] && gestionado=1

if [[ $gestionado -eq 0 && -n "$raiz" ]]; then
  case "$toplevel/" in
    "$raiz"/*/*/)
      rel="${toplevel#"$raiz"/}"
      proyecto="${rel%%/*}"
      [[ -f "$raiz/$proyecto/$proyecto-docs/crux.json" ]] && gestionado=1
      ;;
  esac
fi

[[ $gestionado -eq 1 ]] || silencio

# --- Una vez por sesión ------------------------------------------------------
#
# Repetirlo en cada turno lo convierte en ruido, y el ruido se aprende a
# ignorar antes que a obedecer.

sesion="$(printf '%s' "$entrada" | node -e '
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    try { process.stdout.write(String(JSON.parse(s).session_id || "")); } catch { }
  });
' 2>/dev/null || true)"
[[ -n "$sesion" ]] || sesion="$PPID"

marca="${TMPDIR:-/tmp}/crux-cycle-guard-${sesion}-$(echo "$toplevel" | tr -c 'a-zA-Z0-9' '-')"
[[ -e "$marca" ]] && silencio
: > "$marca"

cat <<EOF
Estás en '$rama', la rama principal de $(basename "$toplevel"), que es un repo
gestionado por crux. Si lo que viene es una tarea de desarrollo, el trabajo
entra por un espacio propio y sale como propuesta:

  crux workspace new <tarea>       rama, worktree y runtime aislados
  /ship                            la puerta antes de commitear
  crux workspace finish <tarea>    sube la rama y abre la propuesta

Aislar después de empezar obliga a mover cambios ya hechos entre ramas, que es
justo el lío que esto evita. Para preguntas, exploración o una errata, sigue
sin más: el ciclo no aplica a todo.
EOF
