# Construye el INSTALADOR .exe del mod, usando IExpress, que viene incluido en Windows.
# No descarga nada ni instala herramientas de terceros.
#
# Como funciona: mete dentro del .exe un paquete comprimido con el mod y un pequeno
# lanzador. Al abrirlo, el .exe se descomprime solo en una carpeta temporal y ejecuta
# el instalador de siempre, que busca el juego y copia los archivos.
#
# AVISO CONOCIDO: cualquier .exe sin firma digital hace que Windows muestre la pantalla
# de "Windows protegio su PC". Hay que elegir "Mas informacion" y luego "Ejecutar de
# todas formas". Eso no se puede evitar sin comprar un certificado de firma.
#
# Uso:  powershell -ExecutionPolicy Bypass -File "generar-instalador-exe.ps1"

$ErrorActionPreference = 'Stop'
$BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
$DIST = Join-Path $BASE 'distribucion'
$PUB  = Join-Path $BASE 'version-publica'

Write-Host 'Construyendo el instalador .exe...' -ForegroundColor Cyan

if (-not (Test-Path $PUB)) { throw "Falta la version publica. Ejecuta antes generar-version-publica.ps1" }
foreach ($f in @('LEEME.txt','instalar.bat')) {
    if (-not (Test-Path (Join-Path $BASE $f))) { throw "Falta $f en $BASE" }
}

# --- 1) Montar la carpeta de distribucion: lo que vera quien descomprima el zip ---
if (Test-Path $DIST) { Remove-Item $DIST -Recurse -Force }
New-Item -ItemType Directory -Path $DIST -Force | Out-Null
Copy-Item $PUB (Join-Path $DIST 'archivos') -Recurse -Force
Copy-Item (Join-Path $BASE 'LEEME.txt')    $DIST -Force
Copy-Item (Join-Path $BASE 'instalar.bat') $DIST -Force
Write-Host '  carpeta de distribucion montada'

# --- 2) El .zip (opcion sin ejecutable, para quien prefiera copiar a mano) ---
$fecha = Get-Date -Format 'yyyyMMdd'
$zipFinal = Join-Path $BASE "ModSparkingZero-$fecha.zip"
if (Test-Path $zipFinal) { Remove-Item $zipFinal -Force }
Compress-Archive -Path "$DIST\*" -DestinationPath $zipFinal -Force
Write-Host "  zip creado: $([System.IO.Path]::GetFileName($zipFinal))"

# --- 3) Preparar la carga util del .exe ---
$tmp = Join-Path $env:TEMP "sz_exe_build"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# El paquete que ira DENTRO del ejecutable
Compress-Archive -Path "$DIST\*" -DestinationPath (Join-Path $tmp 'paquete.zip') -Force

# El lanzador que se ejecuta al abrir el .exe
$lanzador = @'
@echo off
title Instalador del mod de accesibilidad para Sparking ZERO
set "TRABAJO=%TEMP%\ModSparkingZero_inst"
if exist "%TRABAJO%" rmdir /s /q "%TRABAJO%"
mkdir "%TRABAJO%" 2>nul
echo Preparando la instalacion, espera un momento...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%~dp0paquete.zip' -DestinationPath '%TRABAJO%' -Force"
if not exist "%TRABAJO%\instalar.bat" (
  echo ERROR: no he podido preparar los archivos.
  pause
  exit /b 1
)
call "%TRABAJO%\instalar.bat"
rmdir /s /q "%TRABAJO%" 2>nul
exit /b 0
'@
Set-Content -Path (Join-Path $tmp 'arranque.bat') -Value $lanzador -Encoding ASCII

# --- 4) El guion de IExpress (.sed) ---
$exeFinal = Join-Path $BASE "InstalarModSparkingZero-$fecha.exe"
if (Test-Path $exeFinal) { Remove-Item $exeFinal -Force }
# IExpress se atraganta con rutas que llevan ESPACIOS (y "mod sparkin" tiene uno), asi que se
# construye en una ruta limpia y despues se mueve el resultado a su sitio.
$exeTemp = Join-Path $tmp "InstalarModSparkingZero-$fecha.exe"

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exeTemp
FriendlyName=Mod de accesibilidad para DRAGON BALL Sparking ZERO
AppLaunched=cmd /c arranque.bat
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
FILE0="paquete.zip"
FILE1="arranque.bat"
[SourceFiles]
SourceFiles0=$tmp
[SourceFiles0]
%FILE0%=
%FILE1%=
"@
$sedPath = Join-Path $tmp 'instalador.sed'
Set-Content -Path $sedPath -Value $sed -Encoding ASCII

# --- 5) Construir ---
Write-Host '  llamando a IExpress (viene con Windows)...'
$p = Start-Process -FilePath 'iexpress.exe' -ArgumentList "/N", "`"$sedPath`"" -Wait -PassThru -NoNewWindow
if (-not (Test-Path $exeTemp)) { throw "IExpress no genero el .exe (codigo $($p.ExitCode)). El .zip si esta disponible." }
Move-Item $exeTemp $exeFinal -Force

Remove-Item $tmp -Recurse -Force
$mb = [math]::Round((Get-Item $exeFinal).Length / 1MB, 1)
Write-Host ''
Write-Host "LISTO" -ForegroundColor Green
Write-Host "  Ejecutable: $exeFinal  ($mb MB)"
Write-Host "  Comprimido: $zipFinal"

