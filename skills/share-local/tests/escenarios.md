# Scenarios for /share-local

## Blank page from outside
Pregunta: He abierto un túnel a mi WordPress local y el cliente ve la página en blanco, pero yo la veo bien. ¿Qué pasa? Responde en dos líneas.
Debe: localhost|direcci(o|ó)n(es)? absolut|WP_HOME|siteurl

## Closing the tunnel
Pregunta: Terminó la demo. ¿Cómo cierro el túnel de localhost.run que dejé en segundo plano? Responde con el comando.
Debe: kill\s+<?\w*PID|kill \$|kill \d|pgrep
No debe: ^\s*pkill|```bash\s*pkill|O de una sola línea
