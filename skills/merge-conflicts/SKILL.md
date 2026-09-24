---
name: merge-conflicts
description: Resolver un merge o un rebase que ha quedado a medias, hunk por hunk, por la intención de cada lado y no por lo que parezca correcto en la pantalla; después pasar las comprobaciones del repo y terminar la operación. Usa cuando git deje conflictos sin resolver, cuando un rebase se pare a mitad, cuando aparezcan marcadores `<<<<<<<` en los ficheros, o cuando el usuario diga que tiene un conflicto, que no sabe qué rama se queda o que se le ha liado el merge.
---

# merge-conflicts

Un conflicto no se resuelve leyendo las dos versiones y eligiendo la que se ve
mejor. Las dos se veían bien cuando se escribieron. Lo que hay que recuperar es
**por qué** se escribió cada una, y eso no está en el hunk.

**Nunca `--abort`.** Abortar tira el trabajo de entender el conflicto y lo deja
igual para la próxima vez. Si de verdad hay que abortar, lo decide el usuario.

## 1. Ver dónde estás

```bash
git status
git log --oneline --graph --left-right HEAD...MERGE_HEAD   # merge
git log --oneline REBASE_HEAD                              # rebase
git diff --name-only --diff-filter=U                       # ficheros en conflicto
```

En un rebase, `ours` y `theirs` van al revés de como los lees: `ours` es la
rama sobre la que rebasas, `theirs` es tu commit. Comprobar esto antes de
resolver nada evita resolver el conflicto entero del lado contrario.

## 2. Buscar la fuente primaria de cada lado

Por cada conflicto, averigua qué intención traía cada versión:

```bash
git log --oneline -3 <sha-de-ese-lado> -- <fichero>
git show <sha>                     # el commit completo, con su mensaje
gh pr list --search <sha> --state all   # la PR que lo trajo
```

El mensaje del commit, la PR y el issue valen más que el código. Si el commit
dice «fix: el middleware vuelve a cargar en Edge», ese cambio tiene un motivo
que no se ve en el diff y que se pierde si lo descartas.

**Si no encuentras la intención de un lado, pregunta.** Resolver a ciegas es la
forma de reintroducir el fallo que ese commit arreglaba.

## 3. Resolver hunk por hunk

- **Conserva las dos intenciones** siempre que se pueda. La mayoría de los
  conflictos son dos cambios compatibles que tocaron líneas vecinas.
- **Si son incompatibles**, gana el que cumple el objetivo declarado del merge,
  y el otro se anota como coste asumido.
- **No inventes comportamiento nuevo.** Un conflicto está para que sobrevivan
  dos cambios que ya existían. Mejorar el código de paso va en un commit
  aparte.
- **Los ficheros generados no se resuelven a mano.** `package-lock.json`,
  clientes de Prisma, snapshots: se regeneran. `git checkout --ours` sobre el
  fichero y después el comando que lo genera.

## 4. Pasar las comprobaciones del repo

Un merge resuelto compila pero no funciona más veces de las que parece: cada
lado era coherente por separado y la unión no.

Averigua qué comprueba el repo y ejecútalo, normalmente en este orden:
typecheck, tests, formato. En un repo con `/ship`, pásalo.

## 5. Terminar

```bash
git add -A && git commit        # merge: no reescribas el mensaje por defecto
git rebase --continue           # rebase: hasta que no queden commits
```

En un rebase pueden aparecer conflictos en varios commits seguidos. Vuelve al
paso 1 con cada uno.

---

*Adaptada de la skill `resolving-merge-conflicts` de
[mattpocock/skills](https://github.com/mattpocock/skills), licencia MIT.*
