---
name: skill-creator
description: Escribir una skill nueva que se descubra cuando toca y se pueda seguir sin ambigüedad: elegir su alcance, redactar el disparador, estructurar el procedimiento, decidir si lleva script y colocarla en el kernel o en el proyecto. Usa cuando quieras convertir en procedimiento algo que ya has hecho más de dos veces a mano, o cuando una skill existente no se esté activando cuando debería.
---

# skill-creator

Una skill es un procedimiento en markdown que un agente encuentra y sigue. Se
escribe una vez y se ejecuta muchas, así que merece la pena escribirla bien.

## Cuándo crear una

La regla es sencilla: **cuando lo hayas hecho a mano más de dos veces** y la
tercera hayas tenido que volver a averiguar algo que ya sabías.

Señales claras: reconstruiste unos comandos que ya habías usado, tropezaste con
el mismo gotcha, o le explicaste a alguien un procedimiento paso a paso.

No la crees para algo que solo has hecho una vez: todavía no sabes cuál es el
procedimiento, solo cómo salió esa vez.

## Lo primero: el disparador

La parte más importante de una skill **es la descripción**, por encima del
procedimiento. Es lo único que se lee para decidir si activarla, y una skill que
no se activa cuando toca es como si no existiese.

Una buena descripción tiene dos mitades:

1. **Qué hace**, en términos concretos y observables.
2. **Cuándo usarla**, con las situaciones y las palabras reales con las que
   aparece el problema.

```yaml
---
name: nombre-en-kebab-case
description: Qué hace, dicho de forma concreta. Usa cuando <situación 1>,
  cuando <situación 2>, o cuando <síntoma con las palabras del usuario>.
---
```

Escribe los síntomas **como los diría alguien que tiene el problema**, no como
los describirías tú que ya sabes la solución. Quien lo dice no sabe todavía que
necesita esta skill.

El `name` debe coincidir con el nombre del directorio. Una verificación lo
comprueba.

## La estructura del cuerpo

```markdown
# nombre

Una o dos frases: qué resuelve y cuál es la idea central.

## Cuándo usar / Cuándo no usar
## El procedimiento, por pasos
## Gotchas
## Anti-patterns
## Relacionado
```

**Repite el "cuándo usar" en el cuerpo**, aunque esté en el frontmatter: no
todos los agentes interpretan el frontmatter, y algunos leen la skill como
documento.

**"Cuándo no usar" vale tanto como "cuándo usar"** y casi nadie lo escribe. Es
lo que evita que se aplique un procedimiento caro a un caso trivial.

## Qué poner y qué no

| Sí | No |
| -- | -- |
| El porqué de cada paso no evidente | Narrar lo que el comando ya dice |
| Los gotchas que costaron tiempo | Teoría general que está en cualquier manual |
| Cómo verificar que funcionó | Pasos que el agente ya sabe hacer |
| Qué hacer cuando falla | Un tutorial de la herramienta |

**Los gotchas son el activo real.** El procedimiento feliz lo deduce cualquiera;
lo que no se deduce es que cierta capa de fabricante bloquea los toques, que
sin cancelar las animaciones la salida sale en blanco, o que la variante de
media manda sobre la clase base. Eso es lo que hay que escribir.

## ¿Lleva script?

Un script cuando el procedimiento tiene una parte **mecánica y exacta** que se
repite igual siempre: un cálculo, un formato, una comparación, una reserva de
recursos.

Prosa cuando lo que aporta es **criterio**: qué mirar, en qué orden, cómo
interpretar lo que sale.

Muchas skills buenas son las dos cosas: un script que hace la parte mecánica y
una prosa que explica cómo leer su resultado. Lo que no funciona es un script
que encapsula el criterio: se vuelve una caja negra que nadie ajusta.

## Neutralidad

Una skill que va a compartirse entre proyectos o agentes:

- **No menciona herramientas de un agente concreto.** Describe la acción a
  realizar, no quién la ejecuta. Es lo que hace que el mismo fichero sirva a
  varios.
- **No menciona proyectos concretos** si vive en el kernel. Los datos —rutas,
  credenciales, puertos, nombres— van en un adaptador del proyecto.

## Dónde colocarla

Aplica el test de la frontera:

> Tapa todos los nombres propios. Si el procedimiento sigue teniendo sentido y
> valor, hay un patrón: va al kernel, y en el proyecto queda un adaptador.

Si no, va en las skills del proyecto y ahí se queda.

### Si es un adaptador, tiene que repartir

Un adaptador y el procedimiento que adapta hablan del mismo trabajo, así que
van a compartir vocabulario: eso es inevitable y no es el problema. El problema
aparece cuando el adaptador **gana también las frases sin nombres propios**,
porque el catálogo es común a todos los proyectos y entonces gana en los
proyectos donde no aplica.

El reparto correcto son dos frases y dos ganadores:

| La frase | Quién debe ganar |
| -------- | ---------------- |
| Sin nombres propios | El procedimiento del kernel |
| Con los nombres propios del proyecto | El adaptador |

Se comprueba, no se supone:

```bash
node ~/.claude/skills/skill-audit/scripts/probe.mjs --adaptador \
  <adaptador> <skill-del-kernel> "<frase genérica>" "<frase con nombres propios>"
```

Si pierde la primera, el adaptador está robando y le sobra método en la
descripción: lo que aporta son rutas, credenciales, dispositivos y casos
límite, no el procedimiento otra vez. Si pierde la segunda, le faltan nombres
propios y no lo va a encontrar nadie.

Las dos frases se escriben **antes** de redactar la descripción, como se pediría
el trabajo de verdad. Sacarlas de la descripción ya escrita hace que pase
siempre y no prueba nada.

## Antes de darla por buena

- ¿La descripción contiene las palabras con las que aparece el problema?
  Compruébalo en vez de suponerlo, con una frase que no salga de la propia
  descripción:
  `node ~/.claude/skills/skill-audit/scripts/probe.mjs "la frase con la que lo pedirías"`.
  Si gana otra skill, o gana por menos del 15 %, la descripción no la distingue.
- ¿Un agente que no estuvo en la conversación podría seguirla sin preguntar?
- ¿Están los gotchas que te costaron tiempo, o solo el camino feliz?
- ¿Dice cómo verificar que funcionó?
- **¿La has ejecutado siguiendo lo que dice, en vez de lo que recuerdas?** Es la
  comprobación que revela los pasos que diste por supuestos.

## Anti-patterns

- **Descripción genérica.** "Ayuda con los despliegues" no se activa nunca.
- **Documentar la herramienta en vez del procedimiento.** El manual ya existe.
- **Escribirla desde la memoria sin ejecutarla.** Siempre falta un paso.
- **Una skill que hace tres cosas.** Se activa mal para las tres. Sepárala.
- **Dejarla sin mantenimiento.** Una skill que miente es peor que ninguna: se
  sigue con confianza.

## Relacionado

- `/skill-audit` — decide si una skill está en el sitio correcto
- `/promote-to-docs` — para lo que es conocimiento y no procedimiento
