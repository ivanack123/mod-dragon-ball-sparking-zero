# Genera la version PUBLICA del mod (la que va a GitHub y a otras personas).
#
# Diferencia con la nuestra: el interruptor AE_DIAG se pone a false, de modo que
# el mod NO escribe NADA en disco (ni registro de eventos, ni migajas de crash,
# ni espejo del log, ni historial) y NO carga las herramientas de depuracion.
# Solo habla.
#
# La copia instalada y la de desarrollo NO se tocan: siguen con los diagnosticos
# activos, que son los que usamos para arreglar fallos.
#
# Uso:  powershell -ExecutionPolicy Bypass -File "generar-version-publica.ps1"

$ErrorActionPreference = 'Stop'

$JUEGO = 'C:\Program Files (x86)\Steam\steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64'
$BASE  = Split-Path -Parent $MyInvocation.MyCommand.Path
$OUT   = Join-Path $BASE 'version-publica'

Write-Host 'Generando la version PUBLICA (sin diagnosticos)...' -ForegroundColor Cyan
if (-not (Test-Path $JUEGO)) { throw "No encuentro el juego: $JUEGO" }

if (Test-Path $OUT) { Remove-Item $OUT -Recurse -Force }
$modOut = Join-Path $OUT 'Mods\dragon-ball-sparking-zero-access\Scripts'
New-Item -ItemType Directory -Path $modOut -Force | Out-Null

# --- 1) UE4SS y su configuracion ---
# OJO: `dsound.dll` y `plugins\` son el UTOC Signature Bypass. Las notas del proyecto lo listan
# como parte de la instalacion que funciona, asi que se distribuye tal cual. Se detecto el 07-28
# que faltaban en el paquete: sin ellos el mod podria no arrancar en otro ordenador.
foreach ($f in @('dwmapi.dll', 'UE4SS.dll', 'UE4SS-settings.ini', 'dsound.dll')) {
    $origen = Join-Path $JUEGO $f
    if (Test-Path $origen) { Copy-Item $origen (Join-Path $OUT $f) -Force }
    else { Write-Host "  AVISO: no encuentro $f" }
}
# LA CACHE DE OBJETOS NO SE DISTRIBUYE HASTA QUE ESTE PROBADA (07-29).
# En nuestra maquina esta activada a modo de prueba, y como el ini se copia tal cual del
# juego, se colo activada en el paquete publico. Aqui se fuerza a `false`, que es lo que
# lleva funcionando meses. Cuando Ivan confirme que la cache va bien, se quita este bloque.
$iniPub = Join-Path $OUT 'UE4SS-settings.ini'
if (Test-Path $iniPub) {
    $ini = Get-Content $iniPub -Raw
    if ($ini -match 'bUseUObjectArrayCache\s*=\s*true') {
        $ini = $ini -replace 'bUseUObjectArrayCache\s*=\s*true', 'bUseUObjectArrayCache = false'
        [System.IO.File]::WriteAllText($iniPub, $ini, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '  cache de objetos forzada a false en el paquete publico (sin probar)'
    }
}

$plugins = Join-Path $JUEGO 'plugins'
if (Test-Path $plugins) {
    Copy-Item $plugins $OUT -Recurse -Force
    Write-Host '  incluida: carpeta plugins (UTOC Signature Bypass)'
}

# --- 2) Los mods que UE4SS trae de serie (NO son del mod de accesibilidad) ---
# Vienen dentro de UE4SS y hacen falta para que arranque con la misma
# configuracion probada. Se copian tal cual, menos el nuestro, que va aparte.
$modsOut = Join-Path $OUT 'Mods'
Get-ChildItem (Join-Path $JUEGO 'Mods') -Directory |
    Where-Object { $_.Name -ne 'dragon-ball-sparking-zero-access' } |
    ForEach-Object { Copy-Item $_.FullName $modsOut -Recurse -Force }
Copy-Item (Join-Path $JUEGO 'Mods\mods.txt') $modsOut -Force

# --- 3) El mod de accesibilidad ---
# Se copia TAL CUAL, byte a byte. Nada de leer y reescribir el texto desde PowerShell:
# `Get-Content -Raw` en Windows PowerShell 5.1 lee el archivo como ANSI, y al volver a
# guardarlo en UTF-8 destrozaba todas las letras acentuadas de main.lua. El recorte de
# los diagnosticos lo hace despues el script de Python, que si respeta la codificacion.
$src = Join-Path $JUEGO 'Mods\dragon-ball-sparking-zero-access\Scripts'
$copiados = 0
Get-ChildItem $src -File | Where-Object { $_.Name -notlike '*.bak-*' } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $modOut $_.Name) -Force
    $copiados++
}

# --- 3b) QUITAR DE VERDAD la maquinaria de cazar crashes ---
# Antes esto se apagaba con un interruptor y el codigo se quedaba ahi, apagado. Ahora se
# borra: el mod publico no lleva ni las migajas, ni el registro en disco, ni el historial
# de crashes, ni los mensajes de diagnostico. El script comprueba al final que el Lua
# resultante sigue siendo valido; si algo no cuadra, se planta y no se publica nada.
$limpiador = Join-Path $BASE 'limpiar-diagnosticos.py'
if (-not (Test-Path $limpiador)) { throw "No encuentro el limpiador: $limpiador" }
Write-Host '  quitando la maquinaria de diagnostico...'
& python $limpiador $modOut
if ($LASTEXITCODE -ne 0) { throw 'El limpiado de diagnosticos fallo. No se publica nada.' }

# --- 4) Comprobaciones antes de dar por buena la version ---
$mainPub = Join-Path $modOut 'main.lua'
$textoMain = [System.IO.File]::ReadAllText($mainPub)
foreach ($resto in @('AE_DIAG', 'Crumb(', 'ae_livelog', 'ae_crumb', 'ae_crashlogs', 'AE-DIAG')) {
    if ($textoMain.Contains($resto)) { throw "Ha quedado diagnostico en main.lua: $resto" }
}
if (-not (Test-Path (Join-Path $modOut 'debug_tools.lua'))) { throw 'FALTA debug_tools.lua (F3/F4/F5 deben funcionar)' }
foreach ($c in @('main.lua','speech.lua','helpers.lua','speech_bridge.dll','UniversalSpeech.dll')) {
    if (-not (Test-Path (Join-Path $modOut $c))) { throw "Falta un archivo imprescindible: $c" }
}
# Piezas que hacen que UE4SS arranque dentro del juego. Si falta alguna, el mod no habla.
foreach ($c in @('dwmapi.dll','UE4SS.dll','dsound.dll','plugins\DBSparkingZeroUTOCBypass.asi')) {
    if (-not (Test-Path (Join-Path $OUT $c))) { throw "Falta una pieza de arranque: $c" }
}
$bak = Get-ChildItem $OUT -Recurse -Include '*.bak-*' -File
if ($bak) { throw "Se colaron respaldos: $($bak.Name -join ', ')" }

# NADA EN DISCO SIN QUE EL USUARIO LO PIDA (07-29).
# Se detecto que la version publica SI escribia al arrancar: debug_tools.Init creaba la
# carpeta AE_debug, vaciaba cuatro archivos y dejaba una migaja, pasara lo que pasara.
# Ahora la carpeta se crea bajo demanda (EnsureDumpDir), solo al pulsar F3/F4/F5. Estas
# comprobaciones evitan que eso se vuelva a colar sin darnos cuenta.
$dbg = [System.IO.File]::ReadAllText((Join-Path $modOut 'debug_tools.lua'))
if (-not $dbg.Contains('EnsureDumpDir')) { throw 'debug_tools.lua no tiene la creacion bajo demanda de la carpeta' }
if ($dbg.Contains('ae_crumb')) { throw 'han quedado migajas en debug_tools.lua' }
$init = $dbg -replace '(?s)^.*function DebugTools\.Init', ''
if ($init -match 'os\.execute') { throw 'debug_tools.Init vuelve a crear la carpeta al arrancar' }
if ($init -match 'filesToClear') { throw 'debug_tools.Init vuelve a vaciar archivos al arrancar' }

Write-Host ''
Write-Host "Version publica lista en: $OUT" -ForegroundColor Green
Write-Host "Archivos del mod copiados: $copiados (debug_tools.lua incluido: F3/F4/F5)"
Write-Host 'Comprobado: no escribe nada en disco salvo que el usuario pulse F3, F4 o F5.'
