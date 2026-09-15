// La forma de un servidor MCP: cómo se declara en el contrato y cómo se escribe
// para el cliente.
//
// El contrato dice `transport` y el fichero del cliente dice `type`. Traducir
// entre los dos es lo que hace que la declaración no dependa de qué agente la
// consuma. Vive aquí, y no dentro del adaptador, porque `doctor` necesita
// calcular exactamente lo mismo para saber si lo escrito sigue coincidiendo con
// lo declarado: si cada uno lo dedujera por su cuenta, el día que se separasen
// el doctor daría por bueno un fichero que el adaptador ya no escribiría así.

export const TRANSPORTES = ['stdio', 'http', 'sse']

// `repos` es nuestro: dice en qué repos se escribe el fichero, no cómo se habla
// con el servidor, así que no viaja al cliente.
export function aFormatoCliente(nombre, d) {
  const transporte = d.transport || 'stdio'
  if (!TRANSPORTES.includes(transporte)) {
    throw new Error(`${nombre}: transport '${transporte}' — solo ${TRANSPORTES.join(', ')}`)
  }

  const salida = { type: transporte }
  if (transporte === 'stdio') {
    if (!d.command) throw new Error(`${nombre}: transport stdio sin 'command'`)
    salida.command = d.command
    if (d.args) salida.args = d.args
    if (d.env) salida.env = d.env
  } else {
    if (!d.url) throw new Error(`${nombre}: transport ${transporte} sin 'url'`)
    salida.url = d.url
    if (d.headers) salida.headers = d.headers
  }
  if (d.timeout) salida.timeout = d.timeout
  return salida
}

// Todo texto de una declaración que acaba escrito en el fichero, con la etiqueta
// de dónde salió. Un secreto puede ir en cualquiera de estos sitios y no solo en
// una cabecera: la primera versión miraba `headers` y `env`, y una contraseña
// dentro de la propia `url` llegaba a git sin que nada la parase.
export function textosDe(d) {
  const salida = []
  for (const campo of ['url', 'command']) {
    if (d[campo]) salida.push({ donde: campo, texto: String(d[campo]) })
  }
  for (const [i, v] of (d.args || []).entries()) {
    salida.push({ donde: `args[${i}]`, texto: String(v) })
  }
  for (const campo of ['headers', 'env']) {
    for (const [clave, valor] of Object.entries(d[campo] || {})) {
      salida.push({ donde: `${campo}.${clave}`, texto: String(valor), clave })
    }
  }
  return salida
}

// En qué repos del proyecto se escribe el fichero de un servidor. El docs repo
// entra siempre: es nuestro en todos los perfiles, y tener un destino seguro es
// lo que permite a `doctor` saber dónde debería haber fichero sin repetir esta
// resolución por su cuenta.
//
// El perfil puede recortar esto —donde no se escriben punteros tampoco se
// escribe configuración nuestra—, y eso lo aplica quien llama, que es quien
// conoce el perfil.
export function reposDe(contrato, nombre) {
  const quiere = (contrato.mcp || {})[nombre]?.repos ?? 'docs'
  if (quiere === 'docs') return []
  if (quiere === 'all') return contrato.repos || []
  return Array.isArray(quiere) ? quiere : [quiere]
}
