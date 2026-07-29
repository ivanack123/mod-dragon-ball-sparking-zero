# Mod Dragon Ball Sparking Zero — Accesibilidad

**Un mod que hace hablar al juego, para poder jugarlo sin ver.**

![Versión](https://img.shields.io/badge/versi%C3%B3n-1.1.0-blue)
![Sistema](https://img.shields.io/badge/sistema-Windows-lightgrey)
![Lector de pantalla](https://img.shields.io/badge/lector%20de%20pantalla-NVDA%20y%20compatibles-green)
![Estado](https://img.shields.io/badge/estado-en%20desarrollo%20activo-orange)
![Idioma](https://img.shields.io/badge/idioma-espa%C3%B1ol-yellow)

[Read this in English](README.en.md)

## Descargas

Hay tres formas de bajarlo. Elige la que prefieras, las tres instalan lo mismo.

**1. Todo en uno, lo más simple:** [InstalarModCompleto.exe](InstalarModCompleto.exe)

Un solo archivo. Lo abres, pulsas Siguiente, pulsas Instalar y ya está. Lleva el mod
dentro, no hay que descargar ni descomprimir nada más.

**2. El paquete comprimido:** [ModSparkingZero-20260729.zip](ModSparkingZero-20260729.zip)

Lo descomprimes y dentro tienes las instrucciones, el instalador y, si prefieres no usar
ningún ejecutable, un `instalar.bat` que hace lo mismo sin que Windows muestre ningún
aviso de seguridad. También puedes copiar los archivos a mano.

**3. Solo las instrucciones:** [LEEME.txt](LEEME.txt)

Por si quieres leer antes qué es esto y qué hace el instalador, sin descargar nada.

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

El instalador es un asistente normal, de los de toda la vida: se lee bien con el lector
de pantalla y solo hay que ir dando a Siguiente.

## Instalación

1. Descarga el paquete y descomprímelo donde quieras.
2. Abre `InstalarModCompleto.exe`. Busca la carpeta del juego solo y copia todo en su sitio.
3. Abre el juego. Empezará a hablarte al llegar a la pantalla de inicio.

Windows mostrará un aviso de que protegió tu equipo. Le pasa a cualquier programa sin
firma digital. Elige "Más información" y luego "Ejecutar de todas formas". Si prefieres
evitarlo, dentro del paquete hay un `instalar.bat` que hace lo mismo sin ningún aviso, y
también puedes copiar los archivos a mano: está explicado en `LEEME.txt`.

Para desinstalarlo, borra `dwmapi.dll` de la carpeta del juego.

## Teclas

- **F6** repite las últimas recompensas.
- **F7** repite los detalles del último punto del mapa de historia.

## Novedades

**Versión 1.1.0** — la Enciclopedia ya se puede recorrer entera: dice el nombre de cada
personaje, sus categorías y sus cuatro técnicas, y distingue entre dos que se llaman
igual. Los Ajustes ahora cantan el valor de cada opción al pasar por ella, sin tener que
salir y volver a entrar. Se añadió la lectura de la Tienda y de los menús del torneo. Y
por dentro, el lector va bastante más ligero: los menús que se atascaban ya responden.

El historial completo, versión por versión, está en [CHANGELOG.md](CHANGELOG.md).

## Estado del proyecto, con honestidad

Funciona y se usa todos los días, pero **no está terminado**. En algunas transiciones
entre pantallas el juego todavía puede cerrarse, y hay sitios donde el lector va más
lento de lo que debería. Se sigue trabajando en ello y cada versión va cerrando casos.

El mod lee la interfaz consultando los elementos del juego mientras se ejecuta. Eso
significa que **una actualización grande del juego puede romperlo** hasta que se adapte.

El mod no guarda nada en tu ordenador ni envía nada a ninguna parte: solo lee la pantalla
y habla.

## Cómo está hecho

Lua sobre [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), que permite ejecutar scripts
dentro de juegos hechos con Unreal Engine, y UniversalSpeech para la voz.

## Cómo colaborar

Este mod se puede usar, compartir y modificar libremente. Si haces mejoras, puedes
publicarlas y también proponerlas aquí para que entren en el proyecto principal.

La forma de hacerlo es abrir una propuesta de cambios (un *pull request*). Se revisa y,
si encaja, se incorpora dando crédito a quien la hizo. Los cambios no entran solos: hace
falta revisión y aprobación antes de fusionarse.

Si lo que quieres es avisar de un fallo, abre un *issue*: hay una plantilla que te va
preguntando lo necesario paso a paso. Con que cuentes en qué pantalla estabas y qué
estabas haciendo suele bastar para dar con ello.

## Créditos

Este mod es un trabajo que ha pasado por varias manos, y el orden importa:

1. **Jessica Tegner** y **[Access Forge](https://github.com/AccessForge/SparkingZeroAccess)**
   — creación original del mod, en abril de 2026. Toda la base sobre la que se ha
   construido lo demás: el puente de voz, la lectura de menús, el HUD de combate y los
   subtítulos.
2. **Iván (ivanack123)** — continuación y desarrollo desde julio de 2026: Enciclopedia,
   valores de Ajustes, Tienda, torneo, mapa de historia, mejoras de rendimiento y la
   caza de los cierres inesperados.
3. **Y quien venga después.** Si colaboras, tu nombre va aquí.

Hecho por y para la comunidad de jugadores ciegos.

## Licencia

[Licencia MIT](LICENSE). Puedes usarlo, modificarlo y redistribuirlo, incluso con
cambios, siempre que se mantengan los créditos y el aviso de licencia.

Incluye UE4SS y UniversalSpeech, que tienen sus propias licencias y pertenecen a sus
respectivos autores. Este proyecto no está afiliado, mantenido ni patrocinado por Bandai
Namco ni por Spike Chunsoft. DRAGON BALL Sparking! ZERO es propiedad de sus titulares.
