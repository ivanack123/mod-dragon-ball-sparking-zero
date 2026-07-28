# Instalador TODO EN UNO del mod de accesibilidad para DRAGON BALL Sparking ZERO
#
# A diferencia del otro instalador, este LLEVA EL MOD DENTRO. No necesita ninguna
# carpeta al lado: se descarga el ejecutable, se abre, y ya esta.
#
# El paquete va incrustado como texto al final de este script y se extrae a una
# carpeta temporal en el momento de instalar. La carpeta temporal se borra al acabar.
#
# ACCESIBILIDAD: asistente de ventanas con controles estandar de Windows, que NVDA lee
# de forma nativa. Cada campo con su etiqueta y su nombre accesible, Enter activa el
# boton principal, Escape cancela, y al cambiar de paso cambia el titulo de la ventana
# y el foco salta al control principal, que es como el lector anuncia el cambio.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# El paquete incrustado. Lo rellena el generador; no editar a mano.
$PAQUETE_B64 = '@@PAYLOAD@@'

$script:temporal = $null

function Extraer-Paquete {
    $dir = Join-Path $env:TEMP ('ModSparkingZero_' + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir 'paquete.zip'
    [System.IO.File]::WriteAllBytes($zip, [System.Convert]::FromBase64String($PAQUETE_B64))
    $destino = Join-Path $dir 'contenido'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $destino)
    Remove-Item $zip -Force
    $script:temporal = $dir
    return (Join-Path $destino 'archivos')
}

function Limpiar-Temporal {
    if ($script:temporal -and (Test-Path $script:temporal)) {
        Remove-Item $script:temporal -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Buscar-Juego {
    $sub = 'steamapps\common\DRAGON BALL Sparking! ZERO\SparkingZERO\Binaries\Win64'
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath } catch { }
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $p = Join-Path $steam $sub
        if (Test-Path $p) { return $p }
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $p2 = Join-Path ($m.Groups[1].Value -replace '\\\\', '\') $sub
                if (Test-Path $p2) { return $p2 }
            }
        }
    }
    foreach ($u in 'C','D','E','F','G','H','I','J') {
        foreach ($r in "${u}:\Program Files (x86)\Steam", "${u}:\Steam", "${u}:\SteamLibrary", "${u}:\Games\Steam") {
            $p3 = Join-Path $r $sub
            if (Test-Path $p3) { return $p3 }
        }
    }
    return $null
}

function Parece-Juego { param($ruta)
    if (-not $ruta -or -not (Test-Path $ruta)) { return $false }
    return (Test-Path (Join-Path $ruta 'SparkingZERO-Win64-Shipping.exe')) -or (Test-Path (Join-Path $ruta 'steam_api64.dll'))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Instalador del mod de accesibilidad - Bienvenida'
$form.Size = New-Object System.Drawing.Size(640, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Add_FormClosed({ Limpiar-Temporal })

$titulo = New-Object System.Windows.Forms.Label
$titulo.Location = New-Object System.Drawing.Point(20, 20)
$titulo.Size = New-Object System.Drawing.Size(590, 30)
$titulo.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($titulo)

$texto = New-Object System.Windows.Forms.Label
$texto.Location = New-Object System.Drawing.Point(20, 60)
$texto.Size = New-Object System.Drawing.Size(590, 150)
$texto.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($texto)

$lblRuta = New-Object System.Windows.Forms.Label
$lblRuta.Location = New-Object System.Drawing.Point(20, 215)
$lblRuta.Size = New-Object System.Drawing.Size(590, 22)
$lblRuta.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$lblRuta.Text = 'Carpeta del juego:'
$lblRuta.Visible = $false
$form.Controls.Add($lblRuta)

$txtRuta = New-Object System.Windows.Forms.TextBox
$txtRuta.Location = New-Object System.Drawing.Point(20, 240)
$txtRuta.Size = New-Object System.Drawing.Size(470, 26)
$txtRuta.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$txtRuta.AccessibleName = 'Carpeta donde esta instalado el juego'
$txtRuta.AccessibleDescription = 'Ruta completa que termina en SparkingZERO, Binaries, Win64'
$txtRuta.Visible = $false
$form.Controls.Add($txtRuta)

$btnExaminar = New-Object System.Windows.Forms.Button
$btnExaminar.Location = New-Object System.Drawing.Point(500, 239)
$btnExaminar.Size = New-Object System.Drawing.Size(110, 28)
$btnExaminar.Text = 'Examinar'
$btnExaminar.AccessibleName = 'Examinar para elegir la carpeta del juego'
$btnExaminar.Visible = $false
$form.Controls.Add($btnExaminar)

$barra = New-Object System.Windows.Forms.ProgressBar
$barra.Location = New-Object System.Drawing.Point(20, 240)
$barra.Size = New-Object System.Drawing.Size(590, 26)
$barra.Style = 'Continuous'
$barra.Visible = $false
$form.Controls.Add($barra)

$btnAtras = New-Object System.Windows.Forms.Button
$btnAtras.Location = New-Object System.Drawing.Point(280, 330)
$btnAtras.Size = New-Object System.Drawing.Size(100, 32)
$btnAtras.Text = 'Atras'
$btnAtras.AccessibleName = 'Volver al paso anterior'
$btnAtras.Visible = $false
$form.Controls.Add($btnAtras)

$btnPrincipal = New-Object System.Windows.Forms.Button
$btnPrincipal.Location = New-Object System.Drawing.Point(390, 330)
$btnPrincipal.Size = New-Object System.Drawing.Size(110, 32)
$btnPrincipal.Text = 'Siguiente'
$form.Controls.Add($btnPrincipal)

$btnCancelar = New-Object System.Windows.Forms.Button
$btnCancelar.Location = New-Object System.Drawing.Point(510, 330)
$btnCancelar.Size = New-Object System.Drawing.Size(100, 32)
$btnCancelar.Text = 'Cancelar'
$btnCancelar.AccessibleName = 'Cancelar la instalacion y cerrar'
$form.Controls.Add($btnCancelar)

$form.AcceptButton = $btnPrincipal
$form.CancelButton = $btnCancelar

$script:paso = 1
$script:destino = $null

function Ir-A { param([int]$n)
    $script:paso = $n
    $txtRuta.Visible = $false; $lblRuta.Visible = $false; $btnExaminar.Visible = $false
    $barra.Visible = $false; $btnAtras.Visible = $false
    $btnCancelar.Enabled = $true; $btnPrincipal.Enabled = $true

    switch ($n) {
        1 {
            $form.Text = 'Instalador del mod de accesibilidad - Bienvenida'
            $titulo.Text = 'Mod de accesibilidad para DRAGON BALL Sparking ZERO'
            $texto.Text = "Este asistente instalara el mod que hace hablar al juego, para poder jugarlo sin ver.`r`n`r`nLee los menus, los subtitulos, la vida y el ki en combate, las recompensas, la Enciclopedia, la Tienda y mucho mas.`r`n`r`nTodo lo necesario viene dentro de este mismo programa: no hace falta descargar nada mas.`r`n`r`nAntes de continuar, cierra el juego si lo tienes abierto. Pulsa Siguiente."
            $btnPrincipal.Text = 'Siguiente'
            $btnPrincipal.AccessibleName = 'Siguiente, ir a elegir la carpeta del juego'
            $btnPrincipal.Focus()
        }
        2 {
            $form.Text = 'Instalador del mod de accesibilidad - Carpeta del juego'
            $titulo.Text = 'Carpeta del juego'
            $encontrado = Buscar-Juego
            if ($encontrado) {
                $texto.Text = "He encontrado el juego solo. Si la carpeta es correcta, pulsa Instalar.`r`n`r`nSi no lo es, puedes escribir otra ruta o buscarla con el boton Examinar."
                $txtRuta.Text = $encontrado
            } else {
                $texto.Text = "No he podido encontrar el juego automaticamente.`r`n`r`nEscribe la ruta de la carpeta del juego, o buscala con el boton Examinar. Suele terminar en SparkingZERO, Binaries, Win64.`r`n`r`nPara saberla: abre Steam, busca el juego en tu biblioteca, entra en sus propiedades, seccion de archivos instalados, y usa examinar los archivos locales."
                $txtRuta.Text = ''
            }
            $lblRuta.Visible = $true; $txtRuta.Visible = $true; $btnExaminar.Visible = $true
            $btnAtras.Visible = $true
            $btnPrincipal.Text = 'Instalar'
            $btnPrincipal.AccessibleName = 'Instalar el mod en la carpeta indicada'
            $txtRuta.Focus()
            $txtRuta.SelectionStart = $txtRuta.Text.Length
        }
        3 {
            $form.Text = 'Instalador del mod de accesibilidad - Instalando'
            $titulo.Text = 'Instalando'
            $texto.Text = 'Preparando y copiando los archivos del mod. Espera un momento, por favor.'
            $barra.Visible = $true
            $btnPrincipal.Enabled = $false
            $btnCancelar.Enabled = $false
        }
        4 {
            $form.Text = 'Instalador del mod de accesibilidad - Instalacion terminada'
            $titulo.Text = 'Instalacion terminada'
            $texto.Text = "El mod ha quedado instalado correctamente.`r`n`r`nYa puedes abrir el juego. Deberia empezar a hablarte en cuanto llegue a la pantalla de inicio.`r`n`r`nDentro del juego, la tecla F6 repite las ultimas recompensas y la F7 los detalles del mapa de historia.`r`n`r`nSi algun dia quieres quitarlo, borra el archivo dwmapi.dll de la carpeta del juego.`r`n`r`nPulsa Finalizar para cerrar."
            $btnPrincipal.Text = 'Finalizar'
            $btnPrincipal.AccessibleName = 'Finalizar y cerrar el instalador'
            $btnCancelar.Visible = $false
            $btnPrincipal.Focus()
        }
    }
}

$btnExaminar.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Elige la carpeta Win64 del juego'
    if ($d.ShowDialog() -eq 'OK') { $txtRuta.Text = $d.SelectedPath; $txtRuta.Focus() }
})

$btnAtras.Add_Click({ Ir-A 1 })
$btnCancelar.Add_Click({ $form.Close() })

$btnPrincipal.Add_Click({
    switch ($script:paso) {
        1 { Ir-A 2 }
        2 {
            $ruta = $txtRuta.Text.Trim().Trim('"')
            if (-not (Test-Path $ruta)) {
                [System.Windows.Forms.MessageBox]::Show('Esa carpeta no existe. Revisa la ruta.', 'Carpeta no encontrada', 'OK', 'Warning') | Out-Null
                $txtRuta.Focus(); return
            }
            if (-not (Parece-Juego $ruta)) {
                $r = [System.Windows.Forms.MessageBox]::Show(
                    "Esa carpeta no parece la del juego: no he encontrado dentro los archivos que esperaba.`r`n`r`nDeseas instalar ahi de todas formas?",
                    'Comprobacion de la carpeta', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { $txtRuta.Focus(); return }
            }
            $script:destino = $ruta
            Ir-A 3
            $form.Refresh()
            try {
                $barra.Value = 15
                $origen = Extraer-Paquete
                $barra.Value = 50
                if (-not (Test-Path $origen)) { throw 'El paquete incrustado no contiene los archivos esperados.' }
                Copy-Item (Join-Path $origen '*') $script:destino -Recurse -Force -ErrorAction Stop
                $barra.Value = 85
                $comprobar = Join-Path $script:destino 'Mods\dragon-ball-sparking-zero-access\Scripts\main.lua'
                if (-not (Test-Path $comprobar)) { throw 'La copia termino pero no encuentro los archivos del mod en su sitio.' }
                Limpiar-Temporal
                $barra.Value = 100
                Ir-A 4
            } catch {
                Limpiar-Temporal
                [System.Windows.Forms.MessageBox]::Show(
                    "No se pudieron copiar los archivos.`r`n`r`nSi el juego esta en Archivos de programa, cierra este instalador, pulsa el boton derecho sobre el y elige ejecutar como administrador.`r`n`r`nDetalle: $($_.Exception.Message)",
                    'Error al instalar', 'OK', 'Error') | Out-Null
                Ir-A 2
            }
        }
        4 { $form.Close() }
    }
})

Ir-A 1
[void]$form.ShowDialog()
