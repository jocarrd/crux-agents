#!/usr/bin/env bash
# Hook de Claude Code (SessionStart).
#
# Al abrir una sesión, pone la máquina al día con el remoto: los repos que van
# por detrás, los proyectos creados desde otro ordenador y el kernel. Lo que
# imprime entra en el contexto del agente, así que solo habla si algo cambió o
# pide una decisión.
#
# Existe porque al alternar de ordenador se empezaba a trabajar sobre el código
# de la última vez que se usó esa máquina, sin que nada lo advirtiera.

set -u

kernel="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
[[ -f "$kernel/bin/sync.sh" ]] || exit 0
bash "$kernel/bin/sync.sh" --hook 2>/dev/null || true
exit 0
