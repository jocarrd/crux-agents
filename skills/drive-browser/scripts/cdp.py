#!/usr/bin/env python3
"""Cliente CDP mínimo para pilotar un Chrome con --remote-debugging-port.
Sin dependencias de framework de agente. Requiere: pip websockets.

Acciones:
  goto  <url> [out.png] [wait_s]      navega y (opcional) captura
  shot  <out.png>                     captura la pestaña actual
  eval  <js>                          evalúa JS, imprime el valor (JSON)
  evalshot <js> <out.png> [wait_s]    evalúa, espera y captura
  writefile <js> <path>              evalúa, escribe el valor a fichero (NO lo imprime)
  click <selector-o-texto> [out.png]  click REAL de navegador sobre el centro del elemento
  type  <texto> [out.png]             teclea en el elemento con foco (eventos reales)
  clickxy <x> <y> [out.png]           click real en coordenadas de viewport

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
    async def click_xy(s, x, y):
        for t in ("mousePressed", "mouseReleased"):
            await s.cmd("Input.dispatchMouseEvent", type=t, x=x, y=y,
                        button="left", clickCount=1, buttons=1 if t == "mousePressed" else 0)
            await asyncio.sleep(0.05)
    async def type_text(s, txt):
        for ch in txt:
            await s.cmd("Input.dispatchKeyEvent", type="keyDown", text=ch)
            await s.cmd("Input.dispatchKeyEvent", type="keyUp", text=ch)
            await asyncio.sleep(0.012)
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
        elif action == "click":
            # Un click sintético de JS no basta en muchas SPA: React escucha eventos
            # de puntero de verdad. Se busca por selector CSS o por texto visible.
            q = sys.argv[2].replace("\\", "\\\\").replace('"', '\\"')
            box = await c.ev(f'''(()=>{{
              let e=null; try{{e=document.querySelector("{q}")}}catch(_){{}}
              if(!e){{e=[...document.querySelectorAll("button,a,label,div,span,li")]
                 .filter(x=>x.textContent.trim().includes("{q}")&&x.children.length<4).pop()}}
              if(!e)return null;
              e.scrollIntoView({{block:"center"}});
              const r=e.getBoundingClientRect();
              return {{x:r.left+r.width/2,y:r.top+r.height/2,t:e.textContent.trim().slice(0,60)}};
            }})()''')
            if not box or "__err__" in str(box):
                print("no encontrado:", sys.argv[2], box); return
            await asyncio.sleep(0.3)
            await c.click_xy(box["x"], box["y"])
            await asyncio.sleep(2)
            print(f'click en ({int(box["x"])},{int(box["y"])}) sobre: {box["t"]}')
            if len(sys.argv) > 3: await c.shot(sys.argv[3])
        elif action == "clickxy":
            await c.click_xy(float(sys.argv[2]), float(sys.argv[3]))
            await asyncio.sleep(2)
            print(f"click en ({sys.argv[2]},{sys.argv[3]})")
            if len(sys.argv) > 4: await c.shot(sys.argv[4])
        elif action == "type":
            await c.type_text(sys.argv[2])
            await asyncio.sleep(1)
            print("tecleado", len(sys.argv[2]), "chars")
            if len(sys.argv) > 3: await c.shot(sys.argv[3])
        else:
            print("acción desconocida:", action)

asyncio.run(main())
