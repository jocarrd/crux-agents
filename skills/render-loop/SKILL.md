---
name: render-loop
description: Iterar cambios de maquetación sobre una salida renderizada (PDF, documento, imagen generada, plantilla de correo) viendo el resultado real: renderizar sin navegador ni sesión, rasterizar, ampliar la zona tocada y comparar antes y después apilados. Usa cuando trabajes anotaciones subjetivas de diseño, cuando no haya una referencia contra la que medir, o cuando necesites confirmar visualmente que un cambio se aprecia y no solo que se aplicó.
---

# render-loop

Bucle corto para cambios de maquetación: **editar, renderizar, mirar,
ajustar**. Sirve cuando la referencia es el criterio de una persona.

Complementaria de `/visual-diff`, que mide contra una referencia. Si existe un
diseño oficial contra el que comparar, esa es la herramienta; esta es para
cuando no lo hay.

## 1. Un renderizador determinista, fuera de la aplicación

Lo primero es poder producir la salida **sin navegar la aplicación a mano**:
sin sesión, sin clicar, con los mismos datos cada vez. Normalmente significa
un script pequeño que acuñe la credencial que haga falta y llame a la ruta de
render directamente.

Tres cosas que ese script debe hacer, y que si faltan producen resultados
falsos:

**Replicar las banderas del pipeline de producción.** Si el render de
producción lanza el navegador headless con unas banderas concretas, el script
debe usar exactamente las mismas. Renderizar sin ellas produce artefactos
—cabeceras negras, composición distinta— que parecen defectos del diseño y no
lo son.

**Esperar a las tipografías.** Sin esperar a que estén listas, la salida usa
las de reserva y estás midiendo una fuente que nadie verá.

**Cancelar las animaciones.** Las bibliotecas de animación suelen arrancar con
opacidad cero y no completan en headless: la salida puede salir **en blanco**
sin ningún error.

## 2. Rasterizar

Convierte la salida a imagen a una resolución cómoda para mirar, no la máxima
posible. Para documentos multipágina, limita a la página que estás tocando.

## 3. Ampliar la zona tocada

Mirar la página entera no sirve para juzgar dos píxeles.

```bash
python3 <directorio-de-esta-skill>/scripts/inspect.py zoom pagina.png 40 290 310 440
```

Y después **abrir el PNG y mirarlo**. Ese es el paso que da valor a todo lo
demás; sin él esto es solo generar ficheros.

## 4. Comparar antes y después apilados

Imprescindible en cambios de tamaño: un salto de un píxel es medible pero
puede no ser visible hasta que se ven pegados.

```bash
python3 <directorio-de-esta-skill>/scripts/inspect.py stack antes.png ahora.png \
  --box 40 280 310 440
```

## 5. Forzar el peor caso antes de dar nada por bueno

Si la salida tiene lienzos de tamaño fijo, **el contenido que no cabe se
recorta sin avisar**. Validar con el ejemplo de siempre es insuficiente.

Antes de cerrar un cambio, identifica y fuerza los casos límite reales del
dominio: el texto más largo de todos los posibles, la etiqueta con más
caracteres, el campo vacío, el valor que no resuelve. Se fuerzan en los datos
locales y **se restauran después**.

Merece la pena dejar esa lista escrita en la documentación del proyecto: son
datos concretos —cuál es el texto más largo y cuántos caracteres tiene— que
nadie recuerda a los dos meses.

## 6. Medir la geometría real de los assets

**Posicionar o dimensionar una imagen por su caja no funciona, porque su caja
no es su contenido.**

```bash
python3 <directorio-de-esta-skill>/scripts/inspect.py asset public/logo.png
python3 <directorio-de-esta-skill>/scripts/inspect.py asset public/icono.svg
```

Reporta el margen transparente real de un PNG y la relación de aspecto
declarada de un SVG. Casos reales que costaron varios intentos cada uno: un
PNG con un 28% de transparencia arriba, cuyo contenido caía 85 px por debajo
de su coordenada; otro con un 27% a la derecha, que se veía un tercio más
pequeño de lo posible; un SVG de relación 3,44:1 metido en una caja cuadrada,
que se renderizaba a una franja.

**Mide el asset antes de tocar el número.**

## 7. Poner una guarda de regresión

Cuando una salida queda fuera del alcance de lo que estás cambiando pero puede
romperse sin querer, una huella la protege: renderiza, rasteriza, guarda el
hash de cada página y compara en cada ejecución. Encaja bien en un hook de
pre-push, tolerando que el entorno local no esté levantado.

**Una guarda que no se ha visto fallar no sirve.** Valídala siempre en
negativo: provoca el cambio, comprueba que salta, y revierte. Es la única
forma de saber que estás midiendo lo que crees.

## Aviso: la variante de media manda

Si el render fuerza un tipo de media —típicamente impresión—, **las reglas de
estilo específicas de esa media son las que se aplican**, no las de base.

Un cambio en la clase base puede no tener ningún efecto en la salida, y a la
vez parecer que la guarda de regresión está rota cuando en realidad funciona
bien. Al tocar una salida renderizada, cambia la variante correcta.

## Límite

Esto no detecta lo que no se te ocurra probar. Para cobertura sistemática tras
una tanda de cambios, `/visual-diff` con una batería de escenarios.

## Relacionado

- `/visual-diff` — medir contra una referencia
- `/visual-test` — inspección de páginas web en distintos viewports
