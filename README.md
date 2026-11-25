# Chispa

Un widget para el escritorio del Mac que te enseña, de un vistazo, qué están haciendo tus agentes de **Claude Code**: quién trabaja, quién ha terminado y quién espera tu permiso. Con una mascota que se alegra cuando acaban.

*A desktop widget for macOS that shows what your Claude Code agents are doing. [English below](#english).*

![Chispa](docs/widget.png)

> Proyecto personal de código abierto. **No es una app oficial de Anthropic** ni está relacionada con ella.

## Qué hace

- **Agentes en directo**: cada sesión de Claude Code aparece con lo que está haciendo («Edición · checkout.tsx»), cuánto tiempo lleva y cuántos pasos. Clic en uno y te lleva a su pestaña de Terminal.
- **Avisos**: la mascota y el borde del widget cambian cuando un agente termina o necesita tu permiso. Sonido opcional.
- **Pídele algo a Claude**: escribe una petición y se abre un agente nuevo en la carpeta que elijas. Atajo global: **⌃⌥C**.
- **Resultados**: tareas resueltas hoy y en la semana, y un **informe semanal** en HTML listo para guardar como PDF.
- **Sistema**: CPU, memoria (y qué apps la usan), disco, batería y un botón para que el Mac no se duerma con la tapa cerrada.
- **Se esconde en el borde** de la pantalla y vuelve al pasar el ratón.
- **Modo presentación** y proyectos privados, para enseñarlo sin enseñar nombres.

## Requisitos

- macOS 15 o posterior (Apple Silicon o Intel).
- [Claude Code](https://docs.claude.com/en/docs/claude-code) instalado y abierto al menos una vez.
- Para saltar a la pestaña del agente: la app **Terminal** de macOS. Con otras terminales el widget funciona, pero ese clic solo abre Terminal.

## Instalar

### Opción 1: descargar

1. Descarga `Chispa.zip` de la página de [Releases](../../releases) y descomprímelo.
2. Arrastra `Chispa.app` a tu carpeta Aplicaciones.
3. La primera vez macOS dirá que no puede comprobar la app (no está firmada con una cuenta de desarrollador de Apple). Ve a **Ajustes del Sistema › Privacidad y seguridad**, baja hasta el aviso de Chispa y pulsa **Abrir igualmente**.

### Opción 2: compilar tú mismo

Solo necesitas las herramientas de línea de comandos de Xcode (`xcode-select --install`).

```sh
git clone https://github.com/davidpedrosamorales-dotcom/chispa.git
cd chispa
./build.sh
open build/Chispa.app
```

## La primera vez

Chispa te pedirá permiso para **conectarse con Claude Code**: añade unos *hooks* a `~/.claude/settings.json` para que Claude Code le avise de cuándo empieza, termina o espera tu permiso. Antes de tocar nada guarda una copia en `~/.claude/settings.json.antes-chispa`. Si mueves la app de sitio, corrige la ruta sola.

Todo lo demás está en el menú del **clic derecho** sobre el widget.

## Privacidad

- Chispa lee los registros que Claude Code guarda en tu Mac (`~/.claude/projects`) para contar tareas y tiempo. **Nada sale de tu ordenador.**
- El informe semanal se genera en local, en `~/Documents/Informes Claude`. Lleva tu nombre y los nombres de tus proyectos: revísalo antes de compartirlo (puedes editar el texto y quitar proyectos).
- **Opcional y apagado por defecto**: «Mostrar lo que te queda de Claude (experimental)». Si lo activas, Chispa usa la sesión que Claude Code guarda en el Llavero (macOS te pedirá permiso: pulsa **Permitir**, no «Permitir siempre», para que ningún otro programa pueda leerla sin preguntarte) para preguntar a Anthropic cuánto uso te queda. Usa una función no documentada, así que puede dejar de funcionar en cualquier momento.

## Desinstalar

1. Clic derecho › Salir, y borra `Chispa.app`.
2. Quita de `~/.claude/settings.json` las líneas que contienen `Chispa.app` (o recupera la copia `settings.json.antes-chispa`).
3. Si quieres, borra `~/Library/Caches/local.chispa` y `~/Library/Preferences/local.chispa.plist`.

## Cómo está hecho

Un único archivo en Swift (AppKit + SwiftUI), sin dependencias, y un script de *hook* en zsh (`claude-hook.sh`). `Chispa --render salida.png` dibuja el widget con datos de ejemplo, útil para probar cambios de diseño.

## Autor

Hecho por [davidpedrosamorales-dotcom](https://github.com/davidpedrosamorales-dotcom).

## Licencia

[MIT](LICENSE)

---

## English

Chispa is a macOS desktop widget for **Claude Code**. It shows each running agent and what it is doing, tells you when one finishes or needs your permission, lets you start a new agent from a text field (global shortcut **⌃⌥C**), counts the tasks your agents complete, and builds a weekly HTML report. It also shows CPU, memory, disk and battery, and hides at the screen edge. The interface is in Spanish for now.

- **Requires** macOS 15+ and Claude Code. Jumping to an agent's tab needs macOS Terminal.
- **Install**: download `Chispa.zip` from Releases, move `Chispa.app` to Applications, and on first launch allow it in *System Settings › Privacy & Security › Open Anyway* (the app is not notarized). Or build it yourself with `./build.sh`.
- **First run**: it asks before adding hooks to `~/.claude/settings.json` and keeps a backup (`settings.json.antes-chispa`).
- **Privacy**: everything stays on your Mac. The optional, off-by-default "remaining usage" rings read Claude Code's login from the Keychain and query an undocumented Anthropic endpoint; they may stop working at any time.
- Made by [davidpedrosamorales-dotcom](https://github.com/davidpedrosamorales-dotcom). Not affiliated with Anthropic. MIT licensed.
