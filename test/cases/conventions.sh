#!/usr/bin/env bash

# Cada caso monta un repo con el fallo real que la puerta debe cazar. Si la
# heurística deja de disparar, el test se pone rojo antes de que alguien
# descubra en una revisión que la puerta no señalaba nada.

conventions_repo() {
  # conventions_repo — deja un repo git con base commiteada y devuelve su ruta
  local dir="$SB/repo"
  mkdir -p "$dir/lib" "$dir/conventions"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    echo '# code style' > conventions/code-style.md
    cat > crux.json <<'JSON'
{
  "crux": "0.19.0",
  "conventions": {
    "checks": [
      { "name": "tipos declarados dentro de un .consts — van al .types",
        "files": "*.consts.ts",
        "forbid": "^\\+\\s*(export )?(interface|type) [A-Z]" },
      { "name": "constantes declaradas dentro de un .types — van al .consts",
        "files": "*.types.ts",
        "forbid": "^\\+\\s*export const [A-Z_]+ *=" }
    ]
  }
}
JSON
    printf "export const NETWORK = { AEMET: 'AEMET' } as const\n" > lib/existing.consts.ts
    printf "export type Foo = 'a'\n" > lib/existing.types.ts
    git add -A
    git commit -qm base
  )
  echo "$dir"
}

conventions_run() {
  # conventions_run <repo> — corre la puerta sobre lo que hay sin commitear
  (cd "$1" && git add -A && bash "$CRUX_HOME/skills/ship/scripts/conventions.sh" 2>&1)
}

test_conventions_lista_los_documentos_que_aplican() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export const A = 1\n" > "$repo/lib/nuevo.ts"

  assert_contains "$(conventions_run "$repo")" "conventions/code-style.md" \
    "lista el documento de convenciones del proyecto"
}

test_conventions_no_aplica_sin_codigo() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  echo "texto" > "$repo/LEEME.md"

  assert_contains "$(conventions_run "$repo")" "no aplica" \
    "un diff de solo texto no paga esta puerta"
}

test_conventions_caza_el_literal_repetido() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  cat > "$repo/lib/edad.ts" <<'EOF'
export type Edad = 'fresca' | 'vieja'
export function clasificar(h: number): Edad {
  return h > 6 ? 'vieja' : 'fresca'
}
export function etiqueta(e: Edad): string {
  if (e === 'fresca') return 'reciente'
  if (e === 'vieja') return 'antigua'
  return 'fresca'
}
EOF

  assert_contains "$(conventions_run "$repo")" "literales repetidos" \
    "un literal que se repite pide un diccionario"
}

test_conventions_caza_el_tipo_dentro_del_consts() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  cat > "$repo/lib/marcador.consts.ts" <<'EOF'
interface Apariencia { opacidad: number }
export const APARIENCIA: Record<string, Apariencia> = {}
EOF

  assert_contains "$(conventions_run "$repo")" "tipos declarados dentro de un .consts" \
    "un tipo en el fichero de constantes está fuera de sitio"
}

test_conventions_caza_la_constante_dentro_del_types() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export type Bar = 'b'\nexport const MAX_ITEMS = 10\n" > "$repo/lib/bar.types.ts"

  assert_contains "$(conventions_run "$repo")" "constantes declaradas dentro de un .types" \
    "una constante en el fichero de tipos está fuera de sitio"
}

test_conventions_caza_el_catalogo_redeclarado() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export const NETWORK = { SIAR: 'SIAR' } as const\n" > "$repo/lib/redes.consts.ts"

  assert_contains "$(conventions_run "$repo")" "NETWORK ya existe" \
    "redeclarar un catálogo existente es el fallo caro: las copias divergen"
}

test_conventions_calla_cuando_no_hay_nada_que_decir() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  printf "export function sumar(a: number, b: number): number {\n  return a + b\n}\n" \
    > "$repo/lib/sumar.ts"

  local out; out="$(conventions_run "$repo")"
  assert_contains "$out" "sin señales" "un diff limpio no inventa hallazgos"
  assert_not_contains "$out" "literales repetidos" "sin falsos positivos"
}

test_conventions_no_exige_lo_que_el_proyecto_no_declara() {
  sandbox >/dev/null
  local dir="$SB/simple"
  mkdir -p "$dir/lib"
  (
    cd "$dir" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    echo '{"crux":"0.19.0"}' > crux.json
    printf "export const A = 1\n" > lib/a.ts
    git add -A && git commit -qm base
  )
  printf "interface B { x: number }\n" > "$dir/lib/b.consts.ts"

  local out; out="$(conventions_run "$dir")"
  assert_not_contains "$out" "van al .types" \
    "un proyecto que no declara la regla no la paga"
}

test_conventions_para_si_el_contrato_es_ilegible() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  echo '{ roto' > "$repo/crux.json"
  printf "export const A = 1\n" > "$repo/lib/nuevo.ts"

  local out; out="$(conventions_run "$repo")"
  assert_contains "$out" "no puedo leer las convenciones declaradas" \
    "un contrato ilegible se nombra y para, no se convierte en cero reglas"
}

test_conventions_aplica_las_reglas_tambien_en_un_repo_grande() {
  sandbox >/dev/null
  local repo; repo="$(conventions_repo)"
  (
    cd "$repo" || exit 1
    mkdir -p relleno
    for i in $(seq 1 3000); do : > "relleno/f$i.ts"; done
    git add -A && git commit -qm relleno
  )
  printf "interface Apariencia { opacidad: number }\n" > "$repo/lib/grande.consts.ts"

  assert_contains "$(conventions_run "$repo")" "tipos declarados dentro de un .consts" \
    "la lista de ficheros no puede cerrarle la tubería a git y saltarse las reglas"
}
