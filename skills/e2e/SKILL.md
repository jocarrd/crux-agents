---
name: e2e
description: Escribir y mantener tests end-to-end que no se abandonen: elegir los pocos flujos que de verdad los merecen, explorar la aplicación antes de escribir, hacerlos resistentes a los cambios de maquetación y arreglar el que se rompe en vez de desactivarlo. Usa cuando un flujo crítico no tenga red, cuando un fallo haya llegado a los usuarios sin que nadie se enterase, o cuando la suite existente esté desactivada porque falla sola.
---

# e2e

Los tests end-to-end son los más caros de escribir, los más lentos de ejecutar
y los únicos que prueban que **el sistema entero funciona junto**. Esa
combinación hace que casi todas las suites acaben desactivadas.

Esta skill va sobre no llegar ahí.

## El criterio, antes que la herramienta

> **Un flujo merece un e2e si su rotura te la cuenta un usuario y no un test.**

Esa es la pregunta, y descarta casi todo. Tres o cuatro flujos por producto,
no cuarenta:

- **Entrar.** Autenticación, sesión, permisos. Si esto se rompe, no importa
  nada más, y se rompe por causas que los tests unitarios no ven: una clave
  horneada en el build, un dominio mal configurado, una cookie.
- **La acción que genera el valor.** Publicar, comprar, enviar, reservar. La
  que si falla es una incidencia.
- **La superficie que no se puede simular.** Un mapa que renderiza, un pago,
  un documento que se genera.

Y lo que **no** merece e2e, aunque tiente: validaciones de formulario, textos,
estados vacíos, variaciones de una misma lista. Eso son tests unitarios o de
componente, que cuestan cien veces menos.

**Diez e2e que se ejecutan valen más que cuarenta desactivados.**

## El ciclo, en tres papeles

Es el patrón que ha cuajado en el sector, y funciona igual con o sin
herramientas específicas:

**1. Explorar y planificar.** Recorrer la aplicación funcionando y escribir en
markdown qué hace el flujo, paso a paso, con lo que se observa realmente. Este
plan se revisa **antes** de escribir nada: corregir un plan cuesta un minuto,
corregir una suite cuesta una tarde.

**2. Generar.** Convertir el plan revisado en tests ejecutables.

**3. Reparar.** Cuando uno falla: diagnosticar, proponer el arreglo y volver a
ejecutar. Un test roto es una de dos cosas, y hay que decidir cuál **antes** de
tocarlo: o el producto se rompió —y entonces el test hizo su trabajo— o el test
era frágil.

**Ninguno de los tres papeles produce algo que se pueda dar por bueno sin
mirarlo.** Aceleran la evidencia y el borrador; no la decisión.

## Que no se vuelvan frágiles

La fragilidad es la causa real de que las suites se abandonen. Cuatro reglas:

**Selecciona por rol y por texto visible, no por estructura.** Un selector
atado a la jerarquía de elementos o a clases de utilidad se rompe con cualquier
retoque de maquetación, sin que nada haya dejado de funcionar. Si un elemento
no se puede seleccionar por lo que es, ponle un atributo de test explícito: eso
es un contrato, no un parche.

**No metas esperas fijas.** Un tiempo de espera arbitrario es lento cuando
sobra y falla cuando falta. Espera a la condición: que el elemento esté, que la
petición termine, que el texto cambie.

**Cada test crea y destruye sus datos.** Un test que depende de que exista
cierto registro funciona hasta que alguien lo borra. Y dos tests que comparten
estado se rompen en cuanto se ejecutan en paralelo.

**Aísla lo que no controlas.** Servicios externos, pagos, correo. En e2e se
interceptan o se usa su entorno de pruebas: un test que falla porque una API
ajena está lenta no te dice nada de tu producto y enseña a ignorar los rojos.

## Dónde ejecutarlos

Si el proyecto tiene espacios de trabajo aislados, la suite va en el suyo:
puertos y datos propios. Compartir base de datos con tu entorno de desarrollo
es la forma más rápida de que un test te borre algo mientras trabajas.

## Sobre el coste

Hay integraciones que exponen el navegador al agente de forma muy cómoda. Antes
de adoptarlas conviene saber que **el consumo reportado ronda el cuádruple**
que hacer lo mismo por línea de comandos para una cobertura equivalente.

En un equipo grande puede compensar. Trabajando solo, el cuello de botella es
el coste por sesión: **usa el ciclo de tres papeles, pero por CLI**.

## Cuando uno falla en la puerta de commit

Un e2e rojo detiene el trabajo, así que la tentación de desactivarlo es alta.
La regla: **desactivar un e2e es una decisión que se registra**, con fecha y
motivo. Un test comentado sin explicación es deuda invisible; uno desactivado a
propósito y anotado es una decisión revisable.

## Anti-patterns

- **Cubrir el camino feliz de todo.** La cobertura amplia y superficial no
  atrapa nada y cuesta cada ejecución.
- **Escribir e2e para lógica.** Si se puede probar sin navegador, no es un e2e.
- **Arreglar el test sin preguntarse si el producto se rompió.** Es la forma de
  convertir una suite en decoración.
- **Suites que tardan tanto que se ejecutan solo de noche.** Lo que no se
  ejecuta al cambiar algo, no protege el cambio.

## Relacionado

- `/write-tests` — todo lo que se puede probar sin navegador, que es casi todo
- `/visual-test` — mirar la interfaz; complementaria y mucho más barata
- `/workspace` — el entorno aislado donde ejecutar la suite
- `/ship` — la puerta que decide cuándo hace falta llegar hasta aquí
