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

# --- 3) El mod de accesibilidad, SIN diagnosticos ---
$src = Join-Path $JUEGO 'Mods\dragon-ball-sparking-zero-access\Scripts'
# NADA se excluye: debug_tools.lua (F3/F4/F5) SI va en la version publica, son funciones
# del proyecto que el usuario invoca a mano. Lo que se apaga es la maquinaria de cazar
# crashes (migajas, mediciones, avisos temporales), y de eso se encarga el interruptor.
$excluidos = @()
$copiados = 0
Get-ChildItem $src -File | Where-Object { $_.Name -notlike '*.bak-*' } | ForEach-Object {
    if ($excluidos -contains $_.Name) {
        Write-Host "  EXCLUIDO: $($_.Name)"
        return
    }
    $destino = Join-Path $modOut $_.Name
    if ($_.Name -eq 'main.lua') {
        $texto = Get-Content $_.FullName -Raw
        if ($texto -notmatch 'local AE_DIAG = true') { throw 'No encuentro el interruptor AE_DIAG en main.lua' }
        $texto = $texto -replace 'local AE_DIAG = true', 'local AE_DIAG = false'
        # Guardar SIN BOM: Lua no lo tolera bien al principio del archivo
        [System.IO.File]::WriteAllText($destino, $texto, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '  main.lua copiado con AE_DIAG = false (sin diagnosticos)'
    } else {
        Copy-Item $_.FullName $destino -Force
    }
    $copiados++
}

# --- 4) Comprobaciones antes de dar por buena la version ---
$mainPub = Join-Path $modOut 'main.lua'
if ((Get-Content $mainPub -Raw) -notmatch 'local AE_DIAG = false') { throw 'El interruptor NO quedo en false' }
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

Write-Host ''
Write-Host "Version publica lista en: $OUT" -ForegroundColor Green
Write-Host "Archivos del mod copiados: $copiados (debug_tools.lua excluido)"
Write-Host 'Esta version NO escribe nada en disco.'
