# runbooks/

Un fichero por **síntoma**, nombrado por cómo se reporta el problema
(`login-no-hace-nada-tras-desplegar.md`, `radar-tiles-mal-en-produccion.md`).
Aquí no hay un `runbook.md` genérico: los runbooks aparecen cuando un incidente
real se resuelve, no antes.

Un runbook se ejecuta con el sistema caído, así que **no explica, actúa**. La
anatomía, en este orden:

1. **Síntoma** — el título, tal y como se reporta.
2. **Confirmar que es esto** — un comando y qué se espera ver; cómo distinguirlo
   de lo que se le parece.
3. **Actuar** — los comandos, sin prosa.
4. **Verificar** — cómo se comprueba que se arregló, y cuánto tarda en propagar
   si hay caché o CDN de por medio.
5. **Escalar** — a quién se avisa y qué se apaga si sigue igual.
6. **Historial** — una línea por vez que pasó.

Para escribirlo en caliente justo después de resolver un incidente, usa la skill
`runbook`.
