#!/usr/bin/env python3
"""Cliente CDP mínimo para pilotar un Chrome con --remote-debugging-port.
Sin dependencias de framework de agente. Requiere: pip websockets.

Acciones:
  goto  <url> [out.png] [wait_s]      navega y (opcional) captura
  shot  <out.png>                     captura la pestaña actual
  eval  <js>                          evalúa JS, imprime el valor (JSON)
  evalshot <js> <out.png> [wait_s]    evalúa, espera y captura
  writefile <js> <path>              evalúa, escribe el valor a fichero (NO lo imprime)

CDP escucha en $CDP_URL o http://127.0.0.1:9222.
"""
import asyncio, json, sys, os, base64, urllib.request, websockets

CDP = os.environ.get("CDP_URL", "http://127.0.0.1:9222")

def http(path):
    # ProxyHandler({}) evita que un http_proxy del entorno rompa la llamada a localhost
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return json.load(op.open(CDP + path, timeout=6))

def page_ws():
    for t in http("/json"):
        if t.get("type") == "page":
            return t["webSocketDebuggerUrl"]
    raise SystemExit("no hay pestaña (page target) en CDP")

class C:
    def __init__(s, ws): s.ws = ws; s.i = 0
    async def cmd(s, method, **p):
        s.i += 1; mid = s.i
        await s.ws.send(json.dumps({"id": mid, "method": method, "params": p}))
        while True:
            m = json.loads(await s.ws.recv())
            if m.get("id") == mid:
                if "error" in m: raise RuntimeError(f"{method}: {m['error']}")
                return m.get("result", {})
    async def ev(s, expr):
        r = await s.cmd("Runtime.evaluate", expression=expr,
                        returnByValue=True, awaitPromise=True)
        if "exceptionDetails" in r:
            ex = r["exceptionDetails"].get("exception", {})
            return {"__err__": ex.get("description") or str(r["exceptionDetails"])}
        return r.get("result", {}).get("value")
    async def shot(s, path):
        r = await s.cmd("Page.captureScreenshot", format="png")
        open(path, "wb").write(base64.b64decode(r["data"]))

async def main():
    action = sys.argv[1]
    async with websockets.connect(page_ws(), max_size=None) as ws:
        c = C(ws)
        await c.cmd("Page.enable"); await c.cmd("Runtime.enable")
        if action == "goto":
            await c.cmd("Page.navigate", url=sys.argv[2])
            await asyncio.sleep(float(sys.argv[4]) if len(sys.argv) > 4 else 6)
            print("URL:", await c.ev("location.href"))
            if len(sys.argv) > 3 and sys.argv[3]: await c.shot(sys.argv[3])
        elif action == "shot":
            await c.shot(sys.argv[2]); print("shot", sys.argv[2])
        elif action == "eval":
            print(json.dumps(await c.ev(sys.argv[2])))
        elif action == "evalshot":
            print(json.dumps(await c.ev(sys.argv[2])))
            await asyncio.sleep(float(sys.argv[4]) if len(sys.argv) > 4 else 2.5)
            await c.shot(sys.argv[3]); print("URL:", await c.ev("location.href"))
        elif action == "writefile":
            val = await c.ev(sys.argv[2])
            if not isinstance(val, str):
                print("no es string, no escrito:", type(val).__name__); return
            open(sys.argv[3], "w").write(val)
            os.chmod(sys.argv[3], 0o600)
            print(f"escrito {len(val)} chars en {sys.argv[3]} (no impreso)")
        else:
            print("acción desconocida:", action)

asyncio.run(main())
