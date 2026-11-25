#!/bin/zsh
# Hook de Claude Code -> estado para el widget Chispa
# Uso: claude-hook.sh working|done|attention|end   (JSON del hook por stdin)
# Archivo de estado (una línea por dato): estado · carpeta · terminal · actividad · inicio · pasos · fin
dir="$HOME/Library/Caches/local.chispa/claude"
input=$(cat)
# Valor de texto del JSON por su ruta (p. ej. tool_input.file_path). plutil entiende JSON y respeta las comillas escapadas.
field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null | head -1 }
sid=$(field session_id)
# Solo letras, números y guiones: el id se usa como nombre de archivo
setopt extendedglob
[[ "$sid" == [A-Za-z0-9-]## ]] || exit 0
file="$dir/$sid"
if [[ "$1" == end ]]; then rm -f "$file"; exit 0; fi

# Lo que ya se sabía de esta sesión
prev=()
if [[ -f "$file" ]]; then
  old=$(cat -- "$file" 2>/dev/null)
  prev=("${(@f)old}")
fi
cwd=$(field cwd); [[ -z "$cwd" ]] && cwd="${prev[2]}"
activity="${prev[4]}"; start="${prev[5]}"; steps="${prev[6]:-0}"; fin=""
now=$(date +%s)

# El hook no tiene terminal propio: se busca el de Claude subiendo por los procesos padre
tty="${prev[3]}"
if [[ -z "$tty" ]]; then
  pid=$$
  for i in 1 2 3 4 5 6; do
    t=$(ps -o tty= -p $pid 2>/dev/null | tr -d ' ')
    if [[ "$t" == ttys* ]]; then tty=$t; break; fi
    pid=$(ps -o ppid= -p $pid 2>/dev/null | tr -d ' ')
    [[ -z "$pid" || "$pid" -le 1 ]] && break
  done
fi

event=$(field hook_event_name)
case "$1" in
  working)
    if [[ "$event" == UserPromptSubmit || -z "$start" ]]; then
      start=$now; steps=0; activity="Pensando…"
    fi
    if [[ "$event" == PostToolUse ]]; then
      steps=$((steps + 1))
      tool=$(field tool_name)
      case "$tool" in
        Edit|MultiEdit|Write|NotebookEdit) f=$(field tool_input.file_path); activity="Edición · ${f:t}" ;;
        Read)            f=$(field tool_input.file_path); activity="Lectura · ${f:t}" ;;
        Bash)            d=$(field tool_input.description); activity="${d:-Ejecutando un comando}" ;;
        Grep|Glob)       activity="Buscando en el código" ;;
        WebSearch|WebFetch) activity="Consultando la web" ;;
        Agent|Task)      d=$(field tool_input.description); activity="Subagente · ${d:-en marcha}" ;;
        mcp__*)          s=${tool#mcp__}; activity="Herramienta · ${s%%__*}" ;;
        "")              ;;
        *)               activity="$tool" ;;
      esac
    fi ;;
  done)      fin=$now; activity="Listo para revisar" ;;
  attention) activity="Espera tu permiso" ;;
esac
activity=${activity[1,70]}

mkdir -p "$dir"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$1" "$cwd" "$tty" "$activity" "$start" "$steps" "$fin" > "$file"
exit 0
