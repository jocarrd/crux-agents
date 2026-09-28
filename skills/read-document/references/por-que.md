# Por qué se lee así

El procedimiento está en `SKILL.md`.

## Los gotchas, con su porqué

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

