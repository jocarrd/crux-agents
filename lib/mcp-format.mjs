// The shape of an MCP server: how it is declared in the contract and how it is
// written for the client.
//
// The contract says `transport` and the client file says `type`. Translating
// between the two is what makes the declaration independent of which agent
// consumes it. It lives here, and not inside the adapter, because `doctor`
// needs to compute exactly the same thing to know whether what was written
// still matches what was declared: if each deduced it on its own, the day they
// diverged doctor would approve a file the adapter would no longer write that
// way.

export const TRANSPORTS = ['stdio', 'http', 'sse']

// `repos` is ours: it says in which repos the file is written, not how to talk
// to the server, so it does not travel to the client.
export function toClientFormat(name, d) {
  const transport = d.transport || 'stdio'
  if (!TRANSPORTS.includes(transport)) {
    throw new Error(`${name}: transport '${transport}' — only ${TRANSPORTS.join(', ')}`)
  }

  const output = { type: transport }
  if (transport === 'stdio') {
    if (!d.command) throw new Error(`${name}: transport stdio without 'command'`)
    output.command = d.command
    if (d.args) output.args = d.args
    if (d.env) output.env = d.env
  } else {
    if (!d.url) throw new Error(`${name}: transport ${transport} without 'url'`)
    output.url = d.url
    if (d.headers) output.headers = d.headers
  }
  if (d.timeout) output.timeout = d.timeout
  return output
}

// Every text of a declaration that ends up written in the file, with a label
// for where it came from. A secret can be in any of these places and not only
// in a header: the first version looked at `headers` and `env`, and a password
// inside the `url` itself reached git with nothing stopping it.
export function textsOf(d) {
  const output = []
  for (const field of ['url', 'command']) {
    if (d[field]) output.push({ where: field, text: String(d[field]) })
  }
  for (const [i, v] of (d.args || []).entries()) {
    output.push({ where: `args[${i}]`, text: String(v) })
  }
  for (const field of ['headers', 'env']) {
    for (const [key, value] of Object.entries(d[field] || {})) {
      output.push({ where: `${field}.${key}`, text: String(value), key })
    }
  }
  return output
}

// In which repos of the project a server's file is written. The docs repo
// always goes in: it is ours in every profile, and having a safe destination is
// what lets `doctor` know where a file should exist without repeating this
// resolution on its own.
//
// The profile can trim this —where pointers are not written, our configuration
// is not written either—, and that is applied by the caller, who knows the
// profile.
export function reposOf(contract, name) {
  const wants = (contract.mcp || {})[name]?.repos ?? 'docs'
  if (wants === 'docs') return []
  if (wants === 'all') return contract.repos || []
  return Array.isArray(wants) ? wants : [wants]
}
