@echo off
setlocal enabledelayedexpansion
title Instalador del mod de accesibilidad para Sparking ZERO

REM ---------------------------------------------------------------
REM  Instalador del mod de accesibilidad para DRAGON BALL Sparking ZERO
REM
REM  Es un archivo de texto a proposito, no un .exe: asi cualquiera
REM  puede abrirlo y leer exactamente lo que hace, y Windows no lo
REM  bloquea con avisos de seguridad que estorban a un lector de
REM  pantalla.
REM
REM  Lo que hace: busca la carpeta del juego, comprueba que es la
REM  correcta, y copia los archivos de la carpeta "archivos".
REM  Sin acentos ni simbolos raros en los mensajes, para que se
REM  lean bien en la consola de Windows.
REM ---------------------------------------------------------------

echo.
echo ===============================================================
echo  INSTALADOR DEL MOD DE ACCESIBILIDAD PARA SPARKING ZERO
echo ===============================================================
echo.
echo Voy a buscar la carpeta donde tienes instalado el juego.
echo.

set "ORIGEN=%~dp0archivos"
if not exist "%ORIGEN%" (
  echo ERROR: no encuentro la carpeta "archivos" junto a este instalador.
  echo Descomprime el paquete entero antes de ejecutarlo.
  echo.
  pause
  exit /b 1
)

set "DESTINO="
set "SUBRUTA=steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64"

REM --- 1) Preguntar al registro de Windows donde esta Steam ---
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| find "SteamPath"') do set "STEAMDIR=%%B"
if defined STEAMDIR (
  set "STEAMDIR=!STEAMDIR:/=\!"
  if exist "!STEAMDIR!\%SUBRUTA%" set "DESTINO=!STEAMDIR!\%SUBRUTA%"
)

REM --- 2) Leer las bibliotecas adicionales de Steam (otros discos) ---
if not defined DESTINO if defined STEAMDIR (
  if exist "!STEAMDIR!\steamapps\libraryfolders.vdf" (
    for /f "tokens=2 delims==" %%L in ('findstr /i "\"path\"" "!STEAMDIR!\steamapps\libraryfolders.vdf"') do (
      set "LIB=%%L"
      set "LIB=!LIB:"=!"
      set "LIB=!LIB:\\=\!"
      call :quitaespacios LIB
      if exist "!LIB!\%SUBRUTA%" set "DESTINO=!LIB!\%SUBRUTA%"
    )
  )
)

REM --- 3) Rutas tipicas en todas las unidades ---
if not defined DESTINO (
  for %%D in (C D E F G H I J) do (
    if exist "%%D:\Program Files (x86)\Steam\%SUBRUTA%" set "DESTINO=%%D:\Program Files (x86)\Steam\%SUBRUTA%"
    if exist "%%D:\Steam\%SUBRUTA%" set "DESTINO=%%D:\Steam\%SUBRUTA%"
    if exist "%%D:\SteamLibrary\%SUBRUTA%" set "DESTINO=%%D:\SteamLibrary\%SUBRUTA%"
    if exist "%%D:\Games\Steam\%SUBRUTA%" set "DESTINO=%%D:\Games\Steam\%SUBRUTA%"
  )
)

REM --- 4) Si no aparece, que lo escriba la persona ---
if not defined DESTINO (
  echo No he podido encontrar el juego solo.
  echo.
  echo Escribe la ruta completa de la carpeta Win64 del juego.
  echo Suele terminar en: SparkingZERO\Binaries\Win64
  echo.
  set /p "DESTINO=Ruta: "
  set "DESTINO=!DESTINO:"=!"
)

if not exist "%DESTINO%" (
  echo.
  echo ERROR: esa carpeta no existe. Revisa la ruta y vuelve a intentarlo.
  echo.
  pause
  exit /b 1
)

REM --- Comprobacion de seguridad: que sea de verdad la carpeta del juego ---
if not exist "%DESTINO%\SparkingZERO-Win64-Shipping.exe" (
  if not exist "%DESTINO%\steam_api64.dll" (
    echo.
    echo AVISO: esa carpeta no parece la del juego.
    echo No he encontrado dentro los archivos que esperaba.
    echo.
    set /p "SEGUIR=Escribe SI para continuar de todas formas: "
    if /i not "!SEGUIR!"=="SI" (
      echo Instalacion cancelada. No se ha copiado nada.
      echo.
      pause
      exit /b 1
    )
  )
)

echo.
echo Juego encontrado en:
echo   %DESTINO%
echo.
echo Voy a copiar los archivos del mod. Espera un momento.
echo.

xcopy "%ORIGEN%\*" "%DESTINO%\" /E /I /Y >nul
if errorlevel 1 (
  echo.
  echo ERROR al copiar. Puede que necesites permisos de administrador.
  echo Cierra esta ventana, pulsa el boton derecho sobre instalar.bat
  echo y elige la opcion de ejecutar como administrador.
  echo.
  pause
  exit /b 1
)

echo.
echo ===============================================================
echo  LISTO. El mod ha quedado instalado.
echo ===============================================================
echo.
echo Ya puedes abrir el juego. Deberia empezar a hablarte en cuanto
echo llegue a la pantalla de inicio.
echo.
echo Si algun dia quieres quitarlo, borra el archivo dwmapi.dll de
echo esa misma carpeta del juego.
echo.
pause
exit /b 0

:quitaespacios
setlocal
set "v=!%1!"
for /f "tokens=* delims= " %%a in ("!v!") do set "v=%%a"
endlocal & set "%1=%v%"
goto :eof
