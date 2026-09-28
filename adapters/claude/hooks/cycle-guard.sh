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
# Lo es el propio kernel, un docs repo, o cualquier repo que viva bajo la raíz
# de proyectos. La raíz sale de la configuración, no de una carpeta asumida: en
# una máquina con otra convención esto no fallaba, simplemente no hacía nada, y
# el sistema parecía vigilado sin estarlo.
#
# Antes se exigía además el layout <raíz>/<proyecto>/<repo> con su docs repo al
# lado, y eso dejaba fuera a los repos sueltos de la raíz: cinco en la máquina
# donde se midió. El estándar ya dice qué hacer sin contrato —un repo sin
# crux.json se trata como 'light'—, así que la ausencia de docs repo rebaja el
# rigor, no borra el repo del mapa. Medido el 17-09-2026 en personal-site:
# sin aviso, una sesión trabajó sobre la principal mientras otra fusionaba, y
# el push acabó en rebase.

raiz="${CRUX_PROJECTS_DIR:-}"
kernel=""
if [[ -f "$HOME/.crux/config" ]]; then
  kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$raiz" ]] || raiz="$(grep -E '^CRUX_PROJECTS_DIR=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  [[ -n "$raiz" || -z "$kernel" ]] || raiz="$(dirname "$kernel")"
fi

# Una barra de más en la configuración dejaba el patrón sin casar y el guarda
# callado en todas partes, que es el modo de fallo que este hook no puede tener.
raiz="${raiz%/}"

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || silencio
gestionado=0

[[ -n "$kernel" && "$toplevel" == "$kernel" ]] && gestionado=1

# En el docs repo se trabaja sobre la principal y se sube directo: ahí el
# aviso del ciclo sobra.
if [[ -f "$toplevel/crux.json" ]]; then
  case "$(basename "$toplevel")" in *-docs|docs) silencio ;; esac
fi

if [[ $gestionado -eq 0 && -n "$raiz" ]]; then
  case "$toplevel/" in
    "$raiz"/*/) gestionado=1 ;;
  esac
fi

# La salida para lo que no es tuyo aunque esté ahí: un clon ajeno que se deja
# bajo la raíz para leerlo. Rutas o patrones separados por ':' en la
# configuración. Sin la variable no hay nada que comprobar, que es el caso
# normal.
if [[ $gestionado -eq 1 ]]; then
  ajenos="${CRUX_UNMANAGED:-}"
  if [[ -z "$ajenos" && -f "$HOME/.crux/config" ]]; then
    ajenos="$(grep -E '^CRUX_UNMANAGED=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
  fi
  if [[ -n "$ajenos" ]]; then
    IFS=':' read -ra patrones <<< "$ajenos"
    for patron in "${patrones[@]}"; do
      [[ -n "$patron" ]] || continue
      # Sin comillas a propósito: el patrón puede traer comodines.
      # shellcheck disable=SC2053
      [[ "$toplevel" == $patron ]] && silencio
    done
  fi
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

# La marca va a ~/.crux/state y no a /tmp: el nombre llevaba dentro la ruta
# del repo, o sea el cliente y la tarea, en un directorio legible por
# cualquiera en la maquina y sin que nadie las limpiara nunca.
estado="$HOME/.crux/state"
( umask 077 && mkdir -p "$estado" ) 2>/dev/null || true
marca="$estado/cycle-guard-$(printf '%s' "$sesion-$toplevel" | \
  cksum | tr -d ' ' | tr -c 'A-Za-z0-9' '_')"
find "$estado" -name 'cycle-guard-*' -type f -mtime +2 -delete 2>/dev/null || true
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
