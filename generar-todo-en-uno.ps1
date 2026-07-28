# Construye el instalador TODO EN UNO: un solo .exe que lleva el mod dentro.
#
# Toma el paquete .zip ya generado, lo incrusta dentro del script del asistente
# y lo compila con PS2EXE. El resultado se descarga suelto y funciona por si mismo,
# sin necesidad de ninguna carpeta al lado.
#
# Uso:  powershell -ExecutionPolicy Bypass -File "generar-todo-en-uno.ps1"

$ErrorActionPreference = 'Stop'
$BASE = Split-Path -Parent $MyInvocation.MyCommand.Path

$fecha = Get-Date -Format 'yyyyMMdd'
$zip = Join-Path $BASE "ModSparkingZero-$fecha.zip"
if (-not (Test-Path $zip)) { throw "Falta el paquete $zip. Ejecuta antes generar-instalador-exe.ps1" }

$plantilla = Join-Path $BASE 'plantilla-autocontenido.ps1'
if (-not (Test-Path $plantilla)) { throw 'Falta plantilla-autocontenido.ps1' }

Write-Host 'Construyendo el instalador TODO EN UNO...' -ForegroundColor Cyan
Write-Host "  paquete de origen: $([math]::Round((Get-Item $zip).Length/1MB,1)) MB"

# Incrustar el paquete como texto dentro del script
$b64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zip))
Write-Host "  incrustado como texto: $([math]::Round($b64.Length/1MB,1)) MB"

$script = (Get-Content $plantilla -Raw).Replace('@@PAYLOAD@@', $b64)
$tmpPs1 = Join-Path $env:TEMP "todoenuno_$fecha.ps1"
[System.IO.File]::WriteAllText($tmpPs1, $script, (New-Object System.Text.UTF8Encoding($false)))

# Compilar. Se construye en una ruta sin espacios y luego se mueve, por si acaso.
$tmpExe = Join-Path $env:TEMP "InstalarModCompleto.exe"
if (Test-Path $tmpExe) { Remove-Item $tmpExe -Force }

Write-Host '  compilando (puede tardar, el paquete es grande)...'
Import-Module ps2exe -Force
Invoke-PS2EXE -inputFile $tmpPs1 -outputFile $tmpExe -noConsole -requireAdmin `
    -title 'Instalador del mod de accesibilidad para Sparking ZERO' `
    -description 'Instala el mod de accesibilidad por voz. Incluye todo lo necesario.' `
    -product 'Mod de accesibilidad' -version '1.0.0' | Out-Null

if (-not (Test-Path $tmpExe)) { throw 'PS2EXE no genero el ejecutable' }

$final = Join-Path $BASE 'InstalarModCompleto.exe'
if (Test-Path $final) { Remove-Item $final -Force }
Move-Item $tmpExe $final -Force
Remove-Item $tmpPs1 -Force

$mb = [math]::Round((Get-Item $final).Length/1MB, 1)
Write-Host ''
Write-Host "LISTO: $final  ($mb MB)" -ForegroundColor Green
Write-Host 'Este ejecutable se basta solo: lleva el mod dentro.'
