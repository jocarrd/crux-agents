# Cómo reparte alcance X, y por qué las reglas son estas

El procedimiento está en `SKILL.md`. Aquí están los datos en los que se apoya.

## El algoritmo publicado

X publicó el código de su feed "Para ti" en `github.com/xai-org/x-algorithm` y
se comprometió a actualizarlo cada cuatro semanas. Antes de una campaña
importante, comprueba el repositorio: los pesos cambian. Lo estable es esto:

- **El feed predice acciones y las pondera.** Cada post recibe la suma de
  "probabilidad de que hagas X × peso de X": responder, compartir por mensaje o
  copiando el enlace, citar, repostear, dar like, seguir al autor, hacer clic y
  tiempo de lectura, y también "no me interesa", silenciar, bloquear y denunciar.
- **Conversar pesa mucho más que un like.** En los pesos publicados en agosto de
  2026, una respuesta vale unas 10 veces un like. Compartir copiando el enlace,
  o una respuesta dentro de una conversación entre cuentas que se siguen, unas
  40. Seguir al autor, unas 8.
- **Lo negativo pesa muchísimo más.** Una denuncia resta lo que suman cientos de
  likes, y silenciar o "no me interesa", decenas. Un post que molesta a unos
  pocos hunde el alcance de muchos.
- **Fuera de tus seguidores llegas con descuento.** Los posts de cuentas que no
  sigues se multiplican por un factor menor que 1. Las cuentas pequeñas tienen
  un empujón hasta cierto umbral de impresiones.
- **Publicar seguido tiene rendimiento decreciente.** Cada post del mismo autor
  en el feed de una persona recibe un factor que decae. Dos posts buenos al día
  rinden más que cinco seguidos.
- **La vida útil es corta.** Los posts de más de 48 horas salen de la selección.
- **Un enlace en el cuerpo reduce el alcance.** No aparece como regla en el
  código, pero las mediciones de 2026 coinciden en una caída fuerte, mayor en
  cuentas sin Premium, porque un clic saca a la gente de X.

## Por qué un post, un objetivo

Si un post pide varias acciones a la vez, no consigue ninguna.

## Por qué la marca se construye así

La marca personal se construye enseñando el trabajo, no anunciándolo. La
promoción funciona cuando llega después de muchos posts que no pedían nada. La
continuidad hace que te sigan, porque seguirte es la forma de no perderse el
siguiente capítulo. Abrir con una situación o una persona, y no con el
producto, es lo que hace que alguien se pare.

## Por qué la primera línea

Decide si se lee el resto. Los ganchos que prometen sin dar ahuyentan a la
gente que buscas y cuentan como marcadores de contenido vacío.

## Por qué estas reglas de escritura

En el móvil un bloque de seis líneas se salta. Etiquetar a gente para que lo
vea, sin que el post trate de ellos, se lee como spam y provoca silencios. En
X delatan un texto generado sobre todo la raya larga, las enumeraciones de
tres, el paralelismo negativo y el tono de anuncio. Pedir interacción vacía
atrae interacción de baja calidad y lecturas de spam.

## Por qué la primera hora

Lo que pasa justo después de publicar decide el resto. La respuesta del autor
dentro de una conversación es de las señales que más pesan. Para una cuenta
pequeña, responder bien vale más que publicar mucho.

## Fuentes

- Código del feed de X: `github.com/xai-org/x-algorithm` (señales, puntuación,
  diversidad de autor, descuento fuera de la red, ventana de 48 horas).
- Pesos publicados en agosto de 2026, resumidos en explainx.ai ("X Discloses
  Ranking Weights").
- Mediciones sobre enlaces en el cuerpo del post: Social Media Today, OpenTweet
  (2026).
- Skills públicas de X revisadas: `sergebulaev/x-skills`,
  `alirezarezvani/claude-skills` (`x-twitter-growth`), `yamz8/x-thread-skill`.
- Build in public y marca personal: guías de Indie Hackers y Justin Welsh.
