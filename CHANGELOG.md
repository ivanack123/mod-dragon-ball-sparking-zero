# Historial de cambios

Todos los cambios del mod, del más reciente al más antiguo.

Las fechas de abril salen del historial de versiones del proyecto original. Las de julio
salen del diario de trabajo que se ha ido llevando durante el desarrollo.

---

## Sin publicar — julio de 2026

Un mes largo de trabajo a partir de las partidas reales. Muchas de estas mejoras salieron
de jugar, encontrarse con algo que no se leía, y perseguirlo hasta dar con la causa.

### Se lee mucho más que antes

- **Enciclopedia completa.** Ahora dice el nombre del personaje, sus categorías y sus
  cuatro técnicas. Y distingue entre dos personajes que se llaman igual, como los varios
  "Son Goku" o "Vegeta", comparando su ficha de habilidades, porque el juego no ofrece
  ningún número ni identificador que permita separarlos.
- **Valores de las opciones en Ajustes.** Al mover izquierda o derecha ahora dice el valor
  nuevo: automático, semiautomático, desactivado, personalizar, los números de volumen.
  Costó trece intentos: los doce primeros dependían del foco del teclado, que la
  cinemática de fondo del menú borra constantemente.
- **Tienda.** Se leen las dos pestañas, Shop y Customize, las categorías y los artículos.
- **Torneo.** Presentador, cuadro de emparejamientos entre rondas, premios, personaje
  ganado, misiones y menús.
- **Mapa de historia.** Nodos, capítulos, arcos, condiciones y cambio de área.
- **Detalles de batalla** del menú de pausa, y la lista de comandos y movimientos.
- **Recompensas** al terminar un combate, subidas de nivel y desbloqueos, con la tecla F6
  para repetirlas.
- **Menú de avisos** (el del botón X): notificaciones, bonificación de inicio de sesión.

### Va bastante más rápido

- Se rehízo la lectura de la Enciclopedia: hacía once recorridos completos de la pantalla
  por cada comprobación, y ahora hace uno.
- Se añadieron atajos por pantalla, de modo que el mod mira solo los pocos elementos que
  de verdad pueden tener el foco en cada sitio, en vez de recorrer los más de mil de la
  escena. En la Enciclopedia son trece elementos en lugar de mil ciento cuarenta y cinco.
- Se eliminó trabajo duplicado: los dos bucles internos estaban pidiendo la misma lista de
  objetos del juego, cada uno por su cuenta, diez veces por segundo.
- Se recortó la lista de búsquedas globales que se ejecutaban en todas las pantallas.

### Deja de cerrarse tanto

Buena parte del mes se fue en perseguir cierres inesperados del juego. Cada uno resultó ser
un punto distinto donde el mod tocaba elementos de la pantalla justo mientras el juego los
estaba creando o destruyendo:

- Al entrar a la Enciclopedia, la Tienda, los Ajustes o un episodio desde el menú.
- Al salir de la Enciclopedia de vuelta al menú.
- Al entrar al torneo y al empezar una batalla.
- Al arrancar el juego, justo cuando desaparece el aviso de contenido descargable.

Para eso se construyó un sistema de diagnóstico propio: marcas que registran en qué punto
exacto estaba trabajando el mod cuando el juego murió, un registro de eventos al instante y
mediciones de los atascos internos. Sin eso habría sido imposible: cada caso se cerró
leyendo esas marcas, no adivinando.

### Distribución

- Instalador con asistente de ventanas y botones, pensado para lector de pantalla.
- Alternativa en archivo por lotes, sin avisos de seguridad de Windows.
- Paquete completo con el mod y todo lo necesario para que funcione, sin tener que
  descargar nada más.
- La versión que se publica no escribe archivos de diagnóstico: eso queda solo para el
  desarrollo.

---

## v1.0.1 — 26 de abril de 2026

- Corrección de un cierre del juego en las transiciones entre pantallas.
- Reducción del trabajo que hacía el mod al consultar la interfaz.

---

## v1.0.0 — 6 de abril de 2026

Primera versión pública.

- Lectura de menús y navegación.
- Lectura de vida y ki durante el combate.
- Subtítulos de las cinemáticas y los diálogos.
- Voz mediante UniversalSpeech, compatible con NVDA.
- Instalación sobre UE4SS.

---

## Antes de v1.0.0 — abril de 2026

Arranque del proyecto: exploración de la interfaz del juego para averiguar de dónde se
podía sacar el texto.

Se comprobó que el sistema de accesibilidad que trae Unreal Engine de serie **no está
disponible** en este juego, porque se compiló fuera. Por eso el mod tiene que leer la
interfaz por su cuenta, elemento por elemento.
