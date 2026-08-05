---
name: read-document
description: Poner en contexto un documento que no se puede abrir directamente —un Word, un PowerPoint, un Excel, un ODF, un EPUB o un PDF largo— convirtiéndolo a Markdown, eligiendo la vía correcta según el tipo y comprobando que no ha salido vacío. Usa cuando llegue un adjunto ofimático, cuando haya que leer una presentación o una hoja de cálculo, cuando un PDF sea demasiado largo para leerlo entero, o cuando alguien diga "mira este documento", "resume este informe" o "qué dice el adjunto".
---

# read-document

Un documento que no se puede abrir es un documento que no existe. Esta skill lo
convierte a Markdown para poder leerlo, citarlo y volver a él.

Lo que aporta no es el comando de conversión, que es una línea, sino tres
decisiones: **por qué vía**, **cómo saber que salió bien** y **qué se perdió por
el camino**.

## Cuándo usar

- Llega un adjunto `.docx`, `.pptx`, `.xlsx`, `.odt`, `.odp`, `.ods`, `.rtf`,
  `.epub` o `.csv`. Sin conversión no hay forma de leerlos.
- Un PDF es largo o está lleno de datos y hace falta el contenido, no la
  maquetación.
- Hay que citar literalmente un fragmento de un documento en la respuesta o en
  el código.

## Cuándo no usar

- **Un PDF que se juzga por cómo se ve**: un informe maquetado, un diseño, una
  factura cuya disposición importa. Ábrelo directamente, que conserva la
  maquetación. Convertirlo tira justo lo que hay que mirar.
- **Un documento del que solo hace falta un dato suelto** que ya se conoce y se
  puede buscar con una herramienta de texto.
- **Extraer campos estructurados a JSON**. Esto entrega Markdown; el trabajo de
  extracción es posterior y distinto.
- **Un escaneado o un documento fotografiado.** Aquí no hay texto que extraer:
  hace falta OCR, que es otra cosa. Ver el paso 3.

## 1. Elegir la vía

| Entrada | Vía | Por qué |
| --- | --- | --- |
| Ofimático (Word, PowerPoint, Excel, ODF, RTF, EPUB, CSV) | Convertir a Markdown | No hay alternativa: el fichero es un ZIP de XML |
| PDF con texto, largo o de datos | Convertir a Markdown | Sale con las tablas ya estructuradas y ocupa mucho menos que el volcado plano |
| PDF de maquetación o visual | Abrirlo directamente, sin convertir | La conversión tira la disposición, que es lo que se juzga |
| PDF escaneado o fotografiado | Ninguna: parar y decirlo | Sin capa de texto no hay nada que extraer |

## 2. Convertir

La herramienta de referencia es `anydoc`: un binario que lee los catorce
formatos y emite Markdown con un solo serializador, así que la salida es
consistente venga de donde venga. Licencia MIT, sin credenciales, sin servicio
externo para los formatos de texto.

```bash
npx -y @firecrawl/anydoc <fichero> -o <destino>.md
```

Guarda el resultado en un fichero temporal en vez de dejarlo solo en la
conversación: permite citarlo, buscar dentro y no reconvertir en cada vuelta.

Si la herramienta no está disponible, hay plan B según el formato, con pérdidas:

- PDF: el extractor de texto del sistema, con la disposición preservada. Sale
  mucho más largo y sin estructura de tabla.
- Ofimático: la suite de oficina en modo headless convierte a HTML o a texto.
  **No sabe convertir presentaciones a texto**: para ellas hay que pasar antes
  por PDF, y entonces se pierde el orden y las notas.

## 3. Comprobar que salió algo

**Este es el paso que evita el fallo caro**, y no es opcional.

```bash
wc -c <destino>.md
```

Contrasta el tamaño con lo que cabría esperar del documento. Un documento de
varias páginas que produce cuatro líneas no es un documento corto: es una
conversión fallida.

Si la herramienta avisa de que hace falta OCR, **para y dilo**. No sigas con
media conversión ni afirmes que el documento está vacío: no lo está, es que no
se puede leer así. Ofrece las salidas reales —pedir el original en otro
formato, o usar un servicio de OCR— y deja la decisión a quien pregunta.

## 4. Decir qué se perdió

Antes de trabajar sobre el Markdown, comprueba si la conversión se comió algo
que luego se vaya a necesitar, y avísalo:

- **Las presentaciones pierden la separación entre diapositivas.** El texto sale
  seguido, sin marca de dónde empieza cada una. Si después hay que citar "la
  diapositiva 4", esa referencia ya no existe.
- **Las tablas complejas de PDF salen descuadradas.** Celdas combinadas y
  cabeceras a varios niveles se reconstruyen mal: las columnas bailan. Sirve
  para leer, no para copiar cifras a ciegas.
- **Las imágenes, los gráficos y el color desaparecen.** Si el argumento del
  documento está en un gráfico, en el Markdown no queda nada de él.

## Gotchas

- **El extractor de texto plano falla en silencio con los escaneados.** Devuelve
  un fichero vacío y código de salida cero, así que un agente con prisa concluye
  "el documento no dice nada" y sigue adelante. La herramienta de referencia, en
  cambio, falla con código distinto de cero y explica que hace falta OCR. Es la
  razón principal para preferirla.
- **Un fichero puede estar vacío de verdad y no ser culpa de la conversión.**
  Antes de acusar a la herramienta, mira dentro: las presentaciones exportadas
  por algunas suites salen sin ninguna diapositiva. Comprueba el original antes
  de buscar otra herramienta.
- **La primera ejecución descarga el paquete.** Cuenta unos segundos y unos
  megas la primera vez; después queda en caché.
- **El CSV no tiene firma que lo identifique.** Si el contenido llega por
  entrada estándar, o el nombre no acaba en `.csv`, hay que declarar el formato
  a mano.
- **Los formatos de texto se procesan en local.** El OCR de escaneados, no: eso
  es un servicio de pago del fabricante. No lo asumas disponible.

## Anti-patterns

- **Convertir un PDF que había que mirar.** Si lo que se juzga es la maquetación,
  la conversión destruye la pregunta.
- **Resumir sin comprobar el tamaño de la salida.** Un resumen de una conversión
  vacía es una invención con formato de respuesta.
- **Citar la diapositiva o la página tras convertir.** Esas referencias no
  sobreviven al Markdown; si hacen falta, hay que volver al original.
- **Reconvertir en cada vuelta.** Guarda el Markdown y trabaja sobre él.

## Relacionado

- `/render-loop` — la dirección contraria: iterar sobre una salida renderizada
- `/visual-diff` — cuando lo que hay que comparar es cómo se ve, no qué dice
