#!/usr/bin/env bash
# Hook de Claude Code (PreToolUse, Bash).
#
# Para un `git worktree remove` o un `rm -r` sobre un espacio de trabajo que
# crux tiene registrado, y dice qué usar en su lugar.
#
# Existe por lo que medimos: sesiones que liberaban disco con
# `git worktree remove --force` y `git branch -D` dejaron 41 entradas en el
# registro apuntando a carpetas que ya no existían. `crux workspace rm` retira
# la entrada, archiva la tarea si estaba terminada y se niega si queda trabajo
# sin commitear; el atajo no hace nada de eso. Ver ADR-013.

set -u

entrada="$(cat 2>/dev/null || true)"
[[ -n "$entrada" ]] || exit 0

registro="${CRUX_REGISTRY:-$HOME/.crux/workspaces.json}"
[[ -f "$registro" ]] || exit 0

resultado="$(printf '%s' "$entrada" | node -e '
  const fs = require("fs");
  let s = "";
  process.stdin.on("data", (d) => (s += d));
  process.stdin.on("end", () => {
    let cmd = "";
    try { cmd = String(JSON.parse(s).tool_input?.command || ""); } catch { process.exit(0); }
    // Lo que va detras de una almohadilla es un comentario, no un comando. Sin
    // esto el guarda saltaba con un texto que solo mencionaba las palabras.
    const util = cmd.replace(/(^|\s)#[^\n]*/g, " ");

    // Las formas de llevarse un directorio por delante, no solo la canonica:
    // rm -rf, rm --recursive, rm -f -r, y find ... -delete.
    const DESTRUYE = [
      /\bworktree\s+remove\b/,
      /\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*r)/,
      /\brm\b(?=[^\n]*--recursive)/,
      /\bfind\b(?=[^\n]*\s-delete\b)/,
      /\bfind\b(?=[^\n]*-exec\s+rm\b)/,
    ];
    const golpe = DESTRUYE.map((rx) => util.search(rx)).filter((i) => i >= 0);
    if (!golpe.length) process.exit(0);
    const desde = Math.min(...golpe);
    // Solo cuenta lo que va DESPUES del comando destructivo: mencionar la ruta
    // antes, en un cd o en un echo, no es borrarla.
    const cola = util.slice(desde);

    let r;
    try { r = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
    for (const [n, w] of Object.entries(r.workspaces || {})) {
      const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const fin = `(?=[\\s"'"'"';&|]|/?$|/[\\s"'"'"';&|])`;
      const base = w.path.split("/").pop();
      const porRuta = new RegExp(esc(w.path) + fin);
      const porNombre = new RegExp(`(^|[\\s/"'"'"'])${esc(base)}` + fin);
      if (porRuta.test(cola) || porNombre.test(cola)) {
        process.stdout.write(n);
        process.exit(0);
      }
    }
  });
' "$registro" 2>/dev/null)"

[[ -n "$resultado" ]] || exit 0

cat >&2 <<MSG
'$resultado' es un espacio de trabajo registrado en crux. Retirarlo a mano deja
su entrada en el registro y su tarea sin cerrar.

  crux workspace rm $resultado

Hace lo mismo, retira la entrada, archiva la tarea si ya está fusionada y se
niega si queda algo sin commitear.
MSG
exit 2
