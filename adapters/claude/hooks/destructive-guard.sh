#!/usr/bin/env bash
# Hook de Claude Code (PreToolUse, Bash y herramientas de ficheros).
#
# Para los comandos que destruyen trabajo sin vuelta atrás y la lectura de
# claves privadas y credenciales. Con los permisos del agente saltados, es el
# único freno que queda entre una deducción equivocada y un `reset --hard`.
#
# No sustituye a una persona: si alguien de verdad lo quiere, lo ejecuta él
# con `! <comando>` en la conversación, y entonces es una decisión. Adaptado de
# la política de guardias de Gentle Shell.

set -u

input="$(cat 2>/dev/null || true)"
[[ -n "$input" ]] || exit 0

verdict="$(printf '%s' "$input" | node -e '
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    let event;
    try { event = JSON.parse(raw); } catch { process.exit(0); }
    const tool = String(event.tool_name || "");
    const params = event.tool_input || {};

    // Claves privadas y credenciales. Las publicas (.pub) y los .env quedan
    // fuera: los primeros no son secretos y los segundos los mueve carry-env.
    const SECRET = [
      /(^|\/)\.ssh\/(?!.*\.pub$)(id_[^\/]*|[^\/]*_key|identity)$/,
      /\.(pem|p12|pfx)$/,
      /(^|\/)[^\/]*private[^\/]*\.key$/,
      /(^|\/)\.aws\/credentials$/,
      /(^|\/)\.config\/gh\/hosts\.ya?ml$/,
      /(^|\/)\.netrc$/,
    ];
    const isSecret = (p) => SECRET.some((rx) => rx.test(String(p).replace(/^~(?=\/)/, process.env.HOME || "~")));

    if (tool !== "Bash") {
      const path = params.file_path || params.notebook_path || params.path || "";
      if (path && isSecret(path)) out("secret", path);
      process.exit(0);
    }

    const command = String(params.command || "");
    // Lo que no se ejecuta no cuenta: comentarios, cuerpos de heredoc (los
    // mensajes de commit van ahi) y el texto entre comillas, salvo el que se
    // pasa a otra shell para que lo ejecute.
    const runnable = command
      .replace(/<<-?\s*([\x27"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, " ")
      .replace(/\b(bash|sh|zsh|eval)\s+(-c\s+)?(["\x27])([\s\S]*?)\3/g, " $4 ")
      .replace(/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/g, " \"\" ")
      .replace(/(^|\s)#[^\n]*/g, " ");

    const RULES = [
      [/\bgit\b[^;&|\n]*\breset\b[^;&|\n]*--hard\b/, "git reset --hard", "tira los cambios sin commitear", "git stash push -u -m \"<motivo>\", o un commit temporal"],
      [/\bgit\b[^;&|\n]*\bpush\b(?=[^;&|\n]*(\s--force(?!-with-lease)\b|\s-[A-Za-z]*f))/, "git push --force", "reescribe la historia remota sin comprobar lo que hay", "git push --force-with-lease"],
      [/\bgit\b[^;&|\n]*\bclean\b(?=[^;&|\n]*\s-[A-Za-z]*f)(?=[^;&|\n]*\s-[A-Za-z]*[dxX])/, "git clean -fd", "borra ficheros sin seguimiento, que git no puede recuperar", "git clean -n para ver antes qué borraría"],
      [/\bgit\b[^;&|\n]*\b(checkout\s+--|restore)\s+(\.|:\/)(?=\s|$)/, "descartar el árbol entero", "tira todos los cambios sin commitear del repo", "descarta fichero a fichero, después de mirar el diff"],
      [/\bgit\b[^;&|\n]*\bstash\s+clear\b/, "git stash clear", "la pila de stash es compartida entre worktrees y sesiones", "git stash drop <sha> del tuyo"],
      [/\brm\b(?=(?:\s+-{1,2}[A-Za-z-]+)*\s+-{0,2}[A-Za-z-]*[rR])[^;&|\n]*\s(\/|~|~\/|\$HOME|\$\{HOME\}|\$HOME\/|\.|\.\.|\*|\.\/\*)(?=[\s;&|]|$)/, "rm -r sobre /, ~, . o *", "se lleva por delante un directorio entero", "nombra la ruta exacta que quieres borrar"],
      [/\bchmod\s+-R\s+0?777\b/, "chmod -R 777", "abre todos los permisos de un árbol entero", "da solo el permiso que falta, al fichero que lo necesita"],
      [/\bchown\s+-R\b/, "chown -R", "cambia el dueño de un árbol entero", "cámbialo en la ruta concreta"],
      [/(^|[\s;&|(])(pkill|killall)\b/, "pkill / killall", "mata por nombre y se lleva procesos que no son tuyos", "busca el PID (pgrep -a <nombre>) y usa kill <PID>"],
    ];
    for (const [rx, name, why, instead] of RULES) {
      if (rx.test(runnable)) out("command", name, why, instead);
    }

    // Leer una clave privada desde la shell. Usarla (ssh -i, sshCommand) no
    // la vuelca en la conversacion, asi que eso se deja.
    const READERS = /\b(cat|less|more|head|tail|base64|xxd|od|strings|bat|cp|scp|rsync)\b([^;&|\n]*)/g;
    for (const m of runnable.matchAll(READERS)) {
      const hit = m[2].split(/\s+/).find((t) => t && isSecret(t));
      if (hit) out("secret", hit);
    }
    process.exit(0);

    function out(...fields) {
      process.stdout.write(fields.join("\t"));
      process.exit(0);
    }
  });
' 2>/dev/null)"

[[ -n "$verdict" ]] || exit 0

IFS=$'\t' read -r kind name why instead <<<"$verdict"

if [[ "$kind" == "secret" ]]; then
  cat >&2 <<MSG
'$name' es una clave privada o una credencial. Leerla la deja en la
conversación y en su registro.

Si hace falta usarla, úsala sin volcarla (ssh -i, gh auth). Si de verdad hay
que verla, que la abra una persona.
MSG
else
  cat >&2 <<MSG
Parado: $name $why.

En su lugar: $instead

Si una persona lo quiere tal cual, lo ejecuta ella con '! <comando>' en la
conversación.
MSG
fi
exit 2
