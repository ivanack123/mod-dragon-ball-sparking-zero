# Mod Dragon Ball Sparking Zero — Accesibilidad

**Un mod que hace hablar al juego, para poder jugarlo sin ver.**

**Descarga: [ModSparkingZero-20260728.zip](ModSparkingZero-20260728.zip)**

Descarga el paquete completo, no solo el instalador. `Instalar.exe` por sí solo no
sirve de nada: no lleva el mod dentro, lo copia desde la carpeta que viene a su lado
dentro del paquete.

---

## Por qué existe esto

DRAGON BALL Sparking! ZERO no trae ninguna opción de accesibilidad. Si no ves la
pantalla, no hay forma de saber en qué opción del menú estás, cuánta vida te queda,
qué dice un personaje en una cinemática o a quién acabas de desbloquear.

Este mod se puso en marcha por eso: para poder jugar. Está hecho a base de probar,
equivocarse y volver a probar, con las partidas de verdad como banco de pruebas. No es
un producto pulido de una empresa: es una herramienta que crece a golpe de uso.

## Qué lee

- **Los menús**: cada opción según te mueves, incluidos submenús, Ajustes y sus valores
  (automático, semiautomático, desactivado, volúmenes...).
- **El combate**: vida, ki, transformaciones, choques de golpes y de poderes, y los
  gritos de ataque de los personajes.
- **La historia**: los subtítulos de cinemáticas y diálogos, el mapa de episodios con
  sus nodos, capítulos y condiciones, y los detalles de cada combate.
- **Las recompensas**: lo que ganas al terminar, subidas de nivel y desbloqueos.
- **La Enciclopedia**: el nombre de cada personaje, sus categorías y sus técnicas.
  Distingue incluso entre dos personajes que se llaman igual.
- **La Tienda**: pestañas, categorías y artículos.
- **El torneo**: presentador, cuadro de emparejamientos, premios y menús.
- **El menú de pausa** y la lista de comandos y movimientos.

## Accesibilidad

Habla por su cuenta, sin necesidad de tener el lector abierto. Está probado a diario
con **NVDA** en Windows 11, y usa UniversalSpeech, así que también funciona con otros
lectores compatibles.

El instalador es un asistente con ventanas y botones, hecho con controles estándar de
Windows para que el lector de pantalla los lea bien: cada campo tiene su etiqueta, la
tecla Enter activa el botón principal y Escape cancela.

## Instalación

1. Descarga el paquete y descomprímelo donde quieras.
2. Abre `Instalar.exe`. Busca la carpeta del juego solo y copia todo en su sitio.
3. Abre el juego. Empezará a hablarte al llegar a la pantalla de inicio.

Windows mostrará un aviso de que protegió tu equipo. Le pasa a cualquier programa sin
firma digital. Elige "Más información" y luego "Ejecutar de todas formas". Si prefieres
evitarlo, dentro del paquete hay un `instalar.bat` que hace lo mismo sin ningún aviso, y
también puedes copiar los archivos a mano: está explicado en `LEEME.txt`.

Para desinstalarlo, borra `dwmapi.dll` de la carpeta del juego.

## Teclas

- **F6** repite las últimas recompensas.
- **F7** repite los detalles del último punto del mapa de historia.
- **F3**, **F4** y **F5** generan volcados de información, útiles solo para investigar fallos.

## Novedades

El historial completo de cambios está en [CHANGELOG.md](CHANGELOG.md).

## Estado del proyecto, con honestidad

Funciona y se usa todos los días, pero **no está terminado**. En algunas transiciones
entre pantallas el juego todavía puede cerrarse, y hay sitios donde el lector va más
lento de lo que debería. Se sigue trabajando en ello y cada versión va cerrando casos.

El mod lee la interfaz consultando los elementos del juego mientras se ejecuta. Eso
significa que **una actualización grande del juego puede romperlo** hasta que se adapte.

Si te encuentras un fallo, lo más útil que puedes enviar es lo que queda guardado en la
carpeta `Binaries\Win64\AE_debug` del juego, sobre todo `ae_livelog.txt` y los archivos
que empiezan por `ae_crumb`.

## Cómo está hecho

Lua sobre [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), que permite ejecutar scripts
dentro de juegos hechos con Unreal Engine, y UniversalSpeech para la voz.

## Créditos

Hecho por y para la comunidad de jugadores ciegos.

Incluye UE4SS y UniversalSpeech, cada uno con su propia licencia. Este proyecto no está
afiliado, mantenido ni patrocinado por Bandai Namco ni por Spike Chunsoft. DRAGON BALL
Sparking! ZERO es propiedad de sus respectivos titulares.
