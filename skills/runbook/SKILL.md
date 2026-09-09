---
name: runbook
description: Escribir el procedimiento de un incidente que se acaba de resolver, con la forma que se puede ejecutar con el sistema caído — síntoma tal y como se reporta, cómo confirmarlo, los comandos, cómo verificar que se arregló y cuándo escalar. Usa justo después de arreglar algo en producción, cuando resolver un problema te haya costado reconstruir lo que ya sabías, o cuando alguien pregunte qué hacer si vuelve a pasar.
---

# runbook

Un runbook no se escribe para documentar un incidente. Se escribe **para que
la próxima vez no haya que pensar**.

> **Un runbook se mide por lo que tarda alguien con prisa en llegar del síntoma
> al comando.**

## Cuándo usar

- Justo después de resolver algo en producción. **Es el único momento bueno**:
  en frío te acuerdas de la causa, no de los tres comandos que descartaste.
- Cuando arreglar algo te ha obligado a redescubrir lo que ya sabías.
- Cuando alguien pregunta qué hacer si vuelve a pasar.

## Cuándo no usar

- **El problema tiene arreglo.** Un runbook para algo que se puede eliminar es
  aceptar que va a repetirse. Primero se pregunta si se arregla; el runbook es
  para lo que no depende de ti o no compensa arreglar.
- **El procedimiento se repite en varios proyectos.** Entonces lo que tienes es
  una skill. Tapa los nombres propios: si sigue teniendo sentido,
  hay un patrón.
- **Ha pasado una vez y no sabes por qué.** Lo que tienes es una anécdota.
  Anótala en las notas del repo y espera a la segunda.

## Las cinco partes

Ninguna es opcional. Las dos que se caen siempre son las dos que más duelen.

### 1. Síntoma

Cómo se ve **desde fuera**, con las palabras de quien lo sufre. "El login no
hace nada" antes que el nombre técnico del fallo: es lo que alguien teclea al
buscarlo, y quien lo busca todavía no sabe la causa.

Un runbook que se titula con su causa solo lo encuentra quien ya no lo
necesita.

### 2. Confirmar

Cómo distinguirlo de lo que se le parece. **Es el paso que más tiempo ahorra**
y el que más se omite, porque cuando lo escribes ya sabes cuál era el problema
y parece evidente.

No lo era. Si dos causas distintas dan el mismo síntoma, aquí es donde se
separan, y sin esta parte se aplica el remedio equivocado con toda confianza.

### 3. Actuar

Los comandos, en orden, copiables. **Cada paso es un comando, no una
historia.** Si un paso necesita un párrafo de explicación, o el paso está mal
elegido o la explicación va en otro sitio y el runbook enlaza.

Lo que hay que decidir sí se dice: qué mirar para elegir entre dos ramas, qué
valor es normal y cuál no.

### 4. Verificar

Cómo se sabe que se arregló, con una comprobación que se ejecuta. Sin esto se
declara resuelto lo que no lo está, se cierra el incidente y vuelve media hora
después.

Si el efecto tarda en propagarse —una caché, un DNS, un CDN—, se dice cuánto.

### 5. Escalar

Cuándo dejar de intentarlo. Un runbook sin salida convierte cada incidente en
una carrera sin línea de meta, y a las tres de la mañana eso es lo que
convierte una caída de diez minutos en una de dos horas.

Va con qué hacer entonces: a quién se avisa, qué se apaga, qué se dice.

## Procedimiento

1. **Recupera lo que acabas de hacer.** El historial del shell, no la memoria.
   Ahí están los comandos reales, incluidos los que no funcionaron.
2. **Quédate con el camino corto.** Lo que descartaste no va en `Actuar`; si
   descartarlo costó, va en `Confirmar` como forma de distinguir.
3. **Escribe el síntoma al final**, cuando ya sabes qué era, pero redáctalo
   como si no lo supieras.
4. **Comprueba los comandos.** Copiados del historial, con las rutas reales,
   sin abreviar. Un runbook con un comando que no corre es peor que ninguno.
5. **Enlázalo desde el índice por síntoma**, si el proyecto lo tiene. Un
   runbook que no aparece cuando buscas no existe.

## Dónde va

En `operations/` del docs repo del proyecto. Uno por fichero cuando el
procedimiento es largo; agrupados por sistema cuando son cortos y comparten
contexto.

El índice por síntoma —el playbook— es la puerta de entrada: lista qué se ve y
a qué runbook lleva. Es lo que se abre primero cuando algo falla.

## Anti-patterns

- **El runbook que explica.** Si empieza contando la arquitectura, se convirtió
  en documentación. La explicación va a `architecture/`.
- **El paso que dice "revisa los logs".** Revisar qué, dónde, buscando qué.
  Un paso que hay que interpretar no es un paso.
- **Escribirlo en frío, la semana siguiente.** Sale una reconstrucción
  plausible con los detalles cambiados. El detalle es justamente el valor.
- **El runbook que caduca en silencio.** Rutas, puertos y límites de terceros
  cambian. Si el proyecto marca la última verificación, se marca.

## Relacionado

- `/root-cause` — antes: entender qué pasa. Esto es después
- `/adr` — cuando lo aprendido cambia una decisión, no solo un procedimiento
- `/skill-creator` — cuando el procedimiento resulta valer para varios proyectos
