# -*- coding: utf-8 -*-
"""
Quita FISICAMENTE del mod la maquinaria de cazar crashes, para la version publica.

Por que existe este script y no se borra a mano:
  Son unas 300 lineas repartidas por cuatro archivos grandes. Borrarlas a mano una vez
  es asumible; hacerlo bien en CADA version que se publique, no. Y un corte mal hecho en
  Lua deja el mod sin cargar, o sea al usuario sin voz y sin saber por que. Asi el borrado
  es siempre el mismo, se puede repetir, y al final se comprueba que el Lua sigue siendo
  valido antes de empaquetar nada.

Lo que quita:
  - El registro de eventos en disco y el envoltorio de `print` que lo alimentaba.
  - Las migajas (`Crumb`): la funcion, la lectura de las tres, y las 43 llamadas.
  - El espejo del log de UE4SS (`SnapshotLog`) y sus llamadas.
  - El historial de crashes que se guardaba al arrancar.
  - Los mensajes `[AE-DIAG]` de main, gallery y poll_trackers, y la sonda de sysmsg.
  - En debug_tools: las migajas del volcado.

Lo que NO toca:
  - Nada de la lectura de pantalla. Ni una linea.
  - F3, F4 y F5: siguen funcionando. Lo unico que cambia es que ya no crean la carpeta
    al arrancar (se crea al pulsarlas) y que cada archivo se vacia en su primer uso de la
    sesion, asi que capturan el estado ACTUAL y no un historial que crece.
  - Los frenos anti-crash (uiChurnUntil y compania): esos protegen al usuario, no
    diagnostican. Se quedan.
"""

import io
import os
import re
import sys

# --- utilidades -------------------------------------------------------------

class Fallo(Exception):
    pass


def leer(ruta):
    with io.open(ruta, encoding='utf-8') as f:
        return f.read().split('\n')


def escribir(ruta, lineas):
    with io.open(ruta, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write('\n'.join(lineas))


def indice_de(lineas, texto, desde=0):
    """Primera linea que EMPIEZA por `texto` (ya sin espacios). Falla si no esta."""
    for i in range(desde, len(lineas)):
        if lineas[i].strip().startswith(texto):
            return i
    raise Fallo('no encuentro el ancla: ' + texto)


def fin_de_bloque(lineas, inicio):
    """Primer `end` o `end)` pegado al margen izquierdo. Los bloques que quitamos son
    todos de primer nivel, asi que su cierre esta en la columna 0 y no hay ambiguedad."""
    for i in range(inicio + 1, len(lineas)):
        if lineas[i] in ('end', 'end)'):
            return i
    raise Fallo('no encuentro el cierre del bloque que empieza en la linea %d' % (inicio + 1))


def borrar_rango(lineas, i, j):
    """Borra de i a j inclusive."""
    del lineas[i:j + 1]


def borrar_bloque(lineas, ancla_comentario, ancla_codigo):
    """Borra desde el comentario que lo explica hasta el `end` que lo cierra."""
    i = indice_de(lineas, ancla_comentario)
    k = indice_de(lineas, ancla_codigo, i)
    j = fin_de_bloque(lineas, k)
    borrar_rango(lineas, i, j)
    return j - i + 1


def borrar_llamadas(lineas, patron):
    """Borra las lineas que son SOLO una llamada (o un `if ... then llamada end`)."""
    rx = re.compile(patron)
    quitadas = 0
    for i in range(len(lineas) - 1, -1, -1):
        s = lineas[i].strip()
        if s.startswith('--'):
            continue
        if rx.match(s):
            del lineas[i]
            quitadas += 1
    return quitadas


def borrar_print_diag(lineas):
    """Borra los `print("[AE-DIAG] ...")`, incluidos los que ocupan varias lineas.

    Se cuentan los parentesis desde el `print(` hasta que se cierran, saltando los que
    van dentro de comillas. Asi un print partido en dos o tres lineas se va entero y no
    queda media instruccion suelta."""
    quitados = 0
    i = 0
    while i < len(lineas):
        s = lineas[i].strip()
        if s.startswith('print(') and '[AE-DIAG]' in s:
            j = i
            saldo = 0
            visto = False
            while j < len(lineas):
                dentro = None
                escape = False
                for c in lineas[j]:
                    if dentro:
                        if escape:
                            escape = False
                        elif c == '\\':
                            escape = True
                        elif c == dentro:
                            dentro = None
                        continue
                    if c in ('"', "'"):
                        dentro = c
                    elif c == '(':
                        saldo += 1
                        visto = True
                    elif c == ')':
                        saldo -= 1
                if visto and saldo == 0:
                    break
                j += 1
            if saldo != 0:
                raise Fallo('print [AE-DIAG] sin cerrar en la linea %d' % (i + 1))
            borrar_rango(lineas, i, j)
            quitados += 1
            continue
        i += 1
    return quitados


# --- main.lua ---------------------------------------------------------------

def limpiar_main(ruta):
    L = leer(ruta)
    n0 = len(L)

    # 1) El interruptor, el registro de eventos en disco y el envoltorio de print.
    #    Va todo seguido, desde su cabecera hasta justo antes de la carga de modulos.
    i = indice_de(L, '-- === ZERO-GAP LIVE EVENT LOG ===')
    j = indice_de(L, '-- === MODULE LOADING ===', i) - 1
    while j > i and L[j].strip() == '':
        j -= 1
    if 'AE_DIAG' not in '\n'.join(L[i:j + 1]):
        raise Fallo('el bloque del interruptor no contiene AE_DIAG; el archivo ha cambiado')
    borrar_rango(L, i, j)

    # 2) Las migajas: la declaracion adelantada, la funcion que las escribe y la que lee
    #    las tres. La declaracion adelantada (`local Crumb`) va con su comentario, y hay
    #    que quitarla tambien: si se queda, es una variable suelta que no apunta a nada.
    i = indice_de(L, '-- DECLARACIÓN ADELANTADA de Crumb')
    j = indice_de(L, 'local Crumb', i)
    if L[j].strip() != 'local Crumb':
        raise Fallo('la declaracion adelantada de Crumb no es la que esperaba')
    borrar_rango(L, i, j)
    borrar_bloque(L, '-- TEMP hang breadcrumb', 'function Crumb(tag)')
    borrar_bloque(L, '-- Lee las tres migajas', 'local function ReadAllCrumbs()')

    # 3) El espejo del log de UE4SS.
    borrar_bloque(L, '-- Rolling log mirror.', 'local function SnapshotLog(force)')

    # 4) El historial de crashes que se guardaba en cada arranque.
    borrar_bloque(L, '-- Crash history (persists across restarts)', 'pcall(function()')

    # 5) Las llamadas. Todas ocupan su linea entera: o son `Crumb("...")` sueltas, o van
    #    dentro de un `if ... then Crumb("...") end` de una sola linea.
    #    Algunas llevan un comentario detras, asi que se admite `... end  -- lo que sea`.
    crumbs = borrar_llamadas(L, r'^(Crumb\(|if .+ then Crumb\(.*\) end(\s*--.*)?$)')
    if crumbs < 40:
        raise Fallo('esperaba unas 42 llamadas a Crumb y solo he quitado %d' % crumbs)
    borrar_llamadas(L, r'^(SnapshotLog\(|if .+ then SnapshotLog\(.*\) end(\s*--.*)?$)')

    # 6) El vigilante leia la migaja para decir en que se habia colgado. Sin migajas, se
    #    queda con el aviso normal: sigue reiniciando los bucles igual que antes.
    texto = '\n'.join(L)
    viejo = """            -- Capture which poller the hung loop was inside (the crumb) BEFORE restarting
            -- overwrites it — this is how we identify the culprit of a recovered hang.
            local crumb = ReadAllCrumbs()  -- las TRES migajas (foco, poll, volcado F5)
            print("[AE] Watchdog: loops died (focus=" .. tostring(focusDead)
                .. " poll=" .. tostring(pollDead) .. ") at crumb '" .. tostring(crumb)
                .. "' focusStage=" .. tostring(_focusStage) .. " idx=" .. tostring(_focusScanIdx)
                .. "/" .. tostring(_focusScanTotal) .. ", restarting")"""
    nuevo = """            print("[AE] Watchdog: loops died (focus=" .. tostring(focusDead)
                .. " poll=" .. tostring(pollDead) .. "), restarting")"""
    if viejo not in texto:
        raise Fallo('el bloque del vigilante no coincide; revisar a mano')
    L = texto.replace(viejo, nuevo).split('\n')

    # 7) Los mensajes de diagnostico.
    borrar_print_diag(L)

    if 'AE_DIAG' in '\n'.join(L) or 'Crumb(' in '\n'.join(L):
        raise Fallo('han quedado restos de AE_DIAG o de las migajas en main.lua')

    escribir(ruta, L)
    return n0 - len(L)


# --- gallery.lua y poll_trackers.lua ---------------------------------------

def limpiar_gallery(ruta):
    L = leer(ruta)
    n0 = len(L)
    borrar_print_diag(L)
    escribir(ruta, L)
    return n0 - len(L)


def limpiar_poll_trackers(ruta):
    L = leer(ruta)
    n0 = len(L)
    # La sonda de sysmsg no solo imprimia: llamaba a GetCachedFirstOf a proposito para
    # poder informar. Fuera del diagnostico esa llamada no pinta nada, asi que se va el
    # bloque entero y de paso el juego se ahorra la busqueda.
    try:
        i = indice_de(L, 'if not _sysMsgGateDiagDone then')
        j = i
        while j < len(L) and L[j].strip() != 'end':
            j += 1
        if j < len(L) and '[AE-DIAG]' in '\n'.join(L[i:j + 1]):
            borrar_rango(L, i, j)
    except Fallo:
        pass
    # Y la bandera que solo servia para que esa sonda se ejecutara una vez.
    for k in range(len(L) - 1, -1, -1):
        if L[k].strip().startswith('local _sysMsgGateDiagDone'):
            del L[k]
    borrar_print_diag(L)
    escribir(ruta, L)
    return n0 - len(L)


# --- debug_tools.lua --------------------------------------------------------

def limpiar_debug_tools(ruta):
    """F3/F4/F5 se quedan. Lo que se va son las migajas del volcado y las escrituras
    que se hacian al arrancar sin que nadie las pidiera."""
    with io.open(ruta, encoding='utf-8') as f:
        t = f.read()
    n0 = t.count('\n')

    # La carpeta se crea cuando de verdad hay algo que escribir, y cada archivo se vacia
    # en su primer uso de esta sesion (antes se vaciaban todos al arrancar).
    viejo = '''local DUMP_DIR = "AE_debug"

local function WriteDump(filename, content)
    local f = io.open(DUMP_DIR .. "/" .. filename, "w")'''
    nuevo = '''local DUMP_DIR = "AE_debug"

-- La carpeta y los archivos se crean cuando de verdad hay algo que volcar, o sea solo si
-- se pulsa F3, F4 o F5. Si no se pulsan, el mod no deja nada en el disco.
local _dumpDirReady = false
local function EnsureDumpDir()
    if _dumpDirReady then return end
    _dumpDirReady = true
    pcall(os.execute, "mkdir " .. DUMP_DIR .. " 2>NUL")
end

-- Cada archivo se vacia en su PRIMER uso de esta sesion y a partir de ahi ya se añade.
-- Asi un volcado recoge lo de ahora y no arrastra el de la vez anterior.
local _primerUso = {}

local function WriteDump(filename, content)
    EnsureDumpDir()
    _primerUso[filename] = true
    local f = io.open(DUMP_DIR .. "/" .. filename, "w")'''
    if viejo not in t:
        raise Fallo('no encuentro WriteDump tal y como esperaba')
    t = t.replace(viejo, nuevo, 1)

    viejo = '''local function AppendDump(filename, content)
    local f = io.open(DUMP_DIR .. "/" .. filename, "a")'''
    nuevo = '''local function AppendDump(filename, content)
    EnsureDumpDir()
    local modo = "a"
    if not _primerUso[filename] then
        _primerUso[filename] = true
        modo = "w"
    end
    local f = io.open(DUMP_DIR .. "/" .. filename, modo)'''
    if viejo not in t:
        raise Fallo('no encuentro AppendDump tal y como esperaba')
    t = t.replace(viejo, nuevo, 1)

    # Init ya no escribe nada al arrancar.
    viejo = '''    -- Create dump directory
    os.execute("mkdir " .. DUMP_DIR .. " 2>NUL")

    -- Clear dump files on startup
    local filesToClear = {"debug_dump.txt", "chara_select.txt", "battle_gauges.txt", "battle_state.txt"}
    for _, f in ipairs(filesToClear) do
        local fh = io.open(DUMP_DIR .. "/" .. f, "w")
        if fh then
            fh:write("(cleared on startup " .. os.date("%Y-%m-%d %H:%M:%S") .. ")\\n\\n")
            fh:close()
        end
    end

'''
    if viejo not in t:
        raise Fallo('no encuentro el bloque de arranque de Init tal y como esperaba')
    t = t.replace(viejo, '', 1)

    L = t.split('\n')

    # Las migajas del volcado: la del freno, la de escaneo, la de reposo y la de apagado.
    # El FRENO en si se queda: eso protege al usuario, no diagnostica.
    viejo_freno = '''        local T = package.loaded["poll_trackers"]
        if T and T.uiChurnUntil and os.clock() < T.uiChurnUntil then
            local oks, sf = pcall(io.open, "AE_debug/ae_crumb_dump.txt", "w")
            if oks and sf then sf:write("D:churnskip " .. os.date("%H:%M:%S")); sf:close() end
            return false  -- saltar este ciclo, seguir vivo
        end'''
    nuevo_freno = '''        local T = package.loaded["poll_trackers"]
        if T and T.uiChurnUntil and os.clock() < T.uiChurnUntil then
            return false  -- saltar este ciclo, seguir vivo
        end'''
    t = '\n'.join(L)
    if viejo_freno not in t:
        raise Fallo('no encuentro el freno de churn del volcado')
    t = t.replace(viejo_freno, nuevo_freno, 1)

    for viejo in ('''        local _T = package.loaded["poll_trackers"]
        local _diag = not _T or _T.aeDiag ~= false
        if _diag then
            local okc, cf = pcall(io.open, "AE_debug/ae_crumb_dump.txt", "w")
            if okc and cf then cf:write("D:scan " .. os.date("%H:%M:%S")); cf:close() end
        end
''', '''        if _diag then
            local okd, df = pcall(io.open, "AE_debug/ae_crumb_dump.txt", "w")
            if okd and df then df:write("D:idle " .. os.date("%H:%M:%S")); df:close() end
        end
''', '''local function CrumbDumpOff()
    local ok, f = pcall(io.open, "AE_debug/ae_crumb_dump.txt", "w")
    if ok and f then f:write("D:off"); f:close() end
end

''', '''    -- Deja la migaja del volcado en "apagado" al arrancar: si esta sesión no usa F5, un `D:idle`
    -- heredado de la sesión anterior no debe hacernos creer que el volcado estaba corriendo.
'''):
        if viejo not in t:
            raise Fallo('no encuentro un trozo de migaja del volcado: ' + viejo.strip()[:60])
        t = t.replace(viejo, '', 1)

    # `CrumbDumpOff()` se llamaba DOS veces: al detener el volcado y al cargar el modulo.
    # Hay que quitar LAS DOS. Quitar solo la primera dejaba una llamada a una funcion que
    # ya no existe: el modulo reventaba al cargar y el usuario se quedaba sin F3/F4/F5,
    # y eso un comprobador de sintaxis no lo ve, porque sintacticamente es correcto.
    if t.count('    CrumbDumpOff()\n') != 2:
        raise Fallo('esperaba 2 llamadas a CrumbDumpOff y hay %d'
                    % t.count('    CrumbDumpOff()\n'))
    t = t.replace('    CrumbDumpOff()\n', '')

    for resto in ('ae_crumb', 'aeDiag', 'CrumbDumpOff'):
        if resto in t:
            raise Fallo('han quedado restos en debug_tools.lua: ' + resto)

    with io.open(ruta, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(t)
    return n0 - t.count('\n')


# --- comprobacion final -----------------------------------------------------

def comprobar_sintaxis(carpeta):
    try:
        from luaparser import ast
    except ImportError:
        print('  AVISO: no esta luaparser, no puedo comprobar la sintaxis.')
        print('         Instalalo con:  python -m pip install luaparser')
        return False
    malos = []
    for nombre in sorted(os.listdir(carpeta)):
        if not nombre.endswith('.lua'):
            continue
        ruta = os.path.join(carpeta, nombre)
        with io.open(ruta, encoding='utf-8', errors='replace') as f:
            src = f.read()
        try:
            ast.parse(src)
        except Exception as e:
            malos.append((nombre, str(e).splitlines()[0][:160]))
    if malos:
        for nombre, err in malos:
            print('  SINTAXIS ROTA: %s -> %s' % (nombre, err))
        raise Fallo('el Lua resultante no es valido; NO se publica')
    print('  sintaxis comprobada: los %d archivos siguen siendo Lua valido'
          % len([n for n in os.listdir(carpeta) if n.endswith('.lua')]))
    return True


def comprobar_restos(carpeta):
    """Busca referencias a cosas que acabamos de borrar.

    Esto NO lo pilla el comprobador de sintaxis: llamar a una funcion que ya no existe es
    Lua perfectamente valido, y el fallo solo aparece al ejecutarlo, cuando el modulo
    revienta y el usuario se queda sin voz. Ya paso una vez con `CrumbDumpOff`, que se
    llamaba desde dos sitios y solo se quito uno."""
    borrados = ['Crumb', 'ReadAllCrumbs', 'SnapshotLog', 'CrumbDumpOff', 'AE_DIAG',
                'aeDiag', '_prevLiveLog', '_lastLogSnapshot', 'AE-DIAG',
                '_sysMsgGateDiagDone']
    rx = re.compile(r'\b(' + '|'.join(re.escape(b) for b in borrados) + r')\b')
    restos = []
    for nombre in sorted(os.listdir(carpeta)):
        if not nombre.endswith('.lua'):
            continue
        with io.open(os.path.join(carpeta, nombre), encoding='utf-8', errors='replace') as f:
            for n, linea in enumerate(f, 1):
                sin_comentario = linea.split('--', 1)[0]
                if rx.search(sin_comentario):
                    restos.append('%s:%d: %s' % (nombre, n, linea.strip()[:110]))
    if restos:
        for r in restos:
            print('  RESTO: ' + r)
        raise Fallo('quedan referencias a codigo que ya no existe; NO se publica')
    print('  sin referencias colgadas: nada apunta a lo que se ha borrado')


def main():
    if len(sys.argv) != 2:
        print('uso: python limpiar-diagnosticos.py <carpeta Scripts de la version publica>')
        return 2
    carpeta = sys.argv[1]
    if not os.path.isdir(carpeta):
        print('no existe la carpeta: ' + carpeta)
        return 2

    trabajos = [
        ('main.lua', limpiar_main),
        ('gallery.lua', limpiar_gallery),
        ('poll_trackers.lua', limpiar_poll_trackers),
        ('debug_tools.lua', limpiar_debug_tools),
    ]
    total = 0
    for nombre, funcion in trabajos:
        ruta = os.path.join(carpeta, nombre)
        if not os.path.isfile(ruta):
            print('  FALTA %s' % nombre)
            return 1
        quitadas = funcion(ruta)
        total += quitadas
        print('  %-18s -%d lineas' % (nombre, quitadas))
    print('  total quitado: %d lineas de diagnostico' % total)
    comprobar_sintaxis(carpeta)
    comprobar_restos(carpeta)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Fallo as e:
        print('')
        print('ERROR: ' + str(e))
        print('No se ha publicado nada. Revisar antes de empaquetar.')
        sys.exit(1)
