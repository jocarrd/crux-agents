// Formatos de credencial que no admiten discusión: si aparece uno, alguien pegó
// algo real. Se buscan estos y no "parece una contraseña" porque la
// documentación está llena de ejemplos, y un aviso que grita por cada
// `changeme-dev` enseña a ignorar los avisos.
//
// Viven aquí y no dentro de quien las usa porque hay dos verificadores que las
// necesitan —la documentación y los .mcp.json— y la primera vez que se copiaron
// las dos listas nacieron distintas: a una le faltaban tres huellas, entre ellas
// la de una URL con la contraseña dentro, y por ese hueco pasaba un secreto
// hasta git.

export const HUELLAS = [
  { nombre: 'clave publicable de Stripe/Clerk en vivo', rx: /\bpk_live_[A-Za-z0-9]{10,}/ },
  { nombre: 'clave secreta en vivo', rx: /\bsk_live_[A-Za-z0-9]{10,}/ },
  { nombre: 'token de GitHub', rx: /\bgh[pousr]_[A-Za-z0-9]{20,}/ },
  { nombre: 'clave de acceso de AWS', rx: /\bAKIA[0-9A-Z]{16}\b/ },
  { nombre: 'JSON Web Token', rx: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./ },
  { nombre: 'clave de API de OpenAI', rx: /\bsk-[A-Za-z0-9]{32,}/ },
  { nombre: 'URL con contraseña dentro', rx: /\b[a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]{6,}@(?!localhost|127\.0\.0\.1|::1|host\.docker)/ },
  { nombre: 'clave privada', rx: /-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----/ },
]

export function huellasEn(texto) {
  // huellasEn <texto> — los nombres de las huellas que aparecen en él.
  return HUELLAS.filter(({ rx }) => rx.test(texto)).map(({ nombre }) => nombre)
}
