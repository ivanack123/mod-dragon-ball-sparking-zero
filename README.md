# Mod Dragon Ball Sparking Zero — Accesibilidad

Mod de accesibilidad por voz para **DRAGON BALL Sparking! ZERO** (Steam, Windows).

Hace que el juego hable, para que una persona ciega pueda jugarlo. Lee los menús,
los subtítulos de la historia, la vida y el ki durante el combate, las recompensas,
la Enciclopedia, la Tienda, los Ajustes, el mapa de historia, el modo torneo y más.

Funciona con NVDA y con otros lectores de pantalla compatibles. No hace falta tener
el lector abierto: el mod habla por su cuenta.

## Instalación

**Opción fácil.** Descarga el paquete de la sección de *releases*, descomprímelo y abre
`instalar.bat` (o el instalador `.exe`). Busca la carpeta del juego solo y copia todo en
su sitio. Si Windows avisa de que protegió tu equipo, elige "Más información" y luego
"Ejecutar de todas formas": pasa con cualquier programa que no esté firmado digitalmente.

**Opción manual.** Copia todo el contenido de la carpeta `archivos` (o de `version-publica`,
si trabajas desde el código) dentro de la carpeta del juego:

```
...\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64
```

Las instrucciones completas y accesibles están en `LEEME.txt`.

## Teclas

- **F6** repite las últimas recompensas obtenidas.
- **F7** repite los detalles del último punto del mapa de historia.
- **F3**, **F4** y **F5** generan volcados de información para investigar problemas.

## Desinstalar

Borra `dwmapi.dll` de la carpeta `Win64` del juego. Con eso el mod deja de cargarse y el
juego vuelve a su estado original.

## Cómo está hecho

El mod está escrito en Lua y se ejecuta sobre [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
que permite ejecutar scripts dentro de juegos hechos con Unreal Engine. La voz se emite a
través de UniversalSpeech.

El mod lee la interfaz del juego consultando sus elementos en tiempo real y anunciando los
cambios. Por eso depende de cómo está construida la interfaz por dentro: **una actualización
grande del juego puede romperlo** hasta que se adapte.

## Estado

En desarrollo activo y en uso diario. Funciona, pero todavía puede fallar: en algunas
transiciones entre pantallas el juego puede cerrarse. Se sigue trabajando en ello.

## Estructura del repositorio

- `version-publica/` — el mod listo para copiar dentro del juego, junto con UE4SS y su
  configuración probada.
- `instalar.bat` — instalador que localiza el juego y copia los archivos.
- `LEEME.txt` — instrucciones completas, pensadas para leerse con lector de pantalla.
- `generar-version-publica.ps1` y `generar-instalador-exe.ps1` — scripts que construyen el
  paquete distribuible a partir de la instalación de desarrollo.

## Créditos y licencia

Mod de accesibilidad desarrollado por y para la comunidad de jugadores ciegos.

Incluye [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) y UniversalSpeech, cada uno con su
propia licencia. DRAGON BALL Sparking! ZERO es propiedad de sus respectivos titulares; este
proyecto no está afiliado a ellos.
