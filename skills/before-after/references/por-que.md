# Por qué se enseña así

El procedimiento está en `SKILL.md`.

## Por qué una persona

Los tests no ven la pantalla, y la puerta 7 de `/ship` la pasa el agente. Aquí
aprueba una persona, y lo hace desde el móvil: por eso tres anchos, montajes
pegados y tramos que se descargan bien en un teléfono.

## Los mismos datos y el mismo script

Si el antes y el después se capturan de forma distinta, se comparan dos maneras
de capturar, no dos versiones.

## Por qué no se sube nada antes del sí

La propuesta es para lo aprobado. Proponer ya es enseñar el trabajo a otros, y
lo que se enseña para aprobar va antes. Si entra otro commit después del sí,
las capturas ya no enseñan lo que se propone.

## Los gotchas

- La captura de página completa agranda la ventana; la gráfica se redibuja desde
  cero y la foto sale con los ejes y sin datos. El script agranda, espera y
  después dispara.
- Con un servidor de desarrollo, una transición de vista que no termina deja al
  Chrome del sistema sin pintar nunca; el script prueba primero el navegador que
  trae Playwright.
- Una cookie de mentira no siempre basta para quitar el aviso de
  consentimiento, porque no es universal.
- La barra de navegación inferior de móvil aparece abajo del todo en la captura
  completa.

## Los anti-patrones

La mitad del tráfico es móvil y es donde se rompe. Sin el antes, la persona
tiene que recordar cómo era, y entonces no decide: opina.
