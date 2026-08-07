#!/usr/bin/env python3
"""Lista todas las reglas CSS que tocan un selector, en orden de cascada.

    python3 reglas.py estilos.css "nombre-del-bloque"

El patrón es una expresión regular contra el selector. Se imprimen las reglas
en el orden en que aparecen, con la media query que las envuelve: la última que
coincide es la que manda.
"""
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)

ruta, patron = sys.argv[1], sys.argv[2]
lines = open(ruta).read().split("\n")

i = 0
media = []
depth = 0
while i < len(lines):
    stripped = lines[i].strip()

    if stripped.startswith("@media"):
        media.append((stripped.rstrip("{").strip(), depth))
        depth += lines[i].count("{") - lines[i].count("}")
        i += 1
        continue

    if stripped.endswith("{") and not stripped.startswith(("@", "/*")):
        abre = i
        inicio = i
        while inicio > 0 and lines[inicio - 1].strip().endswith(","):
            inicio -= 1
        sel = " ".join(l.strip() for l in lines[inicio : abre + 1])[:-1].strip()

        fin, d = abre, 0
        while fin < len(lines):
            d += lines[fin].count("{") - lines[fin].count("}")
            fin += 1
            if d == 0:
                break

        if re.search(patron, sel):
            marco = f"   [{media[-1][0]}]" if media else ""
            print(f"L{inicio + 1}{marco}")
            for k in range(inicio, fin):
                print("   " + lines[k])
        i = fin
        continue

    depth += lines[i].count("{") - lines[i].count("}")
    while media and depth <= media[-1][1]:
        media.pop()
    i += 1
