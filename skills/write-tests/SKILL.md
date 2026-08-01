---
name: write-tests
description: Escribir tests que valgan la pena: elegir qué merece cobertura y qué no, cubrir el caso que duele antes que el feliz, mantenerlos deterministas y validarlos en negativo. Usa cuando añadas comportamiento nuevo, cuando arregles un bug y quieras que no vuelva, cuando vayas a refactorizar algo sin red, o cuando te pidan subir la cobertura.
---

# write-tests

Escribir tests es fácil. Escribir los que valen la pena, no.

## El criterio: testea lo que duele si falla

No se testea por cobertura, se testea por **consecuencia**. Antes de escribir
un test, pregunta qué pasa si eso se rompe en producción y nadie se entera.

| Merece test | No lo merece |
| ----------- | ------------ |
| Cálculos con reglas de negocio | Getters, mapeos triviales |
| Transformación de datos externos | Que un framework haga lo que promete |
| Casos límite y valores frontera | Que una constante valga lo que vale |
| Todo bug que ya ocurrió una vez | Detalles de implementación privados |
| Contratos entre módulos o servicios | Maquetación, salvo que sea medible |
| Lógica que un refactor va a mover | Código que va a desaparecer la semana que viene |

**Un test por cada bug real.** Es la regla con mejor retorno que existe: el bug
ya demostró que ese camino se rompe, así que la probabilidad de que vuelva no
es teórica.

## Empieza por el caso que duele

El camino feliz suele estar cubierto de rebote por el uso. Lo que nadie prueba
es lo otro:

- Vacío, nulo, cero, cadena vacía, lista vacía.
- El máximo y el mínimo, y uno más allá de cada uno.
- Entrada mal formada, en el formato equivocado, con acentos, muy larga.
- Duplicados, orden inverso, concurrencia.
- El error del servicio externo: timeout, 500, respuesta con la forma cambiada.

Si solo vas a escribir tres tests, que sean de aquí.

## Un test tiene que ser determinista

Un test que falla una de cada veinte veces es peor que no tenerlo: enseña al
equipo a reintentar sin mirar, y el día que falle de verdad nadie lo creerá.

Las cuatro fuentes de indeterminismo, y qué hacer con ellas:

| Fuente | Qué hacer |
| ------ | --------- |
| Tiempo y fechas | Inyectar el reloj, nunca leerlo dentro de la lógica |
| Aleatoriedad | Semilla fija, o inyectar el generador |
| Red y servicios externos | Dobles con respuestas fijas; el fixture es el contrato |
| Orden de ejecución y estado compartido | Cada test crea y destruye lo suyo |

## Valídalo en negativo

**Un test que no has visto fallar no sirve.** Es el error más común y el más
caro, porque produce confianza falsa.

Después de escribirlo: rompe a propósito lo que testea, comprueba que el test
se pone rojo por el motivo correcto —no por otro error—, y revierte. Treinta
segundos que te dicen si la red existe.

## Qué hacer cuando cuesta escribirlo

Un test difícil de escribir casi nunca es un problema del test: es el diseño
avisando. Si necesitas simular cinco dependencias para probar una función, esa
función hace cinco cosas.

Antes de montar el andamiaje, prueba a extraer la lógica pura y testear eso.
La parte que habla con el mundo se queda fina y sin lógica, y deja de necesitar
tests complicados.

## Nombres

El nombre del test es lo primero que se lee cuando falla en un log, meses
después. Que diga **la condición y lo esperado**, no el nombre de la función:

- Mal: `test_calcular`, `it("funciona")`
- Bien: `devuelve cero cuando la lista está vacía`,
  `rechaza la fecha si el fin es anterior al inicio`

## Antes de dar por buena una tanda

- ¿Falla alguno si rompo a propósito lo que prueban?
- ¿Pasan en orden aleatorio y en paralelo?
- ¿Pasan en una máquina limpia, sin tu caché ni tu base de datos?
- ¿Alguno tarda tanto que la gente va a empezar a saltárselos?

## Anti-patterns

- **Testear la implementación en vez del comportamiento.** Si el test se rompe
  con cada refactor sin que cambie nada observable, está mal escrito.
- **Un test gigante que lo prueba todo.** Cuando falla no sabes qué falló.
- **Aserciones de más.** Comprobar veinte campos por si acaso convierte
  cualquier cambio legítimo en un test roto.
- **Dobles que devuelven lo que le conviene al test.** Si el doble no se parece
  a la respuesta real, el test pasa y producción falla.
- **Escribir tests para subir un número.** La cobertura es una señal, no un
  objetivo. Se puede tener el 90% y no probar nada que importe.

## Relacionado

- `/ship` — las puertas 1 y 5, que son estos tests
- `/root-cause` — antes de escribir el test de un bug, entiende el bug
