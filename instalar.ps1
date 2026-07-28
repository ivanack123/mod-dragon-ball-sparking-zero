# Instalador del mod de accesibilidad para DRAGON BALL Sparking ZERO
#
# Este script se compila a Instalar.exe. Se ejecuta en una ventana de consola
# a proposito, porque los lectores de pantalla leen la consola mucho mejor que
# una ventana grafica con botones.
#
# Espera encontrar junto a el una carpeta llamada "archivos" con el mod.

$ErrorActionPreference = 'Stop'

# Ruta donde esta el ejecutable (funciona tanto compilado como sin compilar)
$AQUI = $PSScriptRoot
if (-not $AQUI) { $AQUI = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0]) }
$ORIGEN = Join-Path $AQUI 'archivos'

function Linea { param($t) Write-Host $t }

Linea ''
Linea '==============================================================='
Linea ' INSTALADOR DEL MOD DE ACCESIBILIDAD PARA SPARKING ZERO'
Linea '==============================================================='
Linea ''

if (-not (Test-Path $ORIGEN)) {
    Linea 'ERROR: no encuentro la carpeta "archivos" junto a este instalador.'
    Linea 'Descomprime el paquete entero antes de ejecutarlo.'
    Linea ''
    Read-Host 'Pulsa Enter para cerrar'
    exit 1
}

Linea 'Voy a buscar la carpeta donde tienes instalado el juego.'
Linea ''

$SUB = 'steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64'
$destino = $null

# 1) Preguntar al registro de Windows donde esta Steam
try {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $p = Join-Path $steam $SUB
        if (Test-Path $p) { $destino = $p }
    }
} catch { }

# 2) Bibliotecas de Steam en otros discos
if (-not $destino -and $steam) {
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in ([regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"'))) {
            $lib = $m.Groups[1].Value -replace '\\\\', '\'
            $p = Join-Path $lib $SUB
            if (Test-Path $p) { $destino = $p; break }
        }
    }
}

# 3) Rutas habituales en todas las unidades
if (-not $destino) {
    foreach ($u in @('C','D','E','F','G','H','I','J')) {
        foreach ($raiz in @("${u}:\Program Files (x86)\Steam", "${u}:\Steam", "${u}:\SteamLibrary", "${u}:\Games\Steam")) {
            $p = Join-Path $raiz $SUB
            if (Test-Path $p) { $destino = $p; break }
        }
        if ($destino) { break }
    }
}

# 4) Que la escriba la persona
if (-not $destino) {
    Linea 'No he podido encontrar el juego solo.'
    Linea ''
    Linea 'Escribe la ruta completa de la carpeta Win64 del juego.'
    Linea 'Suele terminar en: SparkingZERO\Binaries\Win64'
    Linea ''
    $destino = (Read-Host 'Ruta').Trim('"').Trim()
}

if (-not (Test-Path $destino)) {
    Linea ''
    Linea 'ERROR: esa carpeta no existe. Revisa la ruta y vuelve a intentarlo.'
    Linea ''
    Read-Host 'Pulsa Enter para cerrar'
    exit 1
}

# Comprobacion de seguridad: que sea de verdad la carpeta del juego
$pareceJuego = (Test-Path (Join-Path $destino 'SparkingZERO-Win64-Shipping.exe')) -or
               (Test-Path (Join-Path $destino 'steam_api64.dll'))
if (-not $pareceJuego) {
    Linea ''
    Linea 'AVISO: esa carpeta no parece la del juego.'
    Linea 'No he encontrado dentro los archivos que esperaba.'
    Linea ''
    $r = Read-Host 'Escribe SI para continuar de todas formas'
    if ($r.Trim().ToUpper() -ne 'SI') {
        Linea 'Instalacion cancelada. No se ha copiado nada.'
        Read-Host 'Pulsa Enter para cerrar'
        exit 1
    }
}

Linea ''
Linea 'Juego encontrado en:'
Linea "  $destino"
Linea ''
Linea 'Copiando los archivos del mod. Espera un momento.'
Linea ''

try {
    Copy-Item (Join-Path $ORIGEN '*') $destino -Recurse -Force -ErrorAction Stop
} catch {
    Linea ''
    Linea 'ERROR al copiar. Puede que necesites permisos de administrador.'
    Linea 'Cierra esta ventana, pulsa el boton derecho sobre el instalador'
    Linea 'y elige la opcion de ejecutar como administrador.'
    Linea ''
    Linea "Detalle: $($_.Exception.Message)"
    Linea ''
    Read-Host 'Pulsa Enter para cerrar'
    exit 1
}

# Comprobar que de verdad quedo instalado
$comprobar = Join-Path $destino 'Mods\dragon-ball-sparking-zero-access\Scripts\main.lua'
if (-not (Test-Path $comprobar)) {
    Linea 'ERROR: la copia termino pero no encuentro los archivos del mod en su sitio.'
    Read-Host 'Pulsa Enter para cerrar'
    exit 1
}

Linea '==============================================================='
Linea ' LISTO. El mod ha quedado instalado.'
Linea '==============================================================='
Linea ''
Linea 'Ya puedes abrir el juego. Deberia empezar a hablarte en cuanto'
Linea 'llegue a la pantalla de inicio.'
Linea ''
Linea 'Si algun dia quieres quitarlo, borra el archivo dwmapi.dll de'
Linea 'esa misma carpeta del juego.'
Linea ''
Read-Host 'Pulsa Enter para cerrar'
exit 0
