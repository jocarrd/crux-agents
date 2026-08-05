#!/usr/bin/env bash
# Hook de cierre de sesión (Stop).
#
# Avisa de las memorias que el estándar guarda en git y siguen solo en local.
# Silencioso mientras no haya ninguna.
#
# Vive en un hook y no en el ritual de cierre porque el ritual se invocaba en 2
# de 46 sesiones: la regla existía, la comprobación dependía de que alguien se
# acordase, y las memorias de proyecto se quedaban en una máquina.

set -u

kernel="${CRUX_HOME:-}"
if [[ -z "$kernel" && -f "$HOME/.crux/config" ]]; then
  kernel="$(grep -E '^CRUX_HOME=' "$HOME/.crux/config" | cut -d= -f2- | tr -d '"')"
fi
[[ -n "$kernel" && -f "$kernel/bin/memory.sh" ]] || exit 0

# Una línea, no el informe entero: esto se dispara en cada cierre de sesión, y
# un aviso que ocupa media pantalla se aprende a ignorar en dos días.
bash "$kernel/bin/memory.sh" --brief 2>&1

exit 0
