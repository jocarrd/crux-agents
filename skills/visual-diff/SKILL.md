---
name: visual-diff
description: Medir objetivamente cuánto se desvía una salida renderizada (PDF, página, imagen) respecto a una referencia visual, con rejilla de celdas, error medio por celda, desenfoque previo contra el antialias, zonas con nombre semántico y superposiciones que revelan el desalineo. Usa cuando exista un diseño oficial contra el que comparar, cuando quieras un ranking de qué zonas están peor, o como red de seguridad tras una tanda de cambios de maquetación que la revisión a ojo no cubre.
---

# visual-diff

Responde a una pregunta concreta: **cuánto me desvío de la referencia, y
dónde**. Es la mitad medible del trabajo visual; la otra mitad, cuando no hay
referencia y el criterio es de una persona, es `/render-loop`.

## Cuándo usar cada una

| Situación | Herramienta |
| --------- | ----------- |
| Hay un diseño oficial contra el que comparar | **esta** |
| Antes de dar por buena una tanda de cambios | **esta** |
| Anotaciones subjetivas: "más grande", "más aire" | `/render-loop` |
| Confirmar que un cambio se aprecia | `/render-loop` |

## Uso

```bash
python3 <directorio-de-esta-skill>/scripts/imgdiff.py <actual> <referencia> \
  --out diff-out --grid 12x18 --blocks blocks.json
```

Acepta PDF —lo rasteriza con `pdftoppm`— o imágenes. Produce `report.md`
ordenado por desviación descendente, `scores.json` y una superposición por
página. Sale con código 1 si alguna celda supera el umbral, así que sirve
directamente como puerta en un hook o en CI.

Requiere `python3` con `numpy` y `Pillow`, y `poppler` para los PDF.

## Cómo funciona, y por qué así

1. **Rasteriza ambas salidas a la misma resolución** y ajusta la actual al
   tamaño de la referencia.
2. **Aplica un desenfoque previo.** Esto es lo que hace utilizable la
   comparación entre renderizadores distintos: sin él, el antialias domina la
   señal y todo parece diferente. Con él sobreviven los defectos reales de
   posición, tamaño y color.
3. **Divide en una rejilla y calcula el error medio absoluto por celda.** Un
   número por página no dice nada accionable; por celda, sí.
4. **Ignora las celdas casi blancas en ambas.** Son los márgenes: sin este
   filtro inflan la media y esconden los defectos reales.
5. **Etiqueta cada celda con su bloque semántico.** Un informe que dice "la
   cabecera está desplazada" es accionable; uno que dice "celda 3,7" obliga a
   ir a mirar el PNG para entender qué pasa.
6. **Genera la superposición.** Lo que coincide sale gris; el desalineo
   aparece como fantasma de color, azul donde solo hay contenido en el actual
   y cálido donde solo lo hay en la referencia.

## Los bloques semánticos

Un JSON con las zonas en coordenadas normalizadas de 0 a 1, opcionalmente por
página:

```json
[{"name": "cabecera",  "page": 1, "box": [0, 0, 1, 0.2]},
 {"name": "tarjeta-izquierda", "page": 1, "box": [0, 0.28, 0.55, 0.52]}]
```

Merece la pena escribirlo una vez: convierte el informe de una lista de
coordenadas en una lista de nombres que ya sabes dónde tocar.

## La regla que decide si la medición vale algo

**Fija los datos antes de comparar.** Si el render actual lleva datos
distintos a los de la referencia, estás midiendo contenido y no diseño, y
cualquier diferencia real queda enterrada bajo el ruido.

Lo normal es exponer un modo de la propia aplicación que rellene la salida con
los mismos datos que la referencia. Sin eso, el diff no es concluyente y no
conviene interpretarlo.

## Cobertura sistemática

Una comparación contra una referencia mide el caso que has renderizado. Si la
salida tiene lienzos de tamaño fijo —típico en informes y documentos—, **el
contenido que no cabe se recorta en silencio**, y la revisión a ojo solo
detecta lo que a uno se le ocurre mirar.

Por eso conviene acompañarla de una batería de escenarios que renderice los
casos límite: el texto más largo posible, valores extremos, campos vacíos,
todas las variantes de una etiqueta. Es la parte que hay que pasar sí o sí
después de tocar tipografías o espaciados.

## Falso positivo documentado

**Si aparecen artefactos —cabeceras negras, bloques mal compuestos— en unos
visores y no en otros, sospecha del renderizador antes que del diseño.** La
causa habitual es lanzar el navegador headless sin las mismas banderas que
usa el pipeline de producción.

Cualquier script de comparación debe replicar exactamente esas banderas. Esto
le costó una jornada completa a un equipo antes de documentarlo.

## Relacionado

- `/render-loop` — iterar cuando no hay referencia y el criterio es subjetivo
- `/visual-test` — inspección de páginas web en distintos viewports
