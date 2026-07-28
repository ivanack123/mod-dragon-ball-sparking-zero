--[[
    SparkingZeroAccess - UE4SS Lua Mod
    Phase 2: Live menu reader

    Uses targeted polling on known interactive widget classes.
    IsValid() guards all UObject access. World-identity polling
    handles screen transitions. Watchdog restarts dead loops.

    Reader starts automatically on game launch.
]]

-- === ZERO-GAP LIVE EVENT LOG ===
-- The periodic UE4SS.log mirror (SnapshotLog, below) can be up to a few seconds stale, so a
-- crash in a quiet non-transition moment could lose the final seconds of CONTEXT (the crumb
-- still pins the exact crashing step â€” that's never stale). To close that last gap completely,
-- mirror every [AE] message to a persistent file THE INSTANT it is printed. A native crash can't
-- run code after it, so the only way to have up-to-the-moment context is to already be on disk:
-- open-append-close per line flushes each line to the OS before the next runs, and the OS keeps
-- those buffers even when the process dies (only power loss would lose them). Open-append-close
-- (vs a held handle) survives UE4SS hot-reloads with no handle to leak. Filtered to [AE] lines to
-- bound volume; SnapshotLog trims the file if it ever grows past a cap. Cheap on SSD.
-- Installed BEFORE the requires so module-load prints are captured too. `_prevLiveLog` grabs the
-- previous session's log before we reset it, so the init block (bottom) can archive it on crash.
-- ############################################################################
-- #  INTERRUPTOR DE DIAGNÃ“STICO  (07-28)
-- #
-- #  true  = versiÃ³n de TRABAJO (la nuestra): escribe el registro de eventos,
-- #          las migajas de crash, el espejo del log y el historial, y emite los
-- #          mensajes de diagnÃ³stico [AE-DIAG].
-- #  false = versiÃ³n PÃšBLICA: nada de eso. El mod solo habla.
-- #
-- #  OJO â€” LO QUE **NO** APAGA ESTE INTERRUPTOR: las teclas F3, F4 y F5
-- #  (debug_tools). Esas son funciones del PROYECTO, no diagnÃ³sticos de una
-- #  cacerÃ­a concreta, y deben seguir funcionando para todo el mundo. Lo que se
-- #  apaga es la maquinaria de investigaciÃ³n que se fue aÃ±adiendo para perseguir
-- #  crashes: migajas, mediciones de tiempos y avisos temporales.
-- #
-- #  Por quÃ© un interruptor y no dos copias del cÃ³digo: dos copias se
-- #  desincronizan en cuanto se arregla algo, y ademÃ¡s borrar lÃ­neas de
-- #  diagnÃ³stico a mano puede romper la sintaxis y dejar el mod sin cargar â€”
-- #  o sea, al usuario sin voz. AsÃ­ hay UN solo cÃ³digo y el empaquetador
-- #  cambia esta Ãºnica lÃ­nea.
-- #
-- #  NO PONERLO A false EN LA COPIA DE TRABAJO: sin migajas ni registro nos
-- #  quedamos ciegos para diagnosticar (es la herramienta con la que hemos
-- #  cerrado todos los crashes).
-- ############################################################################
local AE_DIAG = false
-- Se publica para los mÃ³dulos que tambiÃ©n escriben diagnÃ³sticos propios (debug_tools).
pcall(function() require("poll_trackers").aeDiag = AE_DIAG end)

local _prevLiveLog = nil
if AE_DIAG then
pcall(function()
    local f = io.open("AE_debug/ae_livelog.txt", "r")
    if f then _prevLiveLog = f:read("*a"); f:close() end
end)
pcall(function()
    local f = io.open("AE_debug/ae_livelog.txt", "w") -- reset for this session
    if f then f:close() end
end)
end
do
    local _origPrint = print
    _G.print = function(...)
        -- VERSIÃ“N PÃšBLICA: ni se escribe el registro en disco, ni se emiten los mensajes de
        -- diagnÃ³stico. Filtrarlos AQUÃ, en un Ãºnico punto, silencia de golpe los [AE-DIAG] de todos
        -- los mÃ³dulos sin tener que tocar cada uno (y sin arriesgar la sintaxis de ninguno).
        if not AE_DIAG then
            local first = tostring((select(1, ...)))
            if first:find("[AE-DIAG]", 1, true) then return end
            _origPrint(...)
            return
        end
        _origPrint(...)
        -- Build the line HERE, in the function that owns `...`: varargs are NOT visible inside a
        -- nested function, so assembling the string inside the pcall closure would capture nothing.
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        local line = table.concat(parts, "\t")
        pcall(function()
            if line:find("[AE", 1, true) then
                local f = io.open("AE_debug/ae_livelog.txt", "a")
                if f then f:write(os.date("%H:%M:%S ") .. line .. "\n"); f:close() end
            end
        end)
    end
end

-- === MODULE LOADING ===

local H = require("helpers")
local TryCall = H.TryCall
local TryGetProperty = H.TryGetProperty
local IsValidRef = H.IsValidRef
local GetWidgetName = H.GetWidgetName
local GetClassName = H.GetClassName

local Speech = require("speech")
local Speak = Speech.Speak
local SpeakQueued = Speech.SpeakQueued

local WR = require("widget_reader")
local Trackers = require("poll_trackers")
local TeamOV = require("team_overview")
local Roster = require("chara_roster")
local SkillList = require("skill_list")
local Battle = require("battle")
local EpisodeBattle = require("episode_battle")
local Shop = require("shop")
local Gallery = require("gallery")

-- === FOCUS TRACKING ===

local readerEnabled = true
local lastFocusedName = nil
local lastSpokenLabel = nil
local lastFocusedWidget = nil
-- Dedup for the RESULT-screen buttons (Reintentar/Salir). Kept SEPARATE from lastSpokenLabel because
-- that one is cleared every time the focus pauses, and the result screen churns so the focus pauses/
-- resumes constantly â€” clearing it made the button re-read on every resume (IvÃ¡n 07-19). This survives
-- the pauses; reset only when a non-result widget is focused (see OnWidgetFocused).
local lastResultCaption = nil
local lastGuideMessage = nil
local lastListTitle = nil
local lastMatchedLabelWidget = nil
local lastCaptionValue = nil
local lastAnnouncedDialogId = nil
local lastOptionsTip = nil
local lastCharaName = nil
local slowPathCooldown = 0
local lastScreenContext = nil -- "team", "roster", "skilllist", "roomid", or nil
local teamSlotPollFrames = 0 -- counts frames waiting for bubble to appear
local roomIdDigitRefs = {}   -- cached TXT_Num TextBlock refs per IDPanel
local lastCaptionRef = nil   -- cached TextBlock/RichTextBlock ref for caption polling
local focusEmptyScanStreak = 0 -- consecutive ticks the slow-path scan returned nil
-- DIAG TEMPORAL (cacerÃ­a del colgÃ³n de foco 07-18): etapa/Ã­ndice del escaneo de foco, en MEMORIA
-- (cero I/O, cero nativas). El watchdog los lee al detectar la muerte del foco para des-enmascarar
-- DÃ“NDE se colgÃ³ (los pause-checks, el fast-path, o el recorrido de widgets y en quÃ© Ã­ndice). Quitar
-- al cerrar el caso.
-- DECLARACIÃ“N ADELANTADA de Crumb (07-26). La funciÃ³n se define mucho mÃ¡s abajo, pero ScanForFocus
-- (definida ANTES que ella) necesita poder dejar una migaja fina. Declarar aquÃ­ el local y asignarlo
-- luego es mÃ¡s seguro que mover el bloque: las llamadas ocurren en tiempo de ejecuciÃ³n, cuando el
-- archivo ya se cargÃ³ entero. NO quitar la palabra `local` de arriba ni volver a poner `local` abajo:
-- eso crearÃ­a dos variables distintas y las migajas finas dejarÃ­an de escribirse.
local Crumb

local _focusStage = "idle"
local _focusScanIdx = 0
local _focusScanTotal = 0
local lastFocusPauseReason = nil -- DIAG: last logged reason the focus scan was paused
-- DIAGNÃ“STICO TEMPORAL (2026-07-17) â€” se quita cuando cierre la investigaciÃ³n.
-- Registra SOLO los flancos de pauseMenuOpen. Es OBSERVACIÃ“N PURA: no gatea nada.
-- Para quÃ©: se quiere usar pauseMenuOpen como seÃ±al de "el juego estÃ¡ CONGELADO" para
-- arreglar el subtÃ­tulo repetido al pausar, pero NO hay forma de saber si da falsos
-- positivos â€” el diag existente ("focus paused: ... pauseVis=N") solo se imprime en la
-- rama `not pauseMenuOpen`, asÃ­ que un pauseMenuOpen=true NUNCA queda registrado.
-- Antes de usarlo como gate hay que probar EN VIVO que solo se enciende con la pausa
-- ABIERTA (LECCIÃ“N 14: un gate NO se valida con el F5; el intento de presencia de
-- WBP_Pause_C se validÃ³ asÃ­ y silenciÃ³ los barks 4m36s seguidos).
-- QUÃ‰ ESPERAR: pauseMenuOpen=true SOLO cuando IvÃ¡n pausa de verdad, y false al salir.
-- Si aparece true en pleno combate sin que Ã©l haya pausado => la seÃ±al NO sirve y el
-- fix del subtÃ­tulo queda definitivamente descartado.

local focusPauseUntil = 0    -- pause ONLY the focus scan (NOT the whole poll loop)
local lastWidgetCount = 0    -- previous UserWidget count, to detect UI rebuilds (see ScanForFocus)
local pollLastWidgetCount = 0 -- same, but sampled on the 100ms POLL tick (closes the focus-loop gap)
-- DIAG TEMPORAL (cacerÃ­a del crash de transiciÃ³n 07-17): estado del guardia por tick en la
-- ventana volÃ¡til. Quitar al cerrar el caso.
local _transDiagLast = 0
local _transVolatileUntil = 0
local _transDiagLastWC = 0
local churnStreak = 0        -- consecutive ticks the count kept moving (catches GRADUAL loads)
local menuWalkBlockStreak = 0 -- ticks seguidos que el walk se frenÃ³ en menÃºs (tope anti-mudez; ver ScanForFocus)
local _lastOnMainMenuClock = 0 -- Ãºltimo os.clock() con onMainMenu=true; da ventana de SALIDA de menÃº (ver churn guard)
local _lastOnGalleryClock = 0 -- Ã­dem para la ENCICLOPEDIA; da la ventana de SALIDA de galerÃ­a (ver PollFocus)
local _lastMenuFastHitClock = 0 -- Ãºltimo os.clock() en que el atajo hallÃ³ el foco en un botÃ³n del MENÃš
                                -- PRINCIPAL; con eso se detecta el DESMONTAJE del menÃº (ver ScanForFocus)
local _lastGalleryFastHitClock = 0 -- Ãºltimo os.clock() con el foco hallado en la Enciclopedia; detecta su
                                   -- desmontaje igual que _lastMenuFastHitClock con el menÃº
local _menuFastMissUntil = 0       -- enfriamiento del atajo de botones tras una pasada sin foco (07-27:
                                   -- el watchdog fichÃ³ el cuelgue en `scan-menubtn`). Ver ScanForFocus.
local _menuWalkHoldStreak = 0      -- ticks seguidos que el walk se retuvo en el menÃº; tope anti-mudez
                                   -- (LECCIÃ“N 6). Contador PROPIO: no compartir con menuWalkBlockStreak.
local _menuFastMissStreak = 0      -- fallos SEGUIDOS del atajo; da el enfriamiento progresivo (0.15 a 0.8)
local _prevOnMainMenu = false      -- onMainMenu del tick anterior, para detectar el FLANCO de entrada al menÃº
local _menuFocusLostAt = 0         -- instante en que el botÃ³n cacheado del menÃº perdiÃ³ el foco; da la espera
                                   -- de 50ms antes de ir a buscar (ver ScanForFocus). 0 = no estÃ¡ esperando.
-- Enfriamientos de los atajos POR PANTALLA (07-27 noche). Su gate `GetCachedFirstOf` dice EXISTE, no ESTÃ
-- EN PANTALLA (LECCIÃ“N 14), asÃ­ que sin esto se ejecutan en TODAS las pantallas y cuelgan el bucle.
local _galMissUntil = 0
local _optMissUntil = 0
local _shopMissUntil = 0
local _scanReachedWalk = false -- Â¿el escaneo llegÃ³ a mirar la pantalla entera? Si NO, un resultado vacÃ­o
                               -- significa "no mirÃ©" y NO debe borrar el dedup (ver ScanForFocus/PollFocus)
local _lastFocusTickClock = 0  -- reloj de la vuelta anterior del bucle de foco; mide atascos CORTOS que el
                               -- watchdog no ve (umbral 1.5s). DIAG temporal, ver StartFocusLoop.
local _nextWidgetEnum = 0      -- SIN USO desde que el foco dejÃ³ de enumerar por su cuenta (07-27): ahora
                               -- lee `Trackers.widgetCount` del poll. Se deja declarada por si hiciera
                               -- falta volver a throttlear una enumeraciÃ³n propia.
local _lastGalleryWidget = nil -- panel de la Enciclopedia que tuvo el foco; se le pregunta a Ã‰L antes de
                               -- hacer FindAllOf (819 de 918 atascos venÃ­an de esos FindAllOf). Ver allÃ­.
local _pauseChecksMissUntil = 0 -- enfriamiento de la tanda de pause-checks cuando NO hay ninguna pantalla de
                                -- pausa (27+16 atascos medidos el 07-27, uno de ellos fatal). Ver PollFocus.
local _focusDiedAt = 0          -- hora en que el widget enfocado MURIÃ“; frena el walk medio segundo, el
                                -- tiempo que el poll necesita para armar el freno de churn (07-28)
local _menuLooksAlive = false   -- Â¿el botÃ³n cacheado del menÃº sigue VÃLIDO? Distingue "el menÃº se desmonta"
                                -- (frenar) de "el foco estÃ¡ en algo que el atajo no cubre" (hay que buscar
                                -- con el walk). Confundir las dos dejÃ³ MUDO el menÃº de avisos. Ver allÃ­.
local _lastMenuFastWidget = nil    -- Ãºltimo botÃ³n del menÃº que tuvo el foco; el atajo cacheado del menÃº le
                                   -- pregunta a Ã‰L primero (2 llamadas nativas en vez de ~24). Siempre se
                                   -- revalida con IsValidRef antes de usarlo. Ver ScanForFocus.
local MENU_MAIN_CLASSES = {     -- solo el menÃº principal PELÃ“N (no Ajustes ni Tienda). Ver ScanForFocus.
    ["WBP_OBJ_MainMenu_BTN_Sub1_C"] = true,
    ["WBP_MainMenu_Base_C"] = true,
    ["WBP_OBJ_WishSR_BTN_Sub_C"] = true,
    ["WBP_OBJ_WishSR_BTN_Talk_C"] = true,
}
local _focusSkipStreak = 0   -- consecutive focus ticks skipped for small churn (capped, see ScanForFocus)
local uiChurnUntil = 0       -- shared: UI is rebuilding (big widget-count swing); BOTH loops back off
local _pollWCountResync = false -- tras un churn, la primera cuenta del poll solo SINCRONIZA (ver P:wcount)
                             -- until this os.clock(); armed during story cutscenes so
                             -- ScanForFocus doesn't iterate/deref widgets while the
                             -- scene tears down (that native call crashed the game).

-- Pause the focus scan for `seconds` (extends an existing pause, never shortens).
-- Passed to EpisodeBattle.Init and called while a story cutscene is on screen. Only
-- PollFocus honours this â€” the poll loop (HUD, rewards, dialogs...) keeps running.
local function PauseFocus(seconds)
    local u = os.clock() + seconds
    if u > focusPauseUntil then focusPauseUntil = u end
end

-- Read TXT_GuideMessage from the main menu base widget
local function ReadGuideMessage()
    local base = FindFirstOf("WBP_MainMenu_Base_C")
    if not IsValidRef(base) then return nil end
    if not TryCall(base, "IsVisible") then return nil end

    local txtWidget = TryGetProperty(base, "TXT_GuideMessage")
    if not txtWidget then return nil end
    local getText = TryCall(txtWidget, "GetText")
    if not getText then return nil end
    local str = TryCall(getText, "ToString")
    if str and str ~= "" then
        return str:gsub("\n", " "):gsub("%s+", " ")
    end
    return nil
end

-- Read TEXT_TipsMain from the options tips widget
local function ReadOptionsTip()
    local richBlocks = FindAllOf("RichTextBlock")
    if not richBlocks then return nil end

    for _, rb in ipairs(richBlocks) do
        if GetWidgetName(rb) == "TEXT_TipsMain" then
            local ok, rbPath = pcall(function() return rb:GetFullName() end)
            if ok and rbPath:find("Transient", 1, true) then
                local ok2, text = pcall(function() return rb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    return text:gsub("\n", " "):gsub("%s+", " ")
                end
            end
        end
    end
    return nil
end

-- VALOR de una opciÃ³n de Ajustes (07-22). Estructura VERIFICADA en el volcado: el widget ENFOCADO es
-- el botÃ³n de la opciÃ³n (ej. AssistControlButton, SeButton), clase Option_List_010_Text_C (texto:
-- Auto/SemiautomÃ¡tico/Desactivado/Personalizar) o _011_Gauge_C (volumen: 79/80). Su VALOR vive en el
-- sub-TextBlock `.Title` (ruta `...<NombreBotÃ³n>.WidgetTree.Title`). Se busca el Title cuya ruta
-- Estado del poller de valor de opciÃ³n.
local _optValNextPoll = 0

-- POLLER: anuncia el VALOR de una opciÃ³n de Ajustes cuando cambia con IZQUIERDA/DERECHA (el FOCO no se
-- mueve, asÃ­ que el bucle de foco no lo detecta y quedaba mudo).
-- DÃ“NDE VIVE EL VALOR (CONFIRMADO 07-22 leyendo el volcado con el formato correcto â€”valor ANTES de la
-- rutaâ€” y coherente con lo medido en vivo): en el sub-widget **`caption`** del botÃ³n:
--     caption      = "Auto" / "SemiautomÃ¡tico" / "Desactivado" / "Personalizar"   <- EL VALOR
--     Title        = "Asistencia de batalla"                                       <- el NOMBRE
--     Text_Disable = "No puede cambiarse en esta pantalla."                        <- tooltip
-- SEGURIDAD (tras 4 crashes): este poller corre DETRÃS del gate de churn del poll loop (pantalla ya
-- asentada) y NO se hace NADA en OnWidgetFocused (LECCIÃ“N 18: hurgar propiedades del widget reciÃ©n
-- enfocado truena si aÃºn se estÃ¡ construyendo, p.ej. al entrar a un sub-menÃº). Solo lee el `caption`
-- del widget que YA tiene el foco, con TryGetProperty/TryCall (pcall) e IsValidRef delante.
local function ReadOptionCaption(w)
    local capW = TryGetProperty(w, "caption")
    if not capW then return nil end
    local gt = TryCall(capW, "GetText")
    if not gt then return nil end
    local v = TryCall(gt, "ToString")
    if v == "" then return nil end
    return v
end

-- ENFOQUE FINAL (07-22): NO depender del FOCO. Los intentos anteriores exigÃ­an `lastFocusedWidget`
-- vÃ¡lido, pero el DEMO del menÃº lo borra sin parar (ScanForFocus devuelve nil) => casi nunca coincidÃ­a
-- con el tick del poller y NUNCA llegaba a leer (verificado: 0 lecturas, sin errores, con el foco sÃ­
-- estando en las opciones). AquÃ­ se vigilan los `caption` de TODAS las opciones de la pantalla (~39) y
-- se anuncia el que CAMBIE â€” que es justo lo que pasa al mover IZQUIERDA/DERECHA. Da igual dÃ³nde estÃ©
-- la ref del foco. Al entrar se llena el mapa sin anunciar (prev=nil) y al salir de Ajustes se limpia.
-- SEGURIDAD: corre DETRÃS del gate de churn (pantalla asentada), gateado por el contenedor de Ajustes,
-- con IsValidRef por widget y todo en pcall/TryCall. NADA en OnWidgetFocused (LECCIÃ“N 18).
local OPTION_CLASSES = { "WBP_OBJ_Option_List_010_Text_C", "WBP_OBJ_Option_List_011_Gauge_C" }

-- CAUSA RAÃZ DEL v13 (hallada 07-26): la versiÃ³n anterior guardaba el valor anterior en un mapa
-- indexado POR EL WIDGET (`_optCaptionMap[w]`). En Lua, una tabla indexada por un objeto acierta
-- SOLO si es el MISMO objeto Lua, y UE4SS construye un envoltorio NUEVO en cada `FindAllOf` aunque
-- en pantalla sea el mismo botÃ³n. Resultado: `prev` salÃ­a nil SIEMPRE y la condiciÃ³n "cambiÃ³" no se
-- cumplÃ­a NUNCA => 0 anuncios y 0 errores, exactamente lo observado. (El `==` entre widgets sÃ­
-- funciona porque UE4SS define __eq, pero Lua NO usa __eq para buscar CLAVES de tabla. Por eso el
-- `widget == lastFocusedWidget` de OnWidgetFocused sÃ­ sirve y este mapa no servÃ­a.)
-- EVIDENCIA de que todo lo demÃ¡s estaba bien (volcado F5 del 07-26, pantalla de Accesibilidad):
--   WBP_Option_C existe y es visible; hay 12 instancias de Option_List_010_Text_C
--   (AssistControlButton, AssistComboButton, ...); el valor vive en su sub-widget `caption`; y ese
--   caption pasÃ³ de "Desactivado" a "Auto" a "Personalizar" durante la prueba de IvÃ¡n.
-- ENFOQUE NUEVO: comparar por POSICIÃ“N, no por identidad. Se recolectan los valores de todas las
-- opciones en el ORDEN de escaneo (clase, Ã­ndice) y se compara la tanda con la anterior. Un
-- izquierda/derecha mueve UNA casilla => se anuncia. Si cambian muchas de golpe o cambia el nÃºmero
-- de opciones, la pantalla se rehizo o se reordenÃ³ => callar y solo re-sincronizar (fail-safe: en el
-- peor caso queda mudo como hoy, nunca dice basura). NO aÃ±ade ni una llamada nativa: mismas lecturas
-- que la versiÃ³n anterior. Sigue corriendo DETRÃS del gate de churn y NADA en OnWidgetFocused.
local _optPrevValues = nil
local _optPrevFirstName = nil

local function PollOptionValue()
    if os.clock() < _optValNextPoll then return end
    _optValNextPoll = os.clock() + 0.15
    if not H.GetCachedFirstOf("WBP_Option_C") then
        _optPrevValues = nil  -- fuera de Ajustes: olvidar
        _optPrevFirstName = nil
        return
    end
    local cur, n = {}, 0
    local ws = {}      -- refs de este MISMO tick (nunca se guardan entre ticks: LECCIÃ“N 19)
    local first = nil  -- primera opciÃ³n, para identificar la pantalla
    for c = 1, #OPTION_CLASSES do
        local ok, list = pcall(FindAllOf, OPTION_CLASSES[c])
        if ok and list then
            for i = 1, #list do
                local w = list[i]
                local v = nil
                if IsValidRef(w) then v = ReadOptionCaption(w) end
                n = n + 1
                cur[n] = v or ""
                ws[n] = w
                if not first then first = w end
            end
        end
    end
    -- Identidad de la PANTALLA: nombre de la primera opciÃ³n (ej. "AssistControlButton" en Accesibilidad,
    -- "SeButton" en Sonido). Una sola llamada por tick. Si cambia, es OTRO sub-menÃº y NO se compara nada
    -- (evita anunciar basura al cambiar de pestaÃ±a, que es lo que antes tapaba el umbral de 3).
    local firstName = nil
    if first and IsValidRef(first) then firstName = GetWidgetName(first) end
    local prev, prevName = _optPrevValues, _optPrevFirstName
    _optPrevValues, _optPrevFirstName = cur, firstName
    if not prev or #prev ~= n or prevName ~= firstName then return end

    local changed, firstIdx = 0, nil
    local changedIdx = {}
    for i = 1, n do
        if cur[i] ~= prev[i] then
            changed = changed + 1
            changedIdx[changed] = i
            if not firstIdx then firstIdx = i end
        end
    end
    if changed == 0 then return end

    -- PRESET EN BLOQUE (07-26, medido con IvÃ¡n): "Asistencia de batalla" es una opciÃ³n MAESTRA â€” al
    -- ponerla en Auto o Desactivado, el juego cambia DE GOLPE todas sus sub-asistencias (el log mostrÃ³
    -- "6 cambios" y "8 cambios de golpe"). Con el umbral viejo de 3 eso se ignoraba, y por eso IvÃ¡n oÃ­a
    -- "Personalizar" y "SemiautomÃ¡tico" (que mueven pocas) pero NO "Auto" ni "Desactivado". Ahora sÃ­ se
    -- anuncia; falta elegir CUÃL de las cambiadas.
    -- ELEGIR LA CORRECTA: la que tiene el FOCO. `lastFocusedName` lo mantiene el bucle de foco y en
    -- Ajustes es fiable (IvÃ¡n: al volver a una opciÃ³n, la lee bien). Es una variable ya calculada: cero
    -- llamadas nativas para leerla. Solo se piden nombres de las opciones CAMBIADAS (2 a 8 como mucho, y
    -- solo en este caso raro), no de las 12 en cada tick.
    -- Si ninguna cambiada tiene el foco, se anuncia la PRIMERA cambiada: el orden de FindAllOf coincide
    -- con el orden visual (verificado en el volcado: AssistControlButton, AssistComboButton,
    -- AssistPursuitButton...), asÃ­ que la primera ES la maestra, que es justo la que IvÃ¡n estÃ¡ moviendo.
    local pick = firstIdx
    if changed > 1 and lastFocusedName then
        for k = 1, changed do
            local idx = changedIdx[k]
            local w = ws[idx]
            if w and IsValidRef(w) and GetWidgetName(w) == lastFocusedName then
                pick = idx
                break
            end
        end
    end
    local v = cur[pick]
    if v ~= "" then
        Speak(v, true)
        print("[AE] Option value: " .. v .. (changed > 1 and (" (" .. changed .. " cambios)") or ""))
    end
end

-- Read visible Text_Title TextBlocks (list headers like "Stage", "BGM", etc.)
local function ReadListTitle()
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    for _, tb in ipairs(textBlocks) do
        local tbName = GetWidgetName(tb)
        if tbName == "Text_Title" then
            local visible = TryCall(tb, "IsVisible")
            if visible then
                local ok, text = pcall(function() return tb:GetText():ToString() end)
                if ok and text and text ~= "" then
                    return text:match("^%s*(.-)%s*$")
                end
            end
        end
    end
    return nil
end

local function OnWidgetFocused(widget)
    if not readerEnabled then return end

    local name = GetWidgetName(widget)
    if name == lastFocusedName and widget == lastFocusedWidget then return end

    -- Result-screen buttons (Reintentar/Salir) churn into a NEW instance every tick, so the ref check
    -- above never dedups them; add a name-only dedup â€” the slot name (BTN_1/BTN_2) is stable across the
    -- churn â€” so they don't re-read (IvÃ¡n 07-19: "me lo lee mucho sin mover"). className computed here
    -- (was a few lines down) so the check is cheap; reused below.
    local className = GetClassName(widget)
    if name == lastFocusedName and className == "WBP_OBJ_BS_BTN_Result_1_C" then return end
    -- Left the result buttons (focused a real menu widget) => allow the next result entry to re-announce.
    if className ~= "WBP_OBJ_BS_BTN_Result_1_C" then lastResultCaption = nil end

    lastFocusedName = name
    lastFocusedWidget = widget

    -- CACHEAR la ref del Title de la opciÃ³n de Ajustes AQUÃ (07-22). OnWidgetFocused corre en el FOCO loop
    -- justo cuando el foco cambia a esta opciÃ³n = momento ESTABLE GARANTIZADO (foco fresco, sin churn), el
    -- Ãºnico seguro para el FindAllOf. Antes se intentaba cachear en el poll loop, pero ahÃ­ `lastFocusedWidget`
    -- casi nunca estÃ¡ vÃ¡lido (el demo del menÃº detrÃ¡s de Ajustes churnea y lo borra) => 0 lecturas. Con la ref
    -- ya cacheada, PollOptionValue solo lee GetText de ella (barato/seguro) y detecta el cambio izq/der.
    -- NADA del lector de valores aquÃ­ (07-22). El "paso 1" (un diag con 5 TryGetProperty sobre el widget
    -- reciÃ©n enfocado) TAMBIÃ‰N CRASHEÃ“ al entrar a un sub-menÃº de Ajustes. IvÃ¡n insistiÃ³ en no descartarlo
    -- por "no imprimiÃ³": tenÃ­a razÃ³n â€” el print va DESPUÃ‰S de las 5 lecturas, asÃ­ que si una truena, el
    -- mensaje nunca sale y parece que no corriÃ³. **LECCIÃ“N 18: OnWidgetFocused NO es un momento seguro
    -- cuando el foco ACABA de entrar a una pantalla nueva: el widget reciÃ©n enfocado puede estar todavÃ­a
    -- construyÃ©ndose, y hurgarle propiedades extra (TryGetProperty, incluso de propiedades inexistentes)
    -- truena nativo. Lo que el foco ya hace ahÃ­ estÃ¡ probado; AÃ‘ADIR lecturas propias NO es gratis.**
    -- El dato que faltaba (quÃ© sub-widget tiene el VALOR) se saca del VOLCADO F5, sin tocar el juego.

    -- Check if this widget's class is suppressed
    if WR.SuppressedClasses[className] then
        return
    end

    -- === BATTLE RESULT BUTTONS (Reintentar / Salir) ===
    -- Read ONLY this button's OWN "caption" child (first real Latin text; skip the ã‚/JP and the literal
    -- "Text Block" placeholders), matched by path PREFIX so the neighbouring rank-up panel ("Nivel de
    -- jugador", widget WBP_GRP_BS_PlayerRankUP_C) is never grabbed (IvÃ¡n 07-19). Dedup by the caption
    -- text. If the caption can't be found, DON'T return â€” fall through to the generic handler (safe
    -- degradation: reads something rather than going silent).
    if className == "WBP_OBJ_BS_BTN_Result_1_C" then
        lastScreenContext = nil
        local caption = nil
        local wfull = select(2, pcall(function() return widget:GetFullName() end))
        local wpath = type(wfull) == "string" and wfull:match("%s(.+)$") or nil
        if wpath then
            local blocks = FindAllOf("TextBlock")
            if blocks then
                for _, tb in ipairs(blocks) do
                    if GetWidgetName(tb) == "caption" then
                        local tfull = select(2, pcall(function() return tb:GetFullName() end))
                        local tpath = type(tfull) == "string" and tfull:match("%s(.+)$") or nil
                        if tpath and #tpath >= #wpath and tpath:sub(1, #wpath) == wpath then
                            local txt = select(2, pcall(function() return tb:GetText():ToString() end))
                            if type(txt) == "string" and txt:match("%a")
                               and not txt:find("\227", 1, true) and txt ~= "Text Block" then
                                caption = txt
                                break
                            end
                        end
                    end
                end
            end
        end
        if caption then
            -- Dedup by lastResultCaption (survives the churn-driven focus pauses that clear
            -- lastSpokenLabel), so the same button doesn't re-read across those pauses.
            if caption ~= lastResultCaption then
                lastResultCaption = caption
                lastSpokenLabel = caption
                Speak(caption, true)
            end
            return
        end
        -- caption not found: fall through to generic handler below
    end

    -- === ROOM ID INPUT ===
    if className == "WBP_OBJ_MainMenu_OLB_IDPanel_C" then
        local firstEntry = (lastScreenContext ~= "roomid")
        lastScreenContext = "roomid"

        -- Build digit ref cache on first entry (one FindAllOf for all 9 panels)
        if firstEntry then
            roomIdDigitRefs = {}
            local textBlocks = FindAllOf("TextBlock")
            if textBlocks then
                for _, tb in ipairs(textBlocks) do
                    if GetWidgetName(tb) == "TXT_Num" then
                        local ok, tbPath = pcall(function() return tb:GetFullName() end)
                        if ok then
                            local panelName = tbPath:match("(WBP_OBJ_MainMenu_OLB_IDPanel_%d+)")
                            if panelName then
                                roomIdDigitRefs[panelName] = tb
                            end
                        end
                    end
                end
            end
        end

        local suffix = name:match("_(%d+)$")
        local position = suffix and (tonumber(suffix) + 1) or nil

        -- Read digit from cached ref
        local digit = nil
        local digitRef = roomIdDigitRefs and roomIdDigitRefs[name]
        if digitRef and IsValidRef(digitRef) then
            local ok, text = pcall(function() return digitRef:GetText():ToString() end)
            if ok and text then digit = text end
            lastMatchedLabelWidget = digitRef
        end

        local announcement = ""
        if position and digit then
            announcement = digit .. ", digit " .. position .. " of 9"
        elseif position then
            announcement = "Digit " .. position .. " of 9"
        end

        if announcement ~= "" then
            lastSpokenLabel = announcement
            lastCaptionValue = digit
            Speak(announcement, true)
        end

        if firstEntry then
            SpeakQueued("Up Down to change, Left Right to move")
        end

        return
    end

    -- === FAST PATH: WidgetLabels direct lookup (pause menu, etc.) ===
    -- Skip all expensive FindAllOf scans when we have a direct mapping
    if WR.WidgetLabels[name] then
        lastScreenContext = nil
        local label = WR.WidgetLabels[name]
        if label ~= lastSpokenLabel then
            lastSpokenLabel = label
            Speak(label, true)
        end
        return
    end

    -- === PLAYER MATCH PANEL ===
    if className == "WBP_OBJ_PLMatch_PlayerPanel_C" then
        local firstEntry = (lastScreenContext ~= "plmatch_room")
        lastScreenContext = "plmatch_room"

        -- Derive slot number from widget name suffix (e.g. _00 -> 1, _01 -> 2)
        local slotSuffix = name:match("_(%d+)$")
        local slotNum = slotSuffix and (tonumber(slotSuffix) + 1) or nil

        local widgetInstance = name
        local textBlocks = FindAllOf("TextBlock")
        if textBlocks then
            local fields = {}
            for _, tb in ipairs(textBlocks) do
                local ok, tbPath = pcall(function() return tb:GetFullName() end)
                if ok and tbPath:find(widgetInstance, 1, true) and tbPath:find("Transient", 1, true) then
                    local tbName = GetWidgetName(tb)
                    local ok2, text = pcall(function() return tb:GetText():ToString() end)
                    if ok2 and text and text ~= "" then
                        fields[tbName] = text
                    end
                end
            end

            local parts = {}
            if slotNum then
                table.insert(parts, tostring(slotNum))
            end
            local username = fields.TXT_Username_Own
            if not username or username == "Username" then
                username = fields.TXT_UserName
            end
            if username and username ~= "Username" then
                table.insert(parts, username)
            end
            local status = fields.TXT_Status_00
            if status and status ~= "Text Block" then
                table.insert(parts, status)
            elseif fields.TXT_Enter == "Available" then
                table.insert(parts, "Available")
            end
            if username and username ~= "Username" and fields.TXT_WinCountNum and fields.TXT_GameCountNum then
                table.insert(parts, fields.TXT_WinCountNum .. "/" .. fields.TXT_GameCountNum .. " wins")
            end

            local announcement = table.concat(parts, ", ")
            if announcement ~= "" and announcement ~= lastSpokenLabel then
                lastSpokenLabel = announcement
                Speak(announcement, true)
            end
        end

        -- Announce guide bar on first entry
        if firstEntry then
            SpeakQueued("Player Match Room")
            local richBlocks = FindAllOf("RichTextBlock")
            if richBlocks then
                local guideNames = {
                    "WBP_OBJ_Guide_Btn_Present",
                    "WBP_OBJ_Guide_Btn_0",
                    "WBP_OBJ_Guide_Btn_1",
                    "WBP_OBJ_Guide_Btn_2",
                    "WBP_OBJ_Guide_Btn_3",
                }
                for _, gw in ipairs(guideNames) do
                    for _, rb in ipairs(richBlocks) do
                        local ok, rbPath = pcall(function() return rb:GetFullName() end)
                        if ok and rbPath:find(gw, 1, true)
                           and rbPath:find("Transient", 1, true) then
                            local rbName = GetWidgetName(rb)
                            if rbName == "RTEXT_Help_0" or rbName == "RTEXT_Help_1" then
                                local ok2, text = pcall(function() return rb:GetText():ToString() end)
                                if ok2 and text and text:match("%S")
                                   and not text:find("\227\131\152\227\131\171\227\131\151", 1, true)
                                   and not text:find("\227\131\151\227\131\172\227\130\188", 1, true) then
                                    SpeakQueued(text)
                                end
                            end
                        end
                    end
                end
            end
        end

        return
    end

    -- === SHOP DIALOG (purchase confirmation / purchase complete) ===
    if Shop.IsShopDialog(widget) then
        Shop.OnShopDialogFocused(widget)
        lastSpokenLabel = "shop_dialog"
        return
    end

    -- === SHOP ITEM GRID ===
    if Shop.IsShopItem(widget) then
        local firstEntry = (lastScreenContext ~= "shop")
        lastScreenContext = "shop"
        Shop.OnItemFocused(widget)
        lastSpokenLabel = "shop_item"
        return
    end

    -- === EPISODE BATTLE (character select) ===
    if EpisodeBattle.IsCharaSelect(widget) then
        local firstEntry = (lastScreenContext ~= "episode_battle")
        lastScreenContext = "episode_battle"
        EpisodeBattle.OnCharaSelectFocused(widget)
        lastSpokenLabel = "episode_battle"
        return
    end

    -- === TEAM OVERVIEW (check first â€” cheap name + path match) ===
    if TeamOV.IsTeamSlot(widget) then
        local slot, side = TeamOV.GetSlotInfo(widget)
        local sideCode = side == "Player 2" and "2P" or "1P"
        local teamContext = "team_" .. sideCode
        -- Reset player side when first entering team overview (not when switching 1P/2P panels)
        local isTeamScreen = lastScreenContext == "team_1P" or lastScreenContext == "team_2P"
        if not isTeamScreen then
            Battle.ResetPlayerSide()
        end
        Battle.SetPlayerSide(sideCode)
        local firstEntry = (lastScreenContext ~= teamContext)
        lastScreenContext = teamContext
        local slotNum = slot and (slot + 1) or 0
        print("[AE] Team slot: " .. slotNum .. " (" .. sideCode .. ")")

        -- Read character name + DP via texture ID lookup
        local nameOk, charaName, charaId, dp = pcall(TeamOV.ReadSlotCharaName, slot, sideCode)
        if nameOk and charaName then
            local announcement = charaName
            if dp then announcement = announcement .. ", " .. dp .. " DP" end
            Speak(announcement, true)
            SpeakQueued("Slot " .. slotNum)
            print("[AE] Slot " .. slotNum .. ": " .. charaName .. " (" .. charaId .. ") " .. (dp or "?") .. " DP")
        elseif nameOk and charaId == "empty" then
            Speak("Empty", true)
            SpeakQueued("Slot " .. slotNum)
            print("[AE] Slot " .. slotNum .. ": empty")
        elseif nameOk and charaId then
            Speak("Unknown character", true)
            SpeakQueued("Slot " .. slotNum)
            print("[AE] Slot " .. slotNum .. ": unknown ID " .. tostring(charaId))
        else
            Speak("Slot " .. slotNum, true)
            print("[AE] Slot " .. slotNum .. ": unreadable")
        end

        -- Announce context + guide bar shortcuts on first entry or side switch
        if firstEntry then
            -- Request hold button captions from game thread (async)
            pcall(TeamOV.RequestHoldButtonCaptions)

            local playerLabel = side or "Player 1"
            -- Read total DP for the current side
            local dpOk, totalDP, charCount = pcall(TeamOV.GetTotalDP, sideCode)
            local dpInfo = ""
            if dpOk and totalDP and totalDP > 0 then
                dpInfo = ", Total " .. totalDP .. " DP, " .. charCount .. " characters"
            end
            SpeakQueued(playerLabel .. ", Team Overview" .. dpInfo)

            -- Delay guide bar read slightly to let game thread resolve hold captions
            ExecuteWithDelay(100, function()
                local ok, shortcuts = pcall(TeamOV.ReadGuideBar)
                if ok and shortcuts and #shortcuts > 0 then
                    for _, sc in ipairs(shortcuts) do
                        SpeakQueued(sc)
                    end
                    print("[AE] Guide bar: " .. table.concat(shortcuts, ", "))
                end
            end)
        end

        teamSlotPollFrames = 0
        lastSpokenLabel = "team_slot"
        return
    end

    -- === SKILL LIST / EXPLANATION OF CONTROLS ===
    if SkillList.IsSkillListItem(widget) then
        local firstEntry = (lastScreenContext ~= "skilllist")
        lastScreenContext = "skilllist"

        local category = SkillList.ReadCategory()
        local shouldAnnounce, catChanged = SkillList.ShouldAnnounce(name, category)

        if not shouldAnnounce then return end

        local skillName = SkillList.ReadSkillName(widget)

        -- Category change: announce category first
        if catChanged and not firstEntry then
            Speak(category, true)
        end

        -- Announce skill name + button combo
        if skillName then
            local btnCombo = SkillList.ReadButtonCombo()
            local announcement = skillName
            if btnCombo then announcement = announcement .. ", " .. btnCombo end

            if catChanged and not firstEntry then
                SpeakQueued(announcement)
            else
                Speak(announcement, true)
            end
            lastSpokenLabel = skillName

            -- Queue resource cost, then description
            local costText, descText = SkillList.ReadDetails()
            if costText then SpeakQueued(costText) end
            if descText then SpeakQueued(descText) end

            print("[AE] Skill list: " .. skillName .. " [" .. tostring(btnCombo) .. "]")
        end

        -- Announce title on first entry
        if firstEntry then
            local title = SkillList.ReadTitle()
            if title then
                SpeakQueued(title)
                print("[AE] Skill list opened: " .. title)
            end
        end

        return
    end

    -- === CHARACTER ROSTER ===
    local rosterCtx = Roster.GetContext(widget)
    if rosterCtx == "roster" then
        lastScreenContext = "roster"
        teamSlotPollFrames = 0 -- stop team polling when entering roster
        -- Extract grid suffix from widget name (e.g. "WBP_OBJ_Common_HitButton_10" -> "10")
        local gridSuffix = name:match("HitButton_(%d+)$")
        if gridSuffix then
            local charaName, charaId, dp = Roster.ReadGridCharaName(gridSuffix)
            if charaName and charaName ~= lastCharaName then
                lastCharaName = charaName
                local announcement = charaName
                if dp then announcement = announcement .. ", " .. dp .. " DP" end
                Speak(announcement, true)
                lastSpokenLabel = charaName
                print("[AE] Roster grid " .. gridSuffix .. ": " .. charaName .. " (" .. tostring(charaId) .. ") " .. (dp or "?") .. " DP")
            elseif not charaName and charaId then
                -- Unknown character ID
                Speak("Unknown character", true)
                lastSpokenLabel = "unknown"
                print("[AE] Roster grid " .. gridSuffix .. ": unknown ID " .. tostring(charaId))
            end
        end
        return
    end

    if rosterCtx == "skill" then
        local skillName = Roster.ReadSkillName(widget)
        if skillName then
            local widgetName = GetWidgetName(widget)
            local suffix = tonumber(widgetName:match("SkillHitBTN_(%d+)$"))
            local prefix = ""
            if suffix == 4 then prefix = "Ultimate: "
            elseif suffix == 2 or suffix == 3 then prefix = "Blast: "
            end
            Speak(prefix .. skillName, true)
            lastSpokenLabel = skillName
        else
            Speak("Skill " .. (tonumber(name:match("(%d+)$")) or 0) + 1, true)
        end
        return
    end

    if rosterCtx == "teamlist" then
        local slot = GetWidgetName(widget):match("HitButton_(%d+)$")
        if slot then
            local charaName, charaId, dp = Roster.ReadTeamListCharaName(slot)
            if charaName then
                local announcement = charaName
                if dp then announcement = announcement .. ", " .. dp .. " DP" end
                announcement = "Slot " .. (tonumber(slot) + 1) .. ", " .. announcement
                if announcement ~= lastSpokenLabel then
                    lastSpokenLabel = announcement
                    Speak(announcement, true)
                end
            elseif charaId == "empty" then
                local announcement = "Slot " .. (tonumber(slot) + 1) .. ", Empty"
                if announcement ~= lastSpokenLabel then
                    lastSpokenLabel = announcement
                    Speak(announcement, true)
                end
            end
        end
        return
    end

    -- If widget is inside a dialog, announce dialog text first, then button label
    -- Pattern matches both regular dialogs (WBP_Dialog_000_C_123) and shop dialogs (WBP_Dialog_SH_000_C_123)
    local widgetPath = widget:GetFullName()
    local dialogId = widgetPath:match("(WBP_Dialog_%d+_C_%d+)")
    if dialogId then
        if dialogId ~= lastAnnouncedDialogId then
            lastAnnouncedDialogId = dialogId
            local textBlocks = FindAllOf("TextBlock")
            if textBlocks then
                for _, tb in ipairs(textBlocks) do
                    if tb:GetFullName():find(dialogId, 1, true) then
                        if GetWidgetName(tb) == "TEXT_Header" then
                            local ok, headerText = pcall(function() return tb:GetText():ToString() end)
                            if ok and headerText and headerText ~= "" then
                                Speak(headerText, true)
                            end
                            break
                        end
                    end
                end
            end
            local richBlocks = FindAllOf("RichTextBlock")
            if richBlocks then
                for _, rb in ipairs(richBlocks) do
                    if rb:GetFullName():find(dialogId, 1, true) then
                        if GetWidgetName(rb):find("Text_Main") then
                            local ok, bodyText = pcall(function() return rb:GetText():ToString() end)
                            if ok and bodyText and bodyText ~= "" then
                                SpeakQueued(bodyText:gsub("\n", " "):gsub("%s+", " "))
                            end
                            break
                        end
                    end
                end
            end
            -- Queue button label after a delay so the body text has time to be read
            local dialogWidget = widget
            ExecuteWithDelay(1500, function()
                local label = WR.GetSpokenLabel(dialogWidget)
                lastSpokenLabel = label
                SpeakQueued(label)
            end)
            Trackers.MarkDialogSeen(dialogId)
        else
            local label = WR.GetSpokenLabel(widget)
            lastSpokenLabel = label
            Speak(label, true)
        end
        return
    end

    -- Clear dialog and screen context tracking when in generic handler
    lastAnnouncedDialogId = nil
    lastScreenContext = nil

    -- Check if the list header changed (tab switch via L1/R1)
    local listTitle = ReadListTitle()
    local headerChanged = listTitle and listTitle ~= lastListTitle
    if headerChanged then
        lastListTitle = listTitle
        Speak(listTitle, true)
    end

    -- GetSpokenLabel returns label, matchedWidget, captionValue, captionRef
    lastMatchedLabelWidget = nil
    lastCaptionValue = nil
    lastCaptionRef = nil
    local label, matchedWidget, captionValue, captionRef = WR.GetSpokenLabel(widget)
    lastMatchedLabelWidget = matchedWidget
    lastCaptionValue = captionValue
    lastCaptionRef = captionRef

    if label == lastSpokenLabel and not headerChanged then return end

    lastSpokenLabel = label

    if headerChanged then
        SpeakQueued(label)
    else
        Speak(label, true)
    end

    if lastMatchedLabelWidget and lastCaptionValue then
        local title, _ = WR.ReadWidgetTexts(lastMatchedLabelWidget)
        if title and title == label then
            SpeakQueued(lastCaptionValue)
        end
    end

    local pos, total = WR.GetListPosition(name)
    if pos and total then
        SpeakQueued(pos .. " of " .. total)
    end

    local guide = ReadGuideMessage()
    if guide and guide ~= lastGuideMessage then
        lastGuideMessage = guide
        SpeakQueued(guide)
    end

    if className == "WBP_OBJ_Option_List_011_Gauge_C"
    or className == "WBP_OBJ_Option_List_010_Text_C" then
        local tip = ReadOptionsTip()
        if tip and tip ~= lastOptionsTip then
            lastOptionsTip = tip
            SpeakQueued(tip)
        end
    end
end

-- Are we on a STABLE, navigable menu (the title screen or the main menu)? These screens run a
-- looping background "attract" cutscene (Goku/Whis/Trunks banter) that adds and removes ~1000
-- widgets each swap, so the count swings 600<->1700 repeatedly â€” which the churn guard reads as a
-- full screen REBUILD and pauses navigation for the big-swing window (up to 3s). But the menu
-- itself is stable and navigable the whole time; that long pause just makes it feel unresponsive
-- ("tarda en reaccionar... luego habla bien"). On these screens we cap the churn pause short (the
-- cosmetic free-burst settles in <0.5s) so navigation stays snappy. Real teardowns (leaving the
-- menu into a mode) are covered by transitionCooldownUntil, not this. IsVisible on these top-level
-- roots is reliable (confirmed via diag). Cheap: GetCachedFirstOf caches the lookup.
-- Are we in a context that genuinely TEARS DOWN widgets/pawns, where reading mid-churn has crashed?
-- BLACKLIST, not whitelist. Only three contexts have ever crashed: an active battle (P:hud), the
-- story map (P:storymap), and a story cutscene (skip-prompt on screen -> F:pollfocus). ONLY these
-- get the long churn window. EVERYTHING else â€” title, menus, load screens, the looping attract-
-- cutscene banter, the episode character-select, and crucially the transition GAPS BETWEEN menus â€”
-- is navigable/idle menu territory that has never crashed, so it gets a SHORT window and stays
-- responsive. The earlier whitelist ("is a known menu root visible?") misfired in exactly those
-- gaps: entering Episode Battle you pass through a limbo where neither title nor main-menu root is
-- visible, so it fell through to the 3s window â€” the "gran tirÃ³n". A blacklist has no such gap.
local function InDangerZone()
    if EpisodeBattle.IsStoryMapActive and EpisodeBattle.IsStoryMapActive() then return true end
    if Battle.WasBattleActive and Battle.WasBattleActive() then return true end
    -- Ventana de teardown post-pelea: la salida de batalla al menÃº sigue churneando ~segundos
    -- despuÃ©s de que WasBattleActive se apaga; sin esto el foco se colgaba en ese hueco (07-20).
    if Battle.InPostBattleTeardown and Battle.InPostBattleTeardown() then return true end
    local sk = H.GetCachedFirstOf("WBP_GRP_AI_EventSkip_C")
    if sk and TryCall(sk, "IsVisible") then return true end
    return false
end

-- === FOCUS SCAN ===
-- Single FindAllOf("UserWidget"), then HasKeyboardFocus per widget.
-- IsValidRef per widget is REQUIRED: a widget mid-teardown can make
-- HasKeyboardFocus() HANG natively (pcall does NOT catch a hang), which wedges
-- the whole mod. This froze the reader in a story cutscene (post-Raditz, Gohan
-- training with Piccolo) where no transition cooldown was armed. The empty-scan
-- throttle below keeps this off the 60Hz path on focusless screens (cutscenes,
-- fades), so the extra IsValid() call per widget is cheap in practice.
local function ScanForFocus()
    -- === "NO MIRÃ‰" NO ES LO MISMO QUE "NO HAY FOCO" (07-27 noche) ===
    -- IvÃ¡n: "al quedarme parado repite una y otra vez donde estoy". CAUSA, verificada en el cÃ³digo de
    -- PollFocus (no supuesta): cuando esta funciÃ³n devuelve nil, PollFocus BORRA `lastFocusedName` y
    -- `lastFocusedWidget`, que son el dedup. Al volver a encontrar el MISMO botÃ³n lo toma por nuevo y lo
    -- vuelve a leer. Cada freno que corta el escaneo con `return nil` provocaba, por tanto, una relectura.
    -- Y esta funciÃ³n estÃ¡ llena de frenos legÃ­timos (settle, enfriamientos, espera del menÃº, bloqueo del
    -- walk, small-churn guard): todos ellos significan "NO HE MIRADO", no "no hay nada enfocado".
    -- Se distinguen con esta bandera: TODOS los frenos retornan antes de llegar al walk, asÃ­ que si la
    -- funciÃ³n acaba sin haber llegado allÃ­, es que no mirÃ³ y PollFocus debe DEJAR EL DEDUP EN PAZ.
    _scanReachedWalk = false
    _focusStage = "scan-findall"
    -- MIGAJAS FINAS SOLO EN LA ENCICLOPEDIA (07-27). El crash al salir de ahÃ­ dejÃ³ `F:pf-fast`, que
    -- significa "los pause-checks pasaron limpios y muriÃ³ despuÃ©s" â€” pero ese "despuÃ©s" abarca esta
    -- funciÃ³n entera. Hay DOS sospechosos muy distintos y con soluciones opuestas:
    --   (1) este `FindAllOf("UserWidget")`, que enumera ~1762 objetos tocando cada uno. Es EXACTAMENTE la
    --       operaciÃ³n que acaba de matar el juego en `P:wcount` durante un rebuild, solo que aquÃ­ corre a
    --       16ms y en el primer tick de la salida el freno de churn todavÃ­a no estÃ¡ armado.
    --   (2) alguno de los escaneos POSTERIORES (el atajo de la galerÃ­a tocando sus propios botones en
    --       teardown, u otro fast-path, o el walk).
    -- Distinguirlos vale una escritura de archivo por tick, y SOLO dentro de la Enciclopedia (fuera de
    -- ella, cero coste): si el prÃ³ximo crash deja `F:sf-findall` es (1); si deja `F:sf-paths` es (2).
    -- NO se toca nada del comportamiento todavÃ­a: la soluciÃ³n de (1) obligarÃ­a a mover la enumeraciÃ³n
    -- despuÃ©s de los atajos, y de ella depende el churn guard, que es la pieza central anti-crash. Eso
    -- NO se hace a ciegas.
    -- === EL CULPABLE DE LA LENTITUD, MEDIDO (07-27 noche) ===
    -- El DIAG `focus gap` cazÃ³ 296 atascos en 3.5 minutos y el reparto no deja lugar a dudas:
    -- **200 en `scan-findall`** (o sea AQUÃ), 31 en pf-fastpath, 30 en scan-option, 13 en scan-full,
    -- 12 en scan-menubtn, 9 en pf-fp-haskbf. Dos tercios de todo el tiempo perdido estÃ¡n en esta Ãºnica
    -- lÃ­nea. Sumados, los atascos se comÃ­an prÃ¡cticamente TODO el tiempo de la sesiÃ³n: el bucle apenas
    -- hacÃ­a otra cosa. Y encaja con lo ya sabido: esta misma operaciÃ³n (enumerar ~1762 objetos tocando
    -- cada uno) es la que matÃ³ el juego DOS veces en `P:wcount`.
    -- LO ABSURDO DE HACERLO CADA TICK: se enumeraba la pantalla entera 62 veces por segundo aunque el
    -- resultado no se fuera a usar. En el menÃº, la Enciclopedia, Ajustes, la Tienda o la lista de
    -- comandos resuelve un ATAJO y la lista nunca llega a recorrerse: trabajo tirado a la basura, 62
    -- veces por segundo, y encima es el trabajo mÃ¡s peligroso que hace el mod.
    -- AHORA: se enumera cada 100ms (para el conteo del churn guard) y, aparte, siempre que de verdad se
    -- vaya a caminar la lista. En pantallas con atajo eso baja de 62 enumeraciones por segundo a 10.
    -- QUÃ‰ SE PIERDE Y POR QUÃ‰ ES ASUMIBLE: el churn guard del foco pasa a evaluarse 10 veces por segundo
    -- en vez de 62, asÃ­ que una reconstrucciÃ³n puede detectarse hasta 100ms mÃ¡s tarde. El bucle de POLL
    -- ya muestrea exactamente a ese mismo ritmo, o sea que no bajamos por debajo de lo que el mod ya
    -- consideraba suficiente en el otro bucle. Y a cambio se quitan dos tercios de los atascos.
    -- === SE ELIMINA LA ENUMERACIÃ“N PERIÃ“DICA DE ESTE BUCLE (07-27 noche). ERA TRABAJO DUPLICADO ===
    -- Con los dos arreglos anteriores ya validados (`scan-gallery` 819 -> 7, `scan-option` 200 -> 2), el
    -- reparto dejÃ³ un dominador claro: **288 de 515 atascos en `scan-findall`**, sobre todo en pantallas
    -- de batalla y selecciÃ³n, que tienen ~2070 widgets (el doble que un menÃº).
    -- Y al mirarlo con calma resulta que era REDUNDANTE: el bucle de POLL ya hace exactamente el mismo
    -- `FindAllOf("UserWidget")` cada 100ms para su propio churn guard (`P:wcount`), y este bucle lo hacÃ­a
    -- OTRA VEZ, tambiÃ©n cada 100ms desde el throttle de antes. Dos recorridos completos de la lista de
    -- objetos, cada dÃ©cima, para calcular el mismo nÃºmero.
    -- Ahora este bucle LEE el conteo que publica el poll en vez de recalcularlo. **No se pierde nada de
    -- detecciÃ³n**: ambos iban ya al mismo ritmo de 100ms, asÃ­ que la latencia para detectar una
    -- reconstrucciÃ³n es idÃ©ntica; simplemente deja de pagarse dos veces.
    -- La enumeraciÃ³n de verdad solo se hace donde hace falta de verdad: justo antes del walk.
    if Trackers.onGallery then Crumb("F:sf-findall") end
    local allWidgets = nil
    if Trackers.onGallery then Crumb("F:sf-paths") end

    -- UI-rebuild churn guard. Returning to the story map / entering an episode battle
    -- rebuilds a whole widget tree WITHIN THE SAME WORLD, so CheckWorldTransition never
    -- sees it (no "Map changed") and no cooldown is armed â€” pollers then walk widgets
    -- mid-teardown, calling IsValid/HasKeyboardFocus/IsVisible on freed objects, and
    -- CRASH the game natively (crumbs F:pollfocus AND P:room). Detecting the rebuild via
    -- the widget COUNT is safe: it reads only the array length, never touches a churning
    -- widget. A big swing => a screen is being built; arm the SHARED uiChurnUntil so BOTH
    -- the focus loop AND the poll loop back off (~0.4s, self-extends while it churns).
    -- Normal menu moves change the count by only a few, so everyday navigation is
    -- unaffected. This runs on the 16ms focus loop, so the poll loop (100ms) sees the
    -- churn flag armed before its next run.
    -- En los ticks en que NO se enumerÃ³ no hay dato nuevo: se deja prev == count para que el swing salga
    -- 0 y ningÃºn guardia se arme con informaciÃ³n inventada. El siguiente muestreo (a los 100ms) evaluarÃ¡
    -- el salto real acumulado.
    -- El conteo viene del bucle de POLL (`Trackers.widgetCount`), que ya lo calcula cada 100ms. Mientras
    -- no cambie, `prev == count` y ningÃºn guardia se arma con informaciÃ³n repetida.
    local count = Trackers.widgetCount or lastWidgetCount
    local prev = lastWidgetCount
    lastWidgetCount = count

    -- RESULT SCREEN fast-path (game-over/victory: WBP_GRP_BS_Result_02_DP_C). This screen keeps the
    -- battle scene loaded and CHURNING behind it, so the churn guards below would return nil and the
    -- retry/quit menu went unread (IvÃ¡n 07-19). Its buttons (WBP_OBJ_BS_BTN_Result_1_C: BTN_1
    -- "Reintentar", BTN_2 "Salir") are FEW and stable, so â€” exactly like the char-select HitButton
    -- fast-path â€” scan ONLY those, BEFORE the churn guards, and NEVER fall through to the ~2170-widget
    -- full walk (which would crash on the churning scene). Touches only the stable result buttons.
    if H.GetCachedFirstOf("WBP_GRP_BS_Result_02_DP_C") then
        local rok, rbtns = pcall(FindAllOf, "WBP_OBJ_BS_BTN_Result_1_C")
        if rok and rbtns then
            for i = 1, #rbtns do
                local w = rbtns[i]
                if IsValidRef(w) then
                    local fok, focused = pcall(function()
                        if not IsValidRef(w) then return false end
                        return w.HasKeyboardFocus and w:HasKeyboardFocus()
                    end)
                    if fok and focused then return w end
                end
            end
        end
        return nil  -- result screen present: never fall through to the churning full walk
    end

    -- TITLE SCREEN fast-path (pantalla de arranque "Iniciar/Opciones/Salir": WBP_Title_C). 07-21:
    -- 3 crashes AL ARRANCAR hoy (crumbs F:pollfocus/F:worldtrans). VOLCADO `dump_crash_1017.txt`:
    -- el crash cayÃ³ con el foco en StartButton (clase WBP_Title_Button_C) en la pantalla de tÃ­tulo.
    -- CAUSA: al arrancar el juego ya tiene ~1615 UserWidgets creados DE FONDO (a medio construir
    -- mientras cargan assets), aunque solo 8 sean visibles; el tÃ­tulo NO tenÃ­a atajo => caÃ­a al WALK
    -- COMPLETO de esos 1615 y HasKeyboardFocus sobre uno a medio crear TRUENA. El tÃ­tulo solo tiene
    -- 3 botones ESTABLES (Start/Option/Quit). Mismo patrÃ³n probado que result/char-select. SEÃ‘AL
    -- VERIFICADA: WBP_Title_C sale en 11 entradas del volcado y NUNCA coexiste con el menÃº principal
    -- ni con HitButton (exclusiva del arranque). return-nil = NUNCA caer al walk sobre la carga.
    if H.GetCachedFirstOf("WBP_Title_C") then
        local tok, tbtns = pcall(FindAllOf, "WBP_Title_Button_C")
        if tok and tbtns then
            for i = 1, #tbtns do
                local w = tbtns[i]
                if IsValidRef(w) then
                    local fok, focused = pcall(function()
                        if not IsValidRef(w) then return false end
                        return w.HasKeyboardFocus and w:HasKeyboardFocus()
                    end)
                    if fok and focused then return w end
                end
            end
        end
        return nil  -- tÃ­tulo presente: nunca caer al walk sobre los ~1615 widgets de la carga
    end
    -- Measured: normal menu navigation swings the UserWidget count by ~50-145; a full scene/
    -- map rebuild swings ~950-1075. The PARTIAL "Cambiar Ã¡rea" map reload swings LESS than 400
    -- (no guard fired during it) yet still churns TextBlocks internally, so PollStoryMap's scan
    -- crashed mid-reload (crumb P:storymap). Lowered the arm threshold 400 -> 200 to catch these
    -- partial reloads while keeping a safe margin above menu navigation (145). Swings of 100-199
    -- are logged (not armed) so the exact "Cambiar Ã¡rea" magnitude can be confirmed and the
    -- cutoff tuned if it turns out to sit below 200.
    local swing = math.abs(count - prev)
    -- Immediate arm for a single BIG swing (full screen/scene rebuild, ~950-1075).
    if prev > 0 and swing >= 200 then
        -- Big rebuilds keep churning UObjects for ~1s after the count stabilizes, so a flat
        -- 0.4s window expires mid-teardown and the next poller walks a half-destroyed widget
        -- and crashes. Give big swings a longer settle. During a reload there is nothing to
        -- read, so the pause loses no data.
        -- â‰¥800 = a full battle/scene REBUILD (chained story battles, transformations); these
        -- churn pawns for >1.5s, and PollHUD crashed (crumb P:hud) in the GAP between two such
        -- guards firing (1287->2174 then 2174->1266 during the Ginyu-force sequence). 2.5s closes
        -- that gap. Nothing to read mid-rebuild, so the longer pause loses no data.
        -- Long window ONLY in a real teardown context (battle / story map / cutscene). Everywhere
        -- else â€” menus, load screens, attract-cutscene banter, the gaps between screens â€” a short
        -- window keeps navigation responsive (see InDangerZone; fixes the Episode-Battle entry jank).
        -- MENÃš y SUB-MENÃšS (07-20): la premisa "menus never crash" resultÃ³ FALSA. Salir de la TIENDA
        -- al menÃº principal tronÃ³ (crumb F:pollfocus, livelog termina en la tienda): el juego destruye
        -- los botones del sub-menÃº y RECONSTRUYE el menÃº, churneando varios segundos, pero la ventana
        -- corta de 0.3s soltaba el foco a media destrucciÃ³n y escaneaba botones muertos. Se le da la
        -- ventana LARGA usando la banderita NO-NATIVA Trackers.onMainMenu (la setea PollFocus; cero
        -- llamadas nuevas al motor aquÃ­). Flat 2.0 a propÃ³sito: NO 3.0 aunque el swing sea grande,
        -- porque el demo del menÃº reconstruye ~950-1075 y 3s alargarÃ­a la mudez sin necesidad.
        -- VENTANA DE SALIDA DE MENÃš (07-21): DOS crashes idÃ©nticos (10:02 y 10:30) al salir del menÃº
        -- principal hacia la Enciclopedia. El menÃº tarda ~2s en DESMONTARSE, pero en el instante en que
        -- ModeMenu desaparece, onMainMenu cae a false => la transiciÃ³n recibÃ­a solo 0.3s => el foco se
        -- soltaba a media destrucciÃ³n => F:pollfocus. math.max NO bastaba: la ventana larga del demo ya
        -- habÃ­a expirado antes del desmontaje. FIX: durante 2.5s DESPUÃ‰S de dejar el menÃº, las
        -- transiciones siguen recibiendo ventana LARGA (2.0s). Ventana temporizada FAIL-SAFE, mismo
        -- patrÃ³n que InPostBattleTeardown. Cubre TODAS las salidas del menÃº (Enciclopedia, Tienda,
        -- Ajustes, char-select). Trade: la sub-pantalla lee ~2s mÃ¡s tarde mientras carga (no hay
        -- pÃ©rdida de datos: nada que leer en el teardown). El demo del menÃº NO reactiva esto tras salir
        -- (onMainMenu ya es false y no se re-marca), asÃ­ que expira limpio a los 2.5s.
        local justLeftMenu = (os.clock() - _lastOnMainMenuClock) < 2.5
        local window
        if InDangerZone() then window = (swing >= 800) and 3.0 or 2.0
        elseif Trackers.onMainMenu or justLeftMenu then window = 2.0
        else window = 0.3 end -- short: select/transitions; keep navigation snappy
        print("[AE] UI churn guard: " .. prev .. " -> " .. count .. " (" .. window .. "s)")
        -- NUNCA ACORTAR un freno vigente (07-21). Crash F:pollfocus al salir del menÃº principal a la
        -- Enciclopedia: se armÃ³ 2.0s (onMainMenu=true) y al tick siguiente, cuando el menÃº YA se estaba
        -- yendo (onMainMenu=false), un swing menor armÃ³ 0.3s que PISÃ“ la ventana de 2.0s => el foco se
        -- soltÃ³ a media destrucciÃ³n y escaneÃ³ widgets muertos. math.max conserva la protecciÃ³n mÃ¡s
        -- larga vigente. SEGURO en el menÃº: ahÃ­ todas las ventanas ya son 2.0s (misma rama onMainMenu),
        -- asÃ­ que entre ellas math.max no cambia nada; el menÃº sigue leyendo en los huecos donde el
        -- conteo se calma y la ventana EXPIRA sola (math.max no impide expirar, solo impide acortar).
        -- Fail-safe: el tope real es 3.0s, nunca enmudece permanente.
        uiChurnUntil = math.max(uiChurnUntil, os.clock() + window)
        churnStreak = 0
        return nil
    end
    -- Sustained arm for a GRADUAL load: an episode/map load ramped the count by ~130/tick for
    -- 5+ ticks (771->907->1036->1166->1296->1426) â€” no single swing hit 200, yet a poller
    -- crashed mid-ramp (crumb P:sysmsg). Count consecutive ticks of real movement (>=100); 3 in
    -- a row means a load is in progress, not a one-off menu move (which settles in a tick), so
    -- back off. Single-tick menu swings never accumulate to 3, so menus stay responsive.
    if prev > 0 and swing >= 100 then
        churnStreak = churnStreak + 1
        if churnStreak >= 3 then
            print("[AE] UI churn guard (sustained): " .. prev .. " -> " .. count
                .. " streak=" .. churnStreak)
            uiChurnUntil = math.max(uiChurnUntil, os.clock() + 0.6)  -- no acortar (ver churn guard grande)
            return nil
        end
    else
        churnStreak = 0
    end

    -- SMALL-CHURN GUARD. Even a swing below the 100/200 thresholds means widgets are being added or
    -- FREED this very tick, and walking HasKeyboardFocus over the array can touch one mid-free ->
    -- native crash (crumb F:pollfocus, seen navigating the team/roster select: per-move preview churn
    -- stayed under the thresholds so no window ever armed, and the scan walked a freeing widget). So
    -- skip the walk on ANY real single-tick movement and only scan a SETTLED tree. CAPPED at 6
    -- consecutive skips (~96ms) so a screen that legitimately churns every tick (animated preview)
    -- still gets read â€” worst case a slightly delayed read, never a permanently silent menu. A
    -- static menu (focus moves but the widget count is stable) has swing ~0, so navigation there is
    -- unaffected.
    if prev > 0 and swing >= 15 and _focusSkipStreak < 6 then
        _focusSkipStreak = _focusSkipStreak + 1
        return nil
    end
    _focusSkipStreak = 0

    -- CHARACTER-SELECT FAST PATH. On the roster / team select the focused element is ALWAYS a
    -- WBP_OBJ_Common_HitButton_C (a character cell or a team slot). Those number ~40-50; the full
    -- walk below scans ~2000 UserWidgets. The roster's HitButtons FLICKER (freed/created as you
    -- navigate), so calling HasKeyboardFocus across all ~2000 widgets there is THE recurring
    -- F:pollfocus crash on this core, everyday screen (picking fighters for tournaments / local
    -- battles). Scanning ONLY the HitButtons cuts the native calls ~50x -> far fewer crashes, and
    -- also AVOIDS the ~1960 non-cell widgets (churning portraits/effects) entirely. If no HitButton
    -- has focus (focus is on a rule/start button), we fall through to the full walk. FAIL-SAFE: an
    -- empty/failed narrow scan just falls through, so it can never break focus reading. Gated to the
    -- char-select (WBP_GRP_BS_CharaList_DP_C present) so it costs nothing on other screens.
    if H.GetCachedFirstOf("WBP_GRP_BS_CharaList_DP_C") then
        local hok, hits = pcall(FindAllOf, "WBP_OBJ_Common_HitButton_C")
        if hok and hits then
            _focusStage = "scan-hit"; _focusScanTotal = #hits
            for i = 1, #hits do
                _focusScanIdx = i
                local w = hits[i]
                if IsValidRef(w) then
                    local fok, focused = pcall(function()
                        if not IsValidRef(w) then return false end
                        return w.HasKeyboardFocus and w:HasKeyboardFocus()
                    end)
                    if fok and focused then
                        return w
                    end
                end
            end
        end
    end

    -- ENCICLOPEDIA fast-path (07-27). MISMO patrÃ³n ya probado tres veces (char-select, resultado, lista
    -- de comandos): en esta pantalla los elementos que TOMAN FOCO son POQUÃSIMOS, asÃ­ que se escanean
    -- solo ellos en vez de caminar los ~1145 widgets de la escena.
    -- MEDIDO en el volcado `dump_0726_ajustes_ency.txt` (no supuesto): de todas las clases que tuvieron
    -- el foco en esa sesiÃ³n, la MÃS frecuente fue `WBP_OBJ_Gallery_BTN_Menu_C` (15 entradas, 3 instancias
    -- por entrada) y tambiÃ©n toma foco `WBP_OBJ_Gallery_CharacterList_Panel_C` (10 instancias). Ninguna
    -- de las dos estÃ¡ en `menuFastClasses` â€” y NO deben aÃ±adirse ahÃ­ (LECCIÃ“N 15: esa lista corre en
    -- TODAS las pantallas y crecerla disparÃ³ las muertes de foco). AquÃ­ van gateadas por la galerÃ­a, asÃ­
    -- que fuera de ella cuestan cero.
    -- POR QUÃ‰ IMPORTA: 13 widgets contra 1145 es ~88x menos llamadas nativas en la pantalla donde mÃ¡s
    -- crashes hemos tenido, y ademÃ¡s evita que la Enciclopedia dependa del walk â€” que es justo lo que el
    -- bloqueo anti-crash de mÃ¡s abajo va a frenar durante la entrada.
    -- FAIL-SAFE: si ninguno tiene el foco (submenÃºs de mÃºsica/escenarios, etc.) cae al walk de siempre,
    -- asÃ­ que no puede enmudecer nada.
    -- OJO CON LA CONDICIÃ“N: el enfriamiento va EN EL `if` EXTERIOR a propÃ³sito. Si estuviera dentro con un
    -- `return nil`, un atajo enfriado ABORTARÃA el escaneo entero y el resto de atajos (incluido el del
    -- menÃº) no llegarÃ­a a correr â€” eso fue exactamente el fallo del 07-27 noche que dejÃ³ el menÃº hasta 1.5s
    -- sin leer y repitiendo la opciÃ³n al recuperarse. Estando en el `if`, un atajo enfriado simplemente SE
    -- SALTA y el flujo continÃºa al siguiente. NO volver a meterlo dentro.
    -- LOS ENFRIAMIENTOS SE LIMPIAN DURANTE EL CHURN (07-27), aquÃ­ y no dentro de cada atajo: un churn
    -- significa cambio de pantalla, asÃ­ que todos los atajos merecen volver a probar cuando se asiente.
    -- ENFRIAMIENTO SUBIDO DE 1.5s A 30s (07-27 noche, con dato). El DIAG del menÃº principal enseÃ±Ã³ el
    -- patrÃ³n en bucle: un atasco de `scan-option` de 0.5 a 1.34s CADA segundo y medio â€” 39 de los 157
    -- atascos de la sesiÃ³n. Es el atajo de Ajustes ejecutÃ¡ndose EN EL MENÃš (su gate por presencia se
    -- cumple ahÃ­, LECCIÃ“N 14) y pagando CUATRO recorridos completos de la lista de objetos por intento.
    -- Con 1.5s ese peaje se cobraba 40 veces por minuto para comprobar algo que casi nunca es cierto.
    -- POR QUÃ‰ 30s NO RETRASA NADA: el reset de aquÃ­ abajo dispara con CUALQUIER churn, y entrar a Ajustes,
    -- la Tienda o la Enciclopedia mueve cientos de widgets, asÃ­ que siempre hay churn y el atajo se
    -- reactiva al instante. Los 30s solo se agotan si alguna vez se entrara a una de esas pantallas SIN
    -- churn: caso improbable y, aun asÃ­, fail-safe (se leerÃ­a por el walk, mÃ¡s lento pero se leerÃ­a).
    if os.clock() < uiChurnUntil then
        _galMissUntil, _optMissUntil, _shopMissUntil = 0, 0, 0
    end

    -- === EL SETTLE TAMBIÃ‰N VA EN EL `if` EXTERIOR (07-27 noche). MEDIDO, no supuesto ===
    -- El DIAG de retraso dio 11 medidas entre 0.59s y 1.00s **todas con `fallos=0`**, o sea el recorrido
    -- del menÃº acertaba A LA PRIMERA y aun asÃ­ se perdÃ­an ~0.6s. Ese nÃºmero es exactamente el settle
    -- post-churn de estos atajos. La causa: el settle estaba DENTRO del bloque con un `return nil`, y como
    -- el gate por presencia se cumple en TODAS las pantallas (LECCIÃ“N 14), el settle de una pantalla en la
    -- que NI SIQUIERA ESTAMOS abortaba el escaneo del menÃº durante 0.6s despuÃ©s de cada churn.
    -- Puesto en el `if` exterior hace lo que su propÃ³sito pide â€”no tocar los botones de una pantalla que
    -- estÃ¡ naciendoâ€” sin secuestrar el escaneo de las demÃ¡s. El walk sigue protegido por el freno de churn
    -- del bucle y por el bloqueo del walk del menÃº.
    if H.GetCachedFirstOf("WBP_GRP_Gallery_PictureBook_C") and os.clock() >= _galMissUntil
       and os.clock() >= uiChurnUntil + 0.6 then
        -- SETTLE POST-CHURN (07-27 tarde). EVIDENCIA: el crash de las 14:27:20 dejÃ³ la migaja `F:sf-gal`,
        -- o sea AQUÃ DENTRO, y el livelog enseÃ±a por quÃ©: `UI churn guard: 1756 -> 1148 (2.0s)` a las
        -- 14:27:18 (la Enciclopedia naciendo) y `churn=true` en TODAS las lÃ­neas hasta el segundo del
        -- crash. La ventana de 2.0s expirÃ³ justo cuando la pantalla AÃšN se estaba construyendo, el bucle
        -- de foco se soltÃ³ de golpe y este atajo fue derecho a preguntarle `HasKeyboardFocus` a unos
        -- botones a medio nacer. Es el riesgo que ya se anotÃ³ al aÃ±adir este atajo (LECCIÃ“N 15 aplicada a
        -- un atajo propio): tocar los botones de una pantalla que estÃ¡ naciendo o muriendo.
        -- El freno de churn no basta porque expira por TIEMPO, no porque la pantalla estÃ© lista. Con
        -- medio segundo mÃ¡s de margen tras el churn, el Ã¡rbol ya estÃ¡ montado.
        -- `return nil` (NO seguir al walk): si aquÃ­ no es seguro mirar 13 botones, muchÃ­simo menos lo es
        -- caminar los ~1145 de la escena. Fail-safe y temporizado: 0.6s despuÃ©s se lee normal.
        -- === MI ERROR DE DISEÃ‘O, MEDIDO (07-27 noche) ===
        -- El DIAG dio **819 de 918 atascos AQUÃ**, el 89%, tras un rato largo en la Enciclopedia. Y la
        -- causa es un fallo de razonamiento mÃ­o al crear este atajo: yo contÃ© WIDGETS TOCADOS (13 en vez
        -- de 1145) y di por hecho que eso era el coste. **`FindAllOf(clase)` NO cuesta en proporciÃ³n a los
        -- resultados: recorre la lista COMPLETA de objetos del juego para filtrarlos.** AsÃ­ que este
        -- atajo hacÃ­a DOS recorridos completos por tick (uno por clase) â€” o sea, en la parte de bÃºsqueda
        -- podÃ­a costar MÃS que el walk, que hace UNO solo. AhorrÃ© en lo barato y paguÃ© el doble en lo caro.
        -- FIX, el mismo patrÃ³n que ya funcionÃ³ en el menÃº: preguntarle primero al panel que YA tenÃ­a el
        -- foco. En la Enciclopedia eso acierta casi siempre â€” al pasar personajes con RB/LB el foco de
        -- teclado NI SIQUIERA SE MUEVE (por eso existe el poller de gallery.lua) â€” asÃ­ que la inmensa
        -- mayorÃ­a de los ticks se resuelven con DOS llamadas y CERO recorridos de la lista de objetos.
        if _lastGalleryWidget then
            if not IsValidRef(_lastGalleryWidget) then
                _lastGalleryWidget = nil  -- muriÃ³: se cae al escaneo normal de abajo
            else
                local gcok, gcf = pcall(function()
                    if not IsValidRef(_lastGalleryWidget) then return false end
                    return _lastGalleryWidget.HasKeyboardFocus and _lastGalleryWidget:HasKeyboardFocus()
                end)
                if gcok and gcf then
                    _lastGalleryFastHitClock = os.clock()
                    _galMissUntil = 0
                    return _lastGalleryWidget
                end
            end
        end
        _focusStage = "scan-gallery"
        Crumb("F:sf-gal")  -- migaja fina: solo corre dentro de la Enciclopedia (ver la nota de arriba)
        local galClasses = { "WBP_OBJ_Gallery_BTN_Menu_C", "WBP_OBJ_Gallery_CharacterList_Panel_C" }
        for _, cls in ipairs(galClasses) do
            local gok, items = pcall(FindAllOf, cls)
            if gok and items then
                for i = 1, #items do
                    local w = items[i]
                    if IsValidRef(w) then
                        local fok, focused = pcall(function()
                            if not IsValidRef(w) then return false end
                            return w.HasKeyboardFocus and w:HasKeyboardFocus()
                        end)
                        if fok and focused then
                            _lastGalleryFastHitClock = os.clock()
                            _galMissUntil = 0
                            _lastGalleryWidget = w  -- para el atajo cacheado de arriba
                            return w
                        end
                    end
                end
            end
        end
        -- SEÃ‘AL DE SALIDA POR PÃ‰RDIDA DE FOCO (07-27), mismo patrÃ³n que ya funcionÃ³ en el menÃº principal:
        -- dentro de la Enciclopedia el foco SIEMPRE estÃ¡ en uno de estos elementos (el volcado lo
        -- confirma: `Gallery_BTN_Menu` fue la clase mÃ¡s enfocada de la sesiÃ³n). Que de golpe NINGUNO lo
        -- tenga es la firma de que la pantalla se estÃ¡ desmontando porque pulsaste B. En ese instante,
        -- seguir bajando a los demÃ¡s escaneos y al walk de ~1145 widgets es puro riesgo y cero beneficio:
        -- no hay nada que leer en una pantalla que se estÃ¡ muriendo. Se corta aquÃ­.
        -- FAIL-SAFE: ventana temporizada (LECCIÃ“N 11). Si de verdad no hay foco por otro motivo, a los
        -- 0.8s se suelta y el escaneo normal vuelve a correr; no puede enmudecer nada.
        if (os.clock() - _lastGalleryFastHitClock) < 0.8 then return nil end
        _galMissUntil = os.clock() + 30  -- nadie con foco => no estamos en la Enciclopedia; no insistir
    end

    -- AJUSTES fast-path (07-27). IvÃ¡n reportÃ³ que navegar Ajustes "se siente un poco lento". La causa de
    -- fondo NO era solo el bloqueo del walk (ya acortado a 0.8s): es que las OPCIONES de Ajustes dependen
    -- del walk completo, ~1148 widgets a cada tick de 16ms, porque sus clases no estÃ¡n en ningÃºn atajo.
    -- Las pestaÃ±as (`WBP_OBJ_Option_List_004_C`) sÃ­ estÃ¡n en `menuFastClasses` y por eso siempre se
    -- sintieron Ã¡giles; las opciones de dentro, no. Esto lo iguala.
    -- CLASES VERIFICADAS en el volcado `dump_0726_ajustes_ency.txt` (las que REALMENTE tomaron el foco):
    -- `WBP_OBJ_Option_List_010_Text_C` (4 veces; son las 12 opciones de Accesibilidad tipo Asistencia de
    -- batalla) y `WBP_OBJ_Option_List_011_Gauge_C` (3 veces; los volÃºmenes de Sonido â€” LA pantalla que se
    -- rompiÃ³ el 07-21 justamente por bloquearle el walk). Se aÃ±ade tambiÃ©n `WBP_OBJ_Option_List_002_C`
    -- (DataDelete), visible en el mismo volcado.
    -- Gate `WBP_Option_C`, verificado presente en Ajustes el 07-26 (es el contenedor con TitleText
    -- "Opciones" y Text_CategoryTitle). Fuera de Ajustes no cuesta nada. Fail-safe: si nada tiene el foco,
    -- cae al walk de siempre. NO se aÃ±aden a `menuFastClasses` (LECCIÃ“N 15: esa lista corre en TODAS las
    -- pantallas); van gateadas por la suya.
    -- Enfriamiento en el `if` EXTERIOR: ver la nota del atajo de la Enciclopedia. Un atajo enfriado se
    -- SALTA, nunca aborta el escaneo.
    -- Settle y enfriamiento en el `if` EXTERIOR: ver la nota del atajo de la Enciclopedia.
    if H.GetCachedFirstOf("WBP_Option_C") and os.clock() >= _optMissUntil
       and os.clock() >= uiChurnUntil + 0.6 then
        -- === BUG PROPIO CORREGIDO (07-27 noche). LECCIÃ“N 14, y la cometÃ­ yo el mismo dÃ­a ===
        -- IvÃ¡n: "el menÃº principal mÃ¡s pesado, 3 o 4 segundos en nombrar cada cosa". EVIDENCIA: 4 cuelgues
        -- del bucle de foco en 3 minutos, DOS de ellos con `focusStage=scan-option` â€” y en TODA esa sesiÃ³n
        -- no se saliÃ³ del menÃº principal (el livelog solo tiene los dos churn del arranque, ninguna
        -- transiciÃ³n). O sea: este atajo se estaba ejecutando EN EL MENÃš, donde Ajustes no estÃ¡ en
        -- pantalla, tocando widgets de Ajustes que existen en memoria pero no se muestran. Esos cuelgues
        -- de 1.5-3s son exactamente el retraso que IvÃ¡n oye. **`GetCachedFirstOf` responde "EXISTE", no
        -- "ESTÃ EN PANTALLA"** â€” usar presencia como gate de pantalla es el error que la LECCIÃ“N 14
        -- describe, y lo repetÃ­ al crear estos atajos.
        -- NO se arregla con IsVisible: sobre contenedores en teardown es justamente lo que cuelga
        -- (LECCIÃ“N 1, y los 224 colgones del 07-19). Se arregla con la seÃ±al que YA tenemos gratis: si el
        -- atajo no encuentra foco, es que NO estamos en su pantalla, asÃ­ que se enfrÃ­a 1.5s en vez de
        -- reintentar 62 veces por segundo. Cuando de verdad entras a Ajustes, el primer intento acierta y
        -- el enfriamiento no llega a armarse. Y en cada cambio de pantalla (settle de arriba) se limpia,
        -- para que entrar a Ajustes nunca herede un enfriamiento viejo.
        _focusStage = "scan-option"
        -- `WBP_OBJ_Option_List_004_C` (las PESTAÃ‘AS de Ajustes) se MUEVE aquÃ­ desde `menuFastClasses`
        -- (07-27). Estaba en la lista global, que corre en TODAS las pantallas; aquÃ­ solo corre en Ajustes.
        -- Con esto la lista global baja a 4 clases (empezÃ³ en 6) y el menÃº principal paga menos por tick.
        local optClasses = { "WBP_OBJ_Option_List_004_C", "WBP_OBJ_Option_List_010_Text_C",
                             "WBP_OBJ_Option_List_011_Gauge_C", "WBP_OBJ_Option_List_002_C" }
        for _, cls in ipairs(optClasses) do
            local ook, items = pcall(FindAllOf, cls)
            if ook and items then
                for i = 1, #items do
                    local w = items[i]
                    if IsValidRef(w) then
                        local fok, focused = pcall(function()
                            if not IsValidRef(w) then return false end
                            return w.HasKeyboardFocus and w:HasKeyboardFocus()
                        end)
                        if fok and focused then
                            _optMissUntil = 0
                            return w
                        end
                    end
                end
            end
        end
        _optMissUntil = os.clock() + 30  -- nadie con foco => no estamos en Ajustes; no insistir
    end

    -- TIENDA fast-path (07-27). ARREGLA UN BUG REPORTADO Y ADEMÃS ADELGAZA LA LISTA GLOBAL.
    -- IvÃ¡n: "cuando entro a la tienda y cambio entre shop y customize, solo nombra a shop". CAUSA
    -- ENCONTRADA EN EL VOLCADO (no supuesta): son DOS clases distintas, `WBP_OBJ_SH_BTN_Shop_C` (tuvo el
    -- foco 7 veces) y `WBP_OBJ_SH_BTN_Customize_C` (3 veces) â€” y solo la PRIMERA estaba en
    -- `menuFastClasses`. Con el foco en Customize el atajo global fallaba, se enfriaba, y como el bloqueo
    -- del walk se apoya en ese enfriamiento, no quedaba NADIE escaneando: silencio total en esa pestaÃ±a.
    -- Esto explica de paso parte de la lentitud que IvÃ¡n nota: cada vez que el foco cae en algo que el
    -- atajo global no cubre, se dispara el enfriamiento y el walk se retiene.
    -- LO CORRECTO NO ERA CRECER LA LISTA GLOBAL (LECCIÃ“N 15: eso subiÃ³ las muertes de foco de 2 a 12),
    -- sino MOVER la tienda a su propio atajo gateado â€” y de paso `WBP_OBJ_SH_BTN_Shop_C` SALE de la lista
    -- global, que baja de 6 clases a 5. La lista global se ADELGAZA, que es justo lo que pide la lecciÃ³n.
    -- Clases verificadas en el volcado: Shop (1 instancia), Customize (1), Category_00 (7) e ItemIcon_S00
    -- (16, los artÃ­culos del catÃ¡logo; uno tuvo el foco). MÃ¡ximo ~25 widgets contra los ~1145 del walk.
    -- Gate `WBP_GRP_SH_Top_C`: aparece en 11 entradas, las mismas que los dos botones => estÃ¡ presente en
    -- toda la tienda. Con settle post-churn DESDE EL PRIMER DÃA (patrÃ³n aprendido hoy a golpes).
    -- Enfriamiento en el `if` EXTERIOR: ver la nota del atajo de la Enciclopedia.
    if H.GetCachedFirstOf("WBP_GRP_SH_Top_C") and os.clock() >= _shopMissUntil
       and os.clock() >= uiChurnUntil + 0.6 then
        _focusStage = "scan-shop"
        local shopClasses = { "WBP_OBJ_SH_BTN_Shop_C", "WBP_OBJ_SH_BTN_Customize_C",
                              "WBP_OBJ_SH_BTN_Category_00_C", "WBP_OBJ_SH_ItemIcon_S00_C" }
        for _, cls in ipairs(shopClasses) do
            local shok, items = pcall(FindAllOf, cls)
            if shok and items then
                for i = 1, #items do
                    local w = items[i]
                    if IsValidRef(w) then
                        local fok, focused = pcall(function()
                            if not IsValidRef(w) then return false end
                            return w.HasKeyboardFocus and w:HasKeyboardFocus()
                        end)
                        if fok and focused then
                            _shopMissUntil = 0
                            return w
                        end
                    end
                end
            end
        end
        _shopMissUntil = os.clock() + 30  -- nadie con foco => no estamos en la Tienda; no insistir
    end

    -- SKILL LIST / command-list fast-path (WBP_GRP_SL_Main_0_C). Same idea as the char-select fast-path:
    -- its focusable items are FEW (WBP_OBJ_SL_Content_Skill_C skills + WBP_OBJ_SL_Content_Other_C like Ki
    -- Charge), so scan ONLY those instead of the ~2170-widget full walk that hangs on the churning skill
    -- previews (the command-list lag IvÃ¡n reported). Falls through to the full walk if none is focused
    -- (e.g. focus on a tab) so nothing breaks.
    if H.GetCachedFirstOf("WBP_GRP_SL_Main_0_C") then
        _focusStage = "scan-sl"
        local slClasses = { "WBP_OBJ_SL_Content_Skill_C", "WBP_OBJ_SL_Content_Other_C" }
        for _, cls in ipairs(slClasses) do
            local sok, items = pcall(FindAllOf, cls)
            if sok and items then
                for i = 1, #items do
                    local w = items[i]
                    if IsValidRef(w) then
                        local fok, focused = pcall(function()
                            if not IsValidRef(w) then return false end
                            return w.HasKeyboardFocus and w:HasKeyboardFocus()
                        end)
                        if fok and focused then return w end
                    end
                end
            end
        end
    end

    -- MENU BUTTON fast-path: en el menÃº principal (y Shenron) el walk completo (~1762 widgets con la
    -- escena del demo cargada) va LENTO y tropieza (los ~10s de retraso + pesadez al volver de pelea,
    -- 07-20). Los botones focables son POCOS y de clases CONFIRMADAS EN VIVO, asÃ­ que escanea SOLO
    -- esos, como los atajos de char-select / lista de comandos. CAE al walk completo si ninguno tiene
    -- foco (NUNCA mudea). La repeticiÃ³n que esto causaba antes ya se arreglÃ³ aparte (preserveDedup).
    -- WBP_OBJ_Option_List_004_C = botones de AJUSTES (Options). Ajustes es un SUB-MENÃš del principal
    -- (WBP_MainMenu_ModeMenu_C sigue presente => onMainMenu=true => el return-nil de abajo bloquea el
    -- walk), asÃ­ que sin su clase aquÃ­, Ajustes quedaba MUDO (regresiÃ³n 07-20 de mi cambio del menÃº).
    -- NO CRECER ESTA LISTA (medido 07-20, evidencia dura): agregar 3 clases (Option_List_010_Text/
    -- Text2 + SH_BTN_Customize) subiÃ³ las muertes del bucle de FOCO de 2 a 12 en una sola sesiÃ³n, y
    -- las 12 con focusStage=scan-menubtn. Motivo: este atajo corre a 16ms y hace UN GetCachedFirstOf
    -- + FindAllOf POR CLASE; 9 clases = ~540 consultas nativas por segundo en el punto mÃ¡s caliente.
    -- Peor: las clases de Tienda/Ajustes hacen que al SALIR de esas pantallas el atajo vaya a buscar
    -- justo los botones que el juego estÃ¡ destruyendo => cuelgue nativo (LECCIÃ“N 1). Cada cuelgue =
    -- reinicio del watchdog = el silencio de 13-20s que reporta IvÃ¡n. Los sub-menÃºs NO se arreglan
    -- enumerando clases aquÃ­ (whack-a-mole): se arreglan dejando que el walk completo los lea (abajo).
    -- NOTA 07-22: se probÃ³ quitar `WBP_OBJ_Option_List_004_C` culpÃ¡ndola del crash al entrar a sub-menÃºs de
    -- Ajustes, pero era CORRELACIÃ“N (el foco estaba ahÃ­), no causa probada: esa clase lleva desde el 07-20
    -- aquÃ­ SIN causar ese crash. RESTAURADA. La sospecha real pasa al cÃ³digo NUEVO del lector de valores
    -- (ver PollOptionValue, desactivado para el experimento limpio).
    -- 07-27: `WBP_OBJ_SH_BTN_Shop_C` SALE de aquÃ­ â€” la tienda pasa a tener su propio atajo gateado (ver
    -- `scan-shop` arriba), que ademÃ¡s cubre Customize, que aquÃ­ faltaba. La lista global baja de 6 a 5
    -- clases: menos consultas por tick en TODAS las pantallas, que es exactamente lo que pide la LECCIÃ“N 15.
    local menuFastClasses = { "WBP_OBJ_MainMenu_BTN_Sub1_C", "WBP_MainMenu_Base_C", "WBP_OBJ_WishSR_BTN_Sub_C", "WBP_OBJ_WishSR_BTN_Talk_C" }
    -- Subconjunto: las clases del MENÃš PRINCIPAL PELÃ“N. Verificado en el volcado del 07-27: son
    -- exactamente las tres que tuvieron el foco en el menÃº justo antes del crash (BTN_Sub1, MainMenu_Base
    -- y WishSR_BTN_Sub). `Option_List_004` (Ajustes) y `SH_BTN_Shop` (Tienda) quedan FUERA a propÃ³sito.
    -- NO buscar los botones del MENÃš durante la VENTANA DE SALIDA (07-22). CRASH F:pollfocus al entrar a
    -- EPISODIO DE BATALLA (y a Historia): el foco estaba en `WBP_OBJ_MainMenu_BTN_Sub1` â€” que estÃ¡ en esta
    -- lista â€” y al pulsar A esos botones se DESTRUYEN para cargar el modo, mientras este atajo va justo a
    -- buscarlos (FindAllOf + HasKeyboardFocus sobre botones en teardown) => cuelgue nativo. Mismo mecanismo
    -- de la LECCIÃ“N 15, ahora con las clases del MENÃš PRINCIPAL. Gate idÃ©ntico al del skip del foco loop:
    -- `not Trackers.onMainMenu` es CLAVE â€” DENTRO del menÃº (onMainMenu=true) el atajo SIGUE corriendo, asÃ­
    -- que el menÃº NO pierde agilidad; solo se omite en los 2.5s posteriores a DEJARLO, cuando esos botones
    -- ya no sirven de nada. Si no hay atajo, cae al walk (que sÃ­ lleva el 2Âº IsValidRef pegado a la nativa).
    -- === FRENO AL PROPIO ATAJO (07-27). EVIDENCIA DIRECTA, no teorÃ­a ===
    -- El watchdog capturÃ³ un CUELGUE 3 segundos antes del crash fatal con
    -- `focusStage=scan-menubtn` â€” o sea, AQUÃ DENTRO â€” y el crash fatal dejÃ³ la misma migaja `F:pf-fast`.
    -- AdemÃ¡s ese cuelgue ocurriÃ³ con el menÃº ASENTADO (wc=1755, churn=false), asÃ­ que no hace falta ni
    -- una transiciÃ³n para que este atajo se atragante. Es la LECCIÃ“N 15 en vivo.
    -- EL PROBLEMA DE FONDO: cuando el atajo SÃ halla el botÃ³n enfocado hace `return` inmediato y toca
    -- poquÃ­simo. Pero cuando NO lo halla â€”justo lo que pasa en el instante en que pulsas A y los botones
    -- del menÃº se estÃ¡n destruyendoâ€” recorre las SEIS clases, con un `FindAllOf` y un `HasKeyboardFocus`
    -- por cada botÃ³n de cada una: decenas de llamadas nativas sobre widgets moribundos, 62 veces por
    -- segundo mientras dura el desmontaje (~2s = mÃ¡s de cien pasadas). MÃ¡xima exposiciÃ³n en el peor
    -- momento posible.
    -- EL FRENO: en cuanto una pasada falla, no se vuelve a intentar durante 0.8s. Eso convierte esas
    -- ~120 pasadas del desmontaje en 2 o 3. No cambia NADA cuando el menÃº estÃ¡ sano (ahÃ­ el atajo acierta
    -- y ni siquiera llega al final del bucle), y es FAIL-SAFE (LECCIÃ“N 11): si el foco vuelve a un botÃ³n,
    -- a los 0.8s se reintenta y lo encuentra. Coste peor caso: recuperar el foco en el menÃº hasta 0.8s
    -- mÃ¡s tarde tras un hueco.
    -- NO se toca el ORDEN ni el CONTENIDO de `menuFastClasses` (LECCIÃ“N 15: no crecerla, no reordenarla).
    local justLeftMenuScan = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5

    -- === ATAJO CACHEADO DEL MENÃš (07-27). LA SOLUCIÃ“N DE FONDO, no otro parche de ventana ===
    -- POR QUÃ‰ HACÃA FALTA: `scan-menubtn` ya se colgÃ³ dos veces (watchdog 14:05:07 y 14:39:44) y por fin
    -- MATÃ“ el juego a las 14:55:30 (migaja `F:sf-menubtn`, menÃº asentado en wc=1755 y sin churn, o sea al
    -- pulsar A). El enfriamiento progresivo NO puede salvarlo: el crash ocurre en la PRIMERA pasada
    -- fallida, y el enfriamiento solo evita de la segunda en adelante. No hay ninguna seÃ±al previa que
    -- mirar, asÃ­ que hay que atacar el COSTE, que es lo que en este proyecto siempre ha funcionado.
    -- LA CUENTA: recorrer las clases cuesta, por tick, un GetCachedFirstOf + un FindAllOf + dos IsValidRef
    -- y un HasKeyboardFocus POR BOTÃ“N (unos 8 en el menÃº) => del orden de 24 llamadas nativas. Preguntarle
    -- a la ref que YA tenÃ­a el foco cuesta DOS. Doce veces menos superficie de choque, y de paso el menÃº
    -- va mÃ¡s rÃ¡pido (justo lo que pidiÃ³ IvÃ¡n).
    -- Y LO IMPORTANTE: `IsValidRef` sobre esa Ãºnica ref es la forma MÃS BARATA de enterarse de que el
    -- botÃ³n muriÃ³. Si muriÃ³, estamos en el desmontaje: se corta el tick AHÃ MISMO, sin FindAllOf ni
    -- HasKeyboardFocus sobre nada. Antes ese descubrimiento se hacÃ­a a base de tocar los 8 botones.
    -- SOBRE LA DECISIÃ“N DEL 07-21 (se prohibiÃ³ el atajo cacheado de PollFocus en el menÃº porque tronÃ³ al
    -- SALIR con la ref del menÃº muerto): esto NO la revierte. Aquel corrÃ­a tambiÃ©n DESPUÃ‰S de que
    -- `onMainMenu` cayera; este solo corre CON `onMainMenu` true, y la salida sigue cubierta por
    -- `justLeftMenu`, el enfriamiento y el bloqueo del walk. AdemÃ¡s revalida antes de cada uso.
    -- Por defecto se asume que el menÃº NO estÃ¡ vivo; solo la comprobaciÃ³n de abajo puede confirmarlo. AsÃ­,
    -- si no hay ref cacheada (reciÃ©n arrancado, o acaba de morir), el bloqueo del walk mantiene su
    -- protecciÃ³n; y en cuanto se confirma que el botÃ³n vive, el walk queda libre para buscar el foco donde
    -- el atajo no llega (el menÃº de avisos, por ejemplo). Ver la nota del bloqueo del walk.
    _menuLooksAlive = false
    if Trackers.onMainMenu and _lastMenuFastWidget then
        if not IsValidRef(_lastMenuFastWidget) then
            -- El botÃ³n que tenÃ­a el foco YA NO EXISTE => el menÃº se estÃ¡ desmontando. Cortar el tick sin
            -- tocar ni un widget mÃ¡s, y armar el enfriamiento para que el resto del desmontaje no insista.
            _lastMenuFastWidget = nil
            _menuFastMissStreak = _menuFastMissStreak + 1
            local coolD = 0.15 * (2 ^ math.min(_menuFastMissStreak - 1, 3))
            if coolD > 0.8 then coolD = 0.8 end
            _menuFastMissUntil = os.clock() + coolD
            return nil
        end
        _menuLooksAlive = true  -- el botÃ³n del menÃº SIGUE VIVO: el menÃº no se estÃ¡ desmontando
        local cok, cfocused = pcall(function()
            if not IsValidRef(_lastMenuFastWidget) then return false end
            return _lastMenuFastWidget.HasKeyboardFocus and _lastMenuFastWidget:HasKeyboardFocus()
        end)
        if cok and cfocused then
            _lastMenuFastHitClock = os.clock()
            _menuFastMissStreak = 0
            _menuFocusLostAt = 0
            return _lastMenuFastWidget  -- el dedup de OnWidgetFocused evita que se re-lea
        end
        -- === LA PIEZA QUE FALTABA (07-27, tras el crash de las 15:41:31) ===
        -- El atajo cacheado NO cubriÃ³ el crash y ahora sÃ© por quÃ©: cuando pulsas A, el juego primero le
        -- QUITA el foco al botÃ³n y luego lo destruye. AsÃ­ que el botÃ³n cacheado sigue VIVO pero ya sin
        -- foco â€” exactamente el mismo estado que cuando mueves el stick â€” y el flujo caÃ­a al recorrido de
        -- clases, que es donde muriÃ³ (migaja `F:sf-menubtn`).
        -- No hay forma de distinguir "moviste el stick" de "pulsaste A" en ese instante... pero NO HACE
        -- FALTA ADIVINAR: basta con ESPERAR 50ms (3 parpadeos) antes de ir a buscar. Si pulsaste A, en
        -- esos 50ms el conteo de widgets ya se mueve y el freno de churn (o el small-churn guard) corta el
        -- tick ANTES de llegar aquÃ­. Si solo moviste el stick, a los 50ms se busca normal y se lee.
        -- COSTE REAL: 50 milÃ©simas de retraso al cambiar de botÃ³n en el menÃº. NVDA tarda mÃ¡s que eso en
        -- arrancar a hablar, asÃ­ que es inaudible. Y a cambio, el recorrido peligroso deja de ejecutarse
        -- justo en el instante del pulsado, que es el Ãºnico momento en que ha matado.
        -- Esto es esperar a que la seÃ±al LLEGUE en vez de intentar predecirla â€” el mismo principio que
        -- ya funcionÃ³ con el settle post-churn de los atajos de pantalla.
        if _menuFocusLostAt == 0 then _menuFocusLostAt = os.clock() end
        if (os.clock() - _menuFocusLostAt) < 0.05 then return nil end
    end

    if not justLeftMenuScan and os.clock() >= _menuFastMissUntil then
        if Trackers.onMainMenu then Crumb("F:sf-menubtn") end  -- migaja fina: solo en el menÃº, para confirmar el fix
        for _, cls in ipairs(menuFastClasses) do
            if H.GetCachedFirstOf(cls) then
                _focusStage = "scan-menubtn"
                local bok, btns = pcall(FindAllOf, cls)
                if bok and btns then
                    for i = 1, #btns do
                        local w = btns[i]
                        if IsValidRef(w) then
                            local fok, focused = pcall(function()
                                if not IsValidRef(w) then return false end
                                return w.HasKeyboardFocus and w:HasKeyboardFocus()
                            end)
                            if fok and focused then
                                -- SELLO DEL MENÃš PRINCIPAL (07-27, ver el bloqueo del walk mÃ¡s abajo).
                                -- Solo con las clases del menÃº PELÃ“N, NUNCA con las de Ajustes/Tienda:
                                -- si se sellara con `Option_List_004` (las pestaÃ±as de Ajustes), al bajar
                                -- a Sonido el walk quedarÃ­a bloqueado y se repetirÃ­a la regresiÃ³n del
                                -- 07-21 ("Sonido tarda mucho y repite la opciÃ³n").
                                if MENU_MAIN_CLASSES[cls] then _lastMenuFastHitClock = os.clock() end
                                -- DIAG TEMPORAL DE RETRASO (07-27, quitar al cerrar el caso de la lentitud).
                                -- Mide lo que de verdad importa: cuÃ¡nto pasÃ³ entre que el botÃ³n anterior
                                -- perdiÃ³ el foco y este quedÃ³ leÃ­do. Solo imprime si supera 0.2s, asÃ­ que
                                -- en navegaciÃ³n sana no ensucia el log. Si sale mucho y con valores altos,
                                -- el tiempo se va en los frenos; si no sale, la lentitud viene de otro lado
                                -- y hay que buscarla fuera del bucle de foco.
                                if _menuFocusLostAt > 0 then
                                    local lag = os.clock() - _menuFocusLostAt
                                    if lag >= 0.2 then
                                        print(string.format("[AE-DIAG] menu focus lag %.2fs (fallos=%d)", lag, _menuFastMissStreak))
                                    end
                                end
                                _menuFastMissStreak = 0  -- acertÃ³: el enfriamiento vuelve a cero
                                _menuFocusLostAt = 0     -- foco recuperado: la espera de 50ms se reinicia
                                _lastMenuFastWidget = w  -- para el atajo cacheado del menÃº (ver arriba)
                                return w
                            end
                        end
                    end
                end
            end
        end
        -- Pasada COMPLETA sin encontrar foco: o el menÃº se estÃ¡ desmontando, o el foco estÃ¡ en algo que
        -- este atajo no cubre. En ambos casos repetir la bÃºsqueda cada 16ms no aporta nada y es justo lo
        -- que cuelga.
        -- ENFRIAMIENTO PROGRESIVO (07-27, tras el reporte de IvÃ¡n: "siento el menÃº principal menos Ã¡gil...
        -- tarda mÃ¡s segundos en leerme"). El enfriamiento FIJO de 0.8s era el culpable: un solo fallo
        -- aislado â€”normal al moverse entre botones o al pasar el foco por algo no cubiertoâ€” frenaba el
        -- atajo Y, por dependencia, tambiÃ©n el walk, asÃ­ que la siguiente lectura llegaba casi un segundo
        -- tarde. Ahora arranca en 0.15s (imperceptible) y solo se va doblando si los fallos SIGUEN
        -- llegando, que es la firma del desmontaje: 0.15, 0.3, 0.6 y tope 0.8.
        -- AsÃ­ se conserva lo que importa â€”durante los ~2s de un desmontaje se pasa de ~120 pasadas a unas
        -- pocasâ€” sin castigar la navegaciÃ³n normal, donde los fallos son sueltos y el contador se pone a
        -- cero en cuanto el atajo vuelve a acertar.
        -- ENFRIAMIENTO REDUCIDO A 0.05s FIJO (07-27 noche). IvÃ¡n sigue notando el menÃº lento, pero esta
        -- sesiÃ³n tuvo **CERO cuelgues** (antes 4 en 3 minutos), asÃ­ que el retraso que le queda YA NO son
        -- cuelgues: es tiempo de espera que pongo yo. Y el mayor sospechoso es este enfriamiento, que con
        -- el backoff llegaba a 0.8s: si al mover el stick el juego tarda un pelÃ­n en asignar el foco al
        -- botÃ³n siguiente, la pasada falla y el mod se queda callado 0.15s, luego 0.3s, luego 0.6s...
        -- POR QUÃ‰ AHORA SE PUEDE BAJAR SIN PERDER PROTECCIÃ“N: el enfriamiento naciÃ³ para no repetir ~120
        -- pasadas durante el desmontaje del menÃº, pero ese trabajo lo hace YA la espera de 50ms de arriba
        -- (que impide el recorrido justo en el instante del pulsado) y, pasado ese instante, el freno de
        -- churn congela el bucle entero. El enfriamiento largo habÃ­a quedado redundante y solo cobraba
        -- peaje en la navegaciÃ³n normal. Con 0.05s sigue habiendo tope de insistencia (20 pasadas por
        -- segundo en vez de 62) sin que se oiga.
        -- Si volviera a crashear en `scan-menubtn`, esto es lo PRIMERO a revisar.
        _menuFastMissStreak = _menuFastMissStreak + 1
        _menuFastMissUntil = os.clock() + 0.05
    end

    -- QUITADO 07-20 (era la RAÃZ de la mudez de sub-menÃºs). AquÃ­ habÃ­a un
    --     if H.GetCachedFirstOf("WBP_MainMenu_ModeMenu_C") then return nil end
    -- para no caminar los ~1762 widgets de la escena del demo. PERO Ajustes, Tienda y demÃ¡s son
    -- SUB-MENÃšS del principal: ModeMenu sigue presente en ellos => el return-nil los tapaba y los
    -- dejaba MUDOS salvo que su clase estuviera enumerada arriba (whack-a-mole infinito: leÃ­an los
    -- interruptores de activar/desactivar y no los de subir/bajar, que son otra clase). IvÃ¡n seÃ±alÃ³
    -- el dato clave: esas pantallas SÃ leÃ­an antes de esta lÃ­nea. El walk completo las lee TODAS solo.
    -- Por quÃ© es razonable volver a Ã©l AHORA (no es revertir a ciegas): (1) cuando esta lÃ­nea se puso,
    -- el foco leÃ­a DURANTE el churn (bypass) y por eso el walk tronaba en las cargas; ese bypass ya
    -- NO existe, el foco se frena por churn; (2) hoy el menÃº recibe ventana LARGA de 2.0s, asÃ­ que el
    -- walk solo corre con la pantalla ASENTADA; (3) el walk hace UNA sola consulta nativa (un
    -- FindAllOf) contra las ~9 por tick del atajo, que es lo que estaba colgando el bucle.
    -- Si volviera a crashear al entrar a sub-menÃºs, esta lÃ­nea es lo primero a restaurar.
    -- FRENO FINO DEL WALK EN ZONA DE MENÃšS (07-20). EVIDENCIA: crash F:pollfocus al entrar a Episodio
    -- de Batalla; el volcado guardÃ³ los 12 instantes previos y los 2 Ãºltimos (2s antes) muestran los
    -- widgets visibles desplomÃ¡ndose 42 -> 9 -> 8 y NADA enfocado = el menÃº desmontÃ¡ndose. El churn
    -- guard grande no lo atrapa: solo arma con saltos >=200, y un desmontaje que mata widgets de a
    -- pocos se le cuela. AquÃ­ el walk (1762 widgets) camina objetos a medio liberar y truena.
    -- POR QUÃ‰ ES SEGURO NO CAMINAR AQUÃ: en el menÃº principal pelÃ³n el ATAJO de botones (arriba) ya
    -- devolviÃ³ el botÃ³n enfocado â€” el volcado lo confirma (foco en WBP_OBJ_MainMenu_BTN_Sub1_C en
    -- todas las entradas con el menÃº normal). El walk solo entra cuando el atajo NO hallÃ³ foco, que
    -- en el menÃº es justo el hueco del desmontaje: puro riesgo, cero beneficio. En sub-menÃºs
    -- (Ajustes/Tienda) el walk SÃ es indispensable, y ahÃ­ solo se aplaza 16ms por tick movido.
    -- `swing` y `count` salen de la LONGITUD del arreglo: cero llamadas nativas nuevas.
    -- TOPE ANTI-MUDEZ (LECCIÃ“N 6: un freno sin salida deja el lector mudo PARA SIEMPRE): tras 8 ticks
    -- frenados se camina igual y el contador se reinicia. Con movimiento sostenido eso da 1 walk cada
    -- ~9 ticks (~144ms) â€” baja muchÃ­simo la exposiciÃ³n SIN poder enmudecer nunca.
    -- REVERTIDO 07-22: el intento del 07-21 de bloquear el walk SIEMPRE (quitando `swing ~= 0`, para
    -- reducir el crash del menÃº principal) fue una REGRESIÃ“N: los sub-menÃºs de Ajustes PROFUNDO (Sonido,
    -- clase Option_List_011_Gauge que NO estÃ¡ en el fast-path) DEPENDEN del walk cada tick, y bloquearlo
    -- 8 de cada 9 ticks los volviÃ³ LENTOS y con re-lectura (IvÃ¡n: "Sonido tarda mucho y repite la opciÃ³n";
    -- 0 loops died => no era cuelgue, era el freno). Vuelve a `swing ~= 0`: el freno solo bloquea el walk
    -- durante CHURN (transiciÃ³n/reconstrucciÃ³n); en un sub-menÃº ESTABLE (swing==0) el walk corre cada tick
    -- => Sonido lee rÃ¡pido de nuevo. COSTO: el crash del menÃº principal (walk sobre la escena del demo con
    -- conteo estable) vuelve a ser residual intermitente â€” se prioriza la lectura de Ajustes (constante y
    -- usada) sobre ese crash raro. VÃ­a de fondo pendiente sigue siendo la BASE COMÃšN de botones.
    -- === EL FIX DEL CRASH `F:menuwalk` (07-27) ===
    -- EVIDENCIA (crash al entrar a la Enciclopedia, 12:56:09): migaja del foco = `F:menuwalk`, o sea
    -- muriÃ³ AQUÃ, caminando los ~1762 widgets del menÃº. El volcado F5 de esa misma sesiÃ³n enseÃ±a por quÃ©:
    -- en las entradas previas el foco estaba en botones del menÃº (`WBP_OBJ_MainMenu_BTN_Sub1_01` a las
    -- 12:56:06) y en la ÃšLTIMA entrada, 12:56:08, NO HAY FOCO NINGUNO â€” el menÃº desmontÃ¡ndose tras pulsar
    -- A. Sin foco, el atajo de arriba no halla nada y el flujo cae a este walk, justo sobre los widgets
    -- que se estÃ¡n liberando. Y el bloqueo de abajo no actuÃ³ porque el conteo aÃºn no se habÃ­a movido
    -- (`swing == 0`): el livelog no tiene ni una lÃ­nea de churn antes del crash.
    -- LA SEÃ‘AL BUENA NO ES EL CONTEO, ES EL FOCO. En el menÃº sano el atajo SIEMPRE halla el botÃ³n
    -- enfocado (y hace return, sin llegar aquÃ­); que de golpe no halle nada ES la firma del desmontaje.
    -- Por eso basta con recordar cuÃ¡ndo fue la Ãºltima vez que el atajo acertÃ³ en una clase del menÃº
    -- PELÃ“N: si fue hace un instante y ahora no hay nada, estamos en el hueco peligroso y NO se camina.
    -- POR QUÃ‰ NO REPITE LA REGRESIÃ“N DEL 07-21 (Sonido lento y repitiendo): aquel intento bloqueaba el
    -- walk SIEMPRE que `onMainMenu` fuera true, y `onMainMenu` tambiÃ©n es true en los sub-menÃºs, asÃ­ que
    -- mataba a Sonido, que DEPENDE del walk (su clase `Option_List_011_Gauge` no estÃ¡ en ningÃºn atajo â€”
    -- confirmado en el volcado: tuvo el foco 3 veces). AquÃ­ el sello SOLO se pone con las clases del menÃº
    -- pelÃ³n, que en Sonido no se enfocan nunca; su reloj queda viejo y el walk corre igual que hoy.
    -- FAIL-SAFE: es una ventana temporizada (LECCIÃ“N 11). Si el menÃº desaparece de verdad, nadie vuelve a
    -- sellar el reloj y a los 2.0s el walk se suelta solo. No puede enmudecer nada de forma permanente.
    -- COSTO ACEPTADO: al entrar del menÃº a un modo, el walk se aplaza hasta 2.0s. La Enciclopedia ya no
    -- lo nota (tiene su propio atajo, aÃ±adido arriba) y las pestaÃ±as de Ajustes/Tienda tampoco (estÃ¡n en
    -- `menuFastClasses`). Reversible: borrar este bloque.
    -- === VERSIÃ“N 3 DE ESTE BLOQUEO (07-27 tarde). ERROR PROPIO CORREGIDO ===
    -- Historia, porque la lecciÃ³n importa: v1 usaba 2.0s desde el Ãºltimo acierto del atajo y funcionÃ³
    -- contra el walk, pero ralentizÃ³ Ajustes (que entonces dependÃ­a del walk). v2 bajÃ³ a 0.8s... y el
    -- crash `F:menuwalk` VOLVIÃ“. CAUSA, y fue culpa de una interacciÃ³n que yo mismo introduje: el
    -- enfriamiento del atajo (`_menuFastMissUntil`) hace que, tras fallar, el atajo NO se vuelva a
    -- ejecutar durante 0.8s â€” y como el atajo es quien SELLA `_lastMenuFastHitClock`, el sello deja de
    -- refrescarse y a los 0.8s este bloqueo se soltaba... justo en mitad del desmontaje del menÃº, que
    -- dura ~2s. O sea: mi propio arreglo del atajo abriÃ³ la puerta del walk. Verificado en el volcado del
    -- 07-27 14:21: foco en `WBP_OBJ_MainMenu_BTN_Sub1_01` hasta las 14:21:18 y SIN FOCO en la entrada de
    -- las 14:21:21, el segundo del crash.
    -- v3 mira las DOS seÃ±ales, no solo el sello: se bloquea tambiÃ©n mientras el atajo estÃ© ENFRIADO (que
    -- es tanto como decir "el atajo acaba de fallar", o sea estamos en el hueco). Como el atajo reintenta
    -- cada 0.8s y vuelve a fallar mientras el menÃº se desmonta, el enfriamiento se renueva y el bloqueo
    -- aguanta los ~2s completos, sin depender de un nÃºmero fijo.
    -- Y la ventana del sello vuelve a 2.5s: ya NO penaliza a Ajustes, porque Ajustes tiene desde hoy su
    -- propio atajo (`scan-option`) y no depende del walk. Ese era el motivo de haberla acortado.
    -- TOPE ANTI-MUDEZ OBLIGATORIO (LECCIÃ“N 6): un freno sin salida enmudece PARA SIEMPRE. Si en el menÃº
    -- llegara a haber un elemento enfocable que ningÃºn atajo cubre (p.ej. un diÃ¡logo de confirmaciÃ³n), el
    -- atajo fallarÃ­a siempre y sin tope no se leerÃ­a jamÃ¡s. Con el tope, tras ~1.9s se camina igual y se
    -- lee; el contador se reinicia en cuanto el walk corre una vez.
    -- === REGRESIÃ“N CORREGIDA (07-28). IvÃ¡n: "el menÃº del botÃ³n X, el de los avisos, ya no lo lee" ===
    -- CAUSA, verificada en el volcado: en ese menÃº el foco lo tienen `WBP_OBJ_Present_MailTitle_C` (8
    -- focos), `WBP_GRP_PresentBox_Main_C` y `WBP_OBJ_OLB_MenuBTN_C` â€” **ninguna estÃ¡ en `menuFastClasses`
    -- ni en ningÃºn atajo**, asÃ­ que esa pantalla SIEMPRE ha dependido del walk. Y yo bloqueÃ© el walk en el
    -- menÃº. El atajo fallaba (esas clases no estÃ¡n), el fallo armaba el enfriamiento, el enfriamiento
    -- activaba este bloqueo, y la pantalla se quedaba sin nadie que la leyera.
    -- EL ERROR DE CONCEPTO: estaba tratando "el atajo no encuentra el foco" como si SIEMPRE significara
    -- "el menÃº se estÃ¡ desmontando". Son dos cosas distintas:
    --   * el menÃº se DESMONTA (pulsaste A) => el botÃ³n que tenÃ­a el foco MUERE. AquÃ­ sÃ­ hay que frenar.
    --   * el foco se fue a algo que el atajo no cubre (avisos, un diÃ¡logo...) => el botÃ³n sigue VIVO,
    --     el menÃº estÃ¡ sano y hay que ir a buscar el foco con el walk. AquÃ­ frenar es dejar mudo.
    -- La seÃ±al para distinguirlos ya la tenÃ­a delante: si `_lastMenuFastWidget` sigue VÃLIDO, el menÃº no se
    -- estÃ¡ muriendo. `_menuLooksAlive` guarda justo eso, y el bloqueo solo actÃºa cuando el menÃº NO parece
    -- vivo â€” que es el caso peligroso de verdad y el Ãºnico que querÃ­a frenar.
    if Trackers.onMainMenu and not _menuLooksAlive and _menuWalkHoldStreak < 120
       and (os.clock() < _menuFastMissUntil or (os.clock() - _lastMenuFastHitClock) < 2.5) then
        _menuWalkHoldStreak = _menuWalkHoldStreak + 1
        return nil
    end
    _menuWalkHoldStreak = 0
    if Trackers.onMainMenu and prev > 0 and swing ~= 0 and menuWalkBlockStreak < 8 then
        menuWalkBlockStreak = menuWalkBlockStreak + 1
        return nil
    end
    menuWalkBlockStreak = 0

    -- MIGAJA FINA (07-26): el walk completo sobre la escena del menÃº (~1762 widgets) es el candidato mÃ¡s
    -- caro del residual del menÃº principal, y estÃ¡ declarado como riesgo ACEPTADO en la nota de arriba
    -- ("el crash del menÃº principal vuelve a ser residual intermitente"). Marcarlo aparte permite que el
    -- PRÃ“XIMO crash distinga el WALK del atajo de botones, sin tener que adivinar. Casi no cuesta: en el
    -- menÃº sano el atajo halla el botÃ³n enfocado y retorna ANTES de llegar aquÃ­, asÃ­ que esta escritura
    -- solo ocurre en el hueco del desmontaje, que es justo el instante que queremos fichar.
    if Trackers.onMainMenu then Crumb("F:menuwalk") end

    -- === FRENO DEL WALK POR MUERTE DEL FOCO (07-28). CON DATO ===
    -- Crash al entrar al torneo: migaja `F:pf-fast` y, en la lÃ­nea inmediatamente anterior del livelog, un
    -- atasco de **3.02s en `scan-findall`** â€” la enumeraciÃ³n de aquÃ­ abajo â€” con el conteo saltando de 1758
    -- a 695. En esa sesiÃ³n `scan-findall` acumulÃ³ 89 atascos, el grupo mÃ¡s grande.
    -- POR QUÃ‰ EL FRENO DE CHURN NO LLEGÃ“ A TIEMPO: desde que el foco dejÃ³ de enumerar por su cuenta, el
    -- churn lo detecta el bucle de POLL, que va a 100ms. El foco va a 16ms, asÃ­ que tiene ~6 vueltas de
    -- ventaja antes de que el poll se entere y arme el freno. En una de esas vueltas enumerÃ³ y muriÃ³.
    -- LA SEÃ‘AL QUE SÃ LLEGA A TIEMPO: que el widget que tenÃ­a el foco haya MUERTO. Eso lo detecta el propio
    -- foco, en el mismo tick, con un `IsValidRef` que ya hacÃ­a. Si el foco acaba de morir, la pantalla se
    -- estÃ¡ yendo: no hay NADA que leer y caminar 2000 widgets moribundos es puro riesgo.
    -- Medio segundo basta para que el poll se entere y arme el freno de churn de verdad. Y es fail-safe:
    -- pasado ese tiempo el walk vuelve a estar disponible, asÃ­ que no puede enmudecer nada.
    if (os.clock() - _focusDiedAt) < 0.5 then return nil end

    -- AquÃ­ SÃ hace falta la lista de verdad. Si este tick no la enumerÃ³ (throttle de arriba), se pide
    -- ahora: la enumeraciÃ³n cara solo se paga cuando se va a USAR, no en los ticks que resuelve un atajo.
    if not allWidgets then
        _focusStage = "scan-findall"
        local okW, wAll = pcall(FindAllOf, "UserWidget")
        if not okW or not wAll then return nil end
        allWidgets = wAll
        -- AQUÃ NO SE ESCRIBE `lastWidgetCount` (07-28). ERA EL SEGUNDO ESCRITOR Y CAUSABA VENTANAS FALSAS.
        -- La auditorÃ­a multiagente lo localizÃ³ como CAUSA RAÃZ COMÃšN de los tres sÃ­ntomas: `lastWidgetCount`
        -- tenÃ­a DOS dueÃ±os con valores distintos â€” este conteo FRESCO del walk, y el que publica el poll
        -- (`Trackers.widgetCount`), que desde hoy se CONGELA durante todo el churn porque el poll dejÃ³ de
        -- contar. El churn guard comparaba uno contra otro, asÃ­ que la resta salÃ­a de cientos o miles sin
        -- que hubiera pasado nada, y armaba ventanas de 2.0s (3.0s en zona de peligro) una detrÃ¡s de otra.
        -- MEDIDO en el livelog: "UI churn guard: 1777 -> 860 (3.0s)" y "860 -> 1777 (3.0s)" en 11 segundos,
        -- y un 78% de churn=true justo en los momentos en que habla el presentador del torneo. Eso es lo
        -- que dejÃ³ mudos sus subtÃ­tulos: `PollCutsceneText` corre detrÃ¡s de `uiChurnUntil`.
        -- Con un solo dueÃ±o (el poll), prev y count vienen siempre de la misma fuente y un salto solo puede
        -- ser un salto de verdad. La lista sigue usÃ¡ndose aquÃ­ para el walk; simplemente ya no se publica.
    end

    -- A partir de aquÃ­ SÃ se mira de verdad la pantalla entera: si no se encuentra nada, es que
    -- realmente no hay nada enfocado y PollFocus puede limpiar el dedup con razÃ³n.
    _scanReachedWalk = true
    _focusStage = "scan-full"; _focusScanTotal = #allWidgets
    for i = 1, #allWidgets do
        _focusScanIdx = i
        local w = allWidgets[i]
        if IsValidRef(w) then
            -- Re-validate INSIDE the pcall, immediately before the native HasKeyboardFocus call.
            -- On the tournament team/roster select a widget can be freed in the gap between the
            -- IsValidRef above and the call below (the fundamental F:pollfocus race â€” invisible to
            -- the count guards because the total stays stable when a single widget dies). This
            -- second check narrows that window to the smallest it can be from Lua. It does NOT close
            -- it â€” pcall can't catch a native access violation or hang â€” but it makes the crash
            -- markedly rarer. Nothing is removed, so it can't silence any reading.
            local fok, focused = pcall(function()
                if not IsValidRef(w) then return false end
                return w.HasKeyboardFocus and w:HasKeyboardFocus()
            end)
            if fok and focused then
                -- EL WALK TAMBIÃ‰N ALIMENTA LA SONDA DE VIDA DEL MENÃš (07-28). IvÃ¡n: al volver al MENÃš DEL
                -- TORNEO el lector se quedaba MUDO. La auditorÃ­a lo explicÃ³: sus botones son
                -- `WBP_OBJ_OLB_MenuBTN_C`, que NO estÃ¡ en `menuFastClasses` ni en ningÃºn atajo, asÃ­ que esa
                -- pantalla depende del walk al cien por cien. Y mi bloqueo del walk solo se abre si
                -- `_menuLooksAlive` es true, que hasta ahora solo podÃ­a ponerse cuando el ATAJO acertaba â€”
                -- cosa que allÃ­ no pasa NUNCA. Resultado: bloqueo permanente y pantalla muda.
                -- Guardando aquÃ­ el widget, la primera vuelta que el walk consiga correr deja la sonda
                -- cargada y el bloqueo se abre solo. NO se toca `_lastMenuFastHitClock`, que debe seguir
                -- sellÃ¡ndose Ãºnicamente con las clases del menÃº principal (si no, se falsearÃ­a la ventana
                -- de salida del menÃº). Y NO se crece `menuFastClasses` (LECCIÃ“N 15).
                if Trackers.onMainMenu then _lastMenuFastWidget = w end
                return w
            end
        end
    end
    return nil
end

local function PollFocus()
    _focusStage = "pf-pausecheck"
    -- Cooldown: skip UObject access to let game finish destroying widgets
    if slowPathCooldown > 0 then
        slowPathCooldown = slowPathCooldown - 1
        return
    end

    -- Determine if the focus scan must pause, and WHY (diagnostic). Reasons, in order:
    --   transition  â€” dialog dismissed / map loading (transitionCooldownUntil)
    --   churn       â€” UI rebuild in progress (uiChurnUntil)
    --   cutscene    â€” story-cutscene focus-only pause (focusPauseUntil)
    --   eventSkip   â€” a cutscene SKIP prompt is on screen (cinematic churning)
    -- The eventSkip / cutscene pauses protect the fast path from reading a cached menu widget
    -- mid-teardown (crumb F:pollfocus). DIAG (temporary): log the reason once per change so we can
    -- see WHY the pause menu doesn't read in some story scenes.
    -- Is the PAUSE MENU open? Confirmed via diag that WBP_EventPause_C:IsVisible reliably flips
    -- (Y when open, N when closed). If open, the game is PAUSED (frozen) and stable, and the user
    -- needs the menu read â€” so IGNORE ALL the focus pauses, including churn/transition. Previously we
    -- kept churn/transition "for the pause-open rebuild", but that backfired: pausing DURING a
    -- special move (Genkidama) armed a 2-3s churn guard that persisted into the freeze and left the
    -- pause menu SILENT until it expired (IvÃ¡n: "no reaccionaba el menÃº de pausa... luego funcionaba").
    -- The game is frozen while paused, so those guards are stale; the only churn is the pause menu's
    -- own CONSTRUCTION (adding widgets, not tearing a scene down), which the per-widget IsValidRef in
    -- ScanForFocus handles. Reading a frozen pause menu is safe.
    -- Â¿MENÃš PRINCIPAL? Se computa PRIMERO. Si sÃ­, SE SALTA toda la tanda de chequeos de pausa de
    -- BATALLA (pc1-pc5): son widgets de PELEA que en el menÃº no aplican, y sus IsVisible sobre la escena
    -- del demo (que churnea) son los que TRUENAN (F:pollfocus al volver al menÃº, 07-20). En el menÃº el
    -- foco hace SOLO el atajo de botones + return-nil. La banderita la leen los lectores de subtÃ­tulos.
    local onMainMenu = H.GetCachedFirstOf("WBP_MainMenu_ModeMenu_C") and true or false
    -- FLANCO DE ENTRADA AL MENÃš (07-27). IvÃ¡n: al salir de la Enciclopedia, el menÃº tarda casi 5 segundos
    -- en decirle "Enciclopedia". MEDIDO en el livelog: salida de la galerÃ­a a las 15:09:21, el menÃº acaba
    -- de montarse a las 15:09:24 (3s que son del JUEGO cargando, no del mod) y ahÃ­ se arma la ventana de
    -- churn de 2.0s. Encima, el enfriamiento del atajo venÃ­a cargado de la racha de fallos del
    -- desmontaje anterior y sumaba hasta 0.8s MÃS sobre un menÃº que ya estaba montado y sano.
    -- Ese Ãºltimo tramo sÃ­ es puro desperdicio: cuando el menÃº REAPARECE, la racha de fallos vieja ya no
    -- significa nada. Se limpia en el flanco. Ahorra hasta 0.8s de los ~5, sin tocar ningÃºn freno de
    -- seguridad (los otros 2 segundos son el escudo anti-crash de la reconstrucciÃ³n y NO se toca aquÃ­).
    if onMainMenu and not _prevOnMainMenu then
        _menuFastMissUntil = 0
        _menuFastMissStreak = 0
        _menuWalkHoldStreak = 0
    end
    _prevOnMainMenu = onMainMenu
    Trackers.onMainMenu = onMainMenu
    if onMainMenu then _lastOnMainMenuClock = os.clock() end  -- marca de tiempo para la ventana de SALIDA de menÃº
    -- Â¿ENCICLOPEDIA (pantalla "Gallery")? Medido 07-20: las 5 muertes del bucle de foco de esa sesiÃ³n
    -- cayeron TODAS en la ventana de la Enciclopedia y TODAS en el atajo CACHEADO (pf-fastpath 3,
    -- pf-fp-haskbf 2) = la lentitud que reporta IvÃ¡n al navegar con las flechas. Es EL MISMO mecanismo
    -- que causaba el lag de 2-3s por opciÃ³n en el menÃº principal, resuelto saltando el atajo cacheado.
    -- Se aplica aquÃ­ el mismo patrÃ³n ya probado. SEÃ‘AL VERIFICADA en el volcado (no supuesta):
    -- WBP_GRP_Gallery_PictureBook_C aparece en 12 entradas y NUNCA coexiste con los botones del menÃº
    -- principal ni con HitButton (pelea/char-select) â€” exclusividad limpia. UNA sola consulta por tick
    -- a propÃ³sito: inflar el nÃºmero de consultas del hot path fue lo que disparÃ³ los cuelgues cuando
    -- crecÃ­ menuFastClasses. Saltar el atajo NO enmudece: cae al escaneo fresco de ScanForFocus.
    local onGallery = H.GetCachedFirstOf("WBP_GRP_Gallery_PictureBook_C") and true or false
    -- VENTANA DE SALIDA DE LA ENCICLOPEDIA (07-27). CRASH F:pollfocus AL SALIR de la Enciclopedia al
    -- menÃº, con `onMainMenu=false` (la migaja nueva por bucle lo confirmÃ³: foco=F:pollfocus SIN el
    -- sufijo `:menu`, poll=P:done o sea el poll habÃ­a terminado limpio, dump=D:off o sea el volcado
    -- estaba apagado). ASIMETRÃA QUE LO CAUSABA: `onGallery` salta el atajo cacheado MIENTRAS estÃ¡s
    -- dentro, pero en cuanto sales, el widget de la galerÃ­a desaparece, `onGallery` cae a false y el
    -- atajo se REACTIVA sobre `lastFocusedWidget`, que es un widget DE LA GALERÃA en pleno teardown =>
    -- HasKeyboardFocus sobre Ã©l truena. Es EXACTAMENTE el mismo mecanismo (y el mismo fix) que ya se
    -- aplicÃ³ el 07-21 a la salida del MENÃš con `justLeftMenu`; simplemente faltaba el simÃ©trico aquÃ­.
    -- Respaldo histÃ³rico: el 07-20 se midiÃ³ que las 5 muertes del foco de aquella sesiÃ³n cayeron TODAS
    -- en la ventana de la Enciclopedia y TODAS en el atajo cacheado (pf-fastpath 3, pf-fp-haskbf 2).
    -- El reloj se sella aquÃ­ y TAMBIÃ‰N mientras el bucle estÃ¡ congelado (ver el gate del focus loop),
    -- porque si no la ventana envejecerÃ­a durante el freno sin haber protegido nada (LECCIÃ“N 16).
    Trackers.onGallery = onGallery
    if onGallery then _lastOnGalleryClock = os.clock() end
    local justLeftGallery = (not onGallery) and (os.clock() - _lastOnGalleryClock) < 2.5
    -- VENTANA DE SALIDA DE MENÃš: se calcula AQUÃ (antes se calculaba 138 lÃ­neas mÃ¡s abajo y por eso NO
    -- protegÃ­a la tanda de pause-checks de justo debajo).
    local justLeftMenu = (os.clock() - _lastOnMainMenuClock) < 2.5
    local pauseMenuOpen, onSkillList, onResultScreen = false, false, false
    -- `and not justLeftMenu` (07-22): CRASH F:pollfocus al entrar a HISTORIA desde el menÃº (y antes a la
    -- Enciclopedia). CAUSA REAL (no "hay que esperar mÃ¡s"): mientras estÃ¡s en el menÃº, toda esta tanda de
    -- PAUSE-CHECKS se salta por `not onMainMenu`; en cuanto onMainMenu cae (transiciÃ³n), se REACTIVA DE
    -- GOLPE y hace IsVisible sobre widgets de pausa/resultado que estÃ¡n naciendo/muriendo => truena. Y el
    -- diagnÃ³stico del 07-19 (_focusStage) ya habÃ­a medido que el foco NO muere en el recorrido de widgets
    -- sino EN ESTOS PAUSE-CHECKS (13/14 muertes). Saltarlos durante la ventana de salida ataca la causa
    -- SIN frenar la lectura: el foco sigue leyendo normal (fast-path/walk), solo se omiten estos IsVisible.
    -- COSTO REAL Y MÃNIMO: durante 2.5s tras dejar el menÃº no se detecta un menÃº de PAUSA â€” y saliendo del
    -- menÃº principal no hay ninguno (la pausa aparece dentro de una partida, no en esa transiciÃ³n).
    -- === ENFRIAMIENTO DE LA TANDA DE PAUSE-CHECKS (07-27 noche). CON DATO ===
    -- Crash al pasar a otra batalla en el torneo: migaja `F:pf-checks` (o sea AQUÃ) y las Ãºltimas ocho
    -- lÃ­neas del livelog son atascos de **1.18 a 1.20s en `pf-pc5-result-vis`, uno detrÃ¡s de otro**. En el
    -- reparto de esa sesiÃ³n: 27 atascos en `pf-pc5-result-vis` + 16 en `pf-pausecheck`.
    -- EL DERROCHE: esta tanda son CINCO comprobaciones en cadena, y solo se detiene cuando una acierta.
    -- Durante una batalla normal â€”sin pausaâ€” ninguna acierta, asÃ­ que se pagaban las cinco ENTERAS 62
    -- veces por segundo, y cada `IsVisible` sobre un contenedor de batalla puede tardar mÃ¡s de un segundo.
    -- NO se cambia CÃ“MO se comprueba (la LECCIÃ“N 1 es tajante: meter `SafeIsVisible` aquÃ­ disparÃ³ 224
    -- colgones en julio y se revirtiÃ³). Se cambia CADA CUÃNTO, que es la tÃ©cnica que hoy ya funcionÃ³ dos
    -- veces (`scan-gallery` 819->7, `scan-option` 200->2).
    -- SOLO SE ENFRÃA SI NO ENCONTRÃ“ NADA. Si hay un menÃº de pausa abierto, la tanda sigue corriendo cada
    -- tick para que el estado no oscile y la pantalla se lea estable. El Ãºnico coste es que abrir la pausa
    -- puede tardar hasta 0.3s en detectarse â€” y estando el juego congelado ahÃ­, eso no pierde nada.
    -- Se limpia con cualquier churn (cambio de pantalla), como el resto de enfriamientos.
    if os.clock() < uiChurnUntil then _pauseChecksMissUntil = 0 end
    if not onMainMenu and not justLeftMenu and os.clock() >= _pauseChecksMissUntil then
    -- MIGAJA FINA (07-27): esta tanda se lleva 13 de cada 14 muertes histÃ³ricas del foco, pero la migaja
    -- decÃ­a solo "F:pollfocus" y no distinguÃ­a tramos. Con esta marca, el prÃ³ximo crash dirÃ¡ si cayÃ³ AQUÃ
    -- o mÃ¡s adelante. Es UNA escritura mÃ¡s por tick y SOLO cuando la tanda se ejecuta de verdad (en el
    -- menÃº y en su ventana de salida se salta entera, asÃ­ que ahÃ­ no cuesta nada).
    Crumb("F:pf-checks")
    _focusStage = "pf-pc1-eventpause-find"
    local pvw = H.GetCachedFirstOf("WBP_EventPause_C")
    _focusStage = "pf-pc1-eventpause-vis"
    pauseMenuOpen = pvw and TryCall(pvw, "IsVisible") and true or false
    -- The in-BATTLE pause menu is a DIFFERENT widget: WBP_Pause_C (confirmed in the F5 dump â€” it
    -- holds ResumeButton "Continuar", RetryButton "Reintentar", OptionButton "Opciones", QuitButton,
    -- BattleDetailsButton...). WBP_EventPause_C is only the story/cutscene pause. So the battle pause
    -- menu wasn't being detected and the focus guards kept it silent (IvÃ¡n: "no me lee bien el menÃº
    -- de pausa en la batalla"). Check both.
    if not pauseMenuOpen then
        _focusStage = "pf-pc2-battlepause-find"
        local bpv = H.GetCachedFirstOf("WBP_Pause_C")
        _focusStage = "pf-pc2-battlepause-vis"
        pauseMenuOpen = bpv and TryCall(bpv, "IsVisible") and true or false
    end
    -- The in-battle COMMAND LIST / moves menu (opened from the pause menu) is ANOTHER frozen,
    -- navigable menu: its skill items (Content_Skill_S1/S2/UB... under WBP_GRP_SL_Main_0_C) DO take
    -- keyboard focus (confirmed in F5), but navigating them churns widgets, and since the battle is
    -- still "active" the danger-zone logic armed a long churn window that paused the focus scan â€” so
    -- the focused skill never got read (IvÃ¡n: "me muevo con el joystick dentro de las opciones y ya
    -- no las lee"). The game is FROZEN while paused, so treat this like the pause menu: read it,
    -- ignore the (stale) guards. Also covers the customization skill list (same container).
    if not pauseMenuOpen then
        _focusStage = "pf-pc3-skilllist-find"
        local slv = H.GetCachedFirstOf("WBP_GRP_SL_Main_0_C")
        _focusStage = "pf-pc3-skilllist-vis"
        if slv and TryCall(slv, "IsVisible") then
            pauseMenuOpen = true
            onSkillList = true
        end
    end
    -- BATTLE DETAILS (pause menu -> "Detalles de batalla") is a THIRD frozen, navigable screen, and
    -- it REPLACES the pause menu rather than drawing on top of it: the F5 taken right on that screen
    -- (entry 86) shows WBP_Pause_Requirement_C + WBP_OBJ_Pause_Requirement_List_C visible and
    -- WBP_Pause_C ABSENT. So none of the checks above matched, pauseMenuOpen stayed false, the focus
    -- guards kept running and the screen read late / not at all (IvÃ¡n: "da tirÃ³n... entrÃ© a detalles
    -- de batalla, que antes sÃ­ leÃ­a y ahora no"; the diag logged "focus paused: cutscene pauseVis=N"
    -- while he was sitting on it). The game is FROZEN here, same as the pause menu and the command
    -- list, so treat it the same: read it, ignore the stale guards.
    if not pauseMenuOpen then
        _focusStage = "pf-pc4-details-find"
        local rqv = H.GetCachedFirstOf("WBP_Pause_Requirement_C")
        _focusStage = "pf-pc4-details-vis"
        pauseMenuOpen = rqv and TryCall(rqv, "IsVisible") and true or false
    end
    -- The battle RESULT screen (game-over/victory after a battle) is a frozen, navigable menu
    -- (Reintentar / Salir) that KEEPS THE BATTLE SCENE CHURNING behind it, so the churn/cutscene
    -- guards paused the focus and this menu went unread (IvÃ¡n 07-19: "el menÃº de reintentar no lee").
    -- Treat it like the pause menu â€” bypass the guards â€” and let ScanForFocus's dedicated result
    -- fast-path scan ONLY its buttons (never the churning scene). WBP_GRP_BS_Result_02_DP_C is its
    -- root (F5: BTN_1 "Reintentar", BTN_2 "Salir", both WBP_OBJ_BS_BTN_Result_1_C). Same TryCall
    -- pattern as the checks above (NOT SafeIsVisible â€” that IsValid hangs on teardown widgets).
    if not pauseMenuOpen then
        _focusStage = "pf-pc5-result-find"
        local rsv = H.GetCachedFirstOf("WBP_GRP_BS_Result_02_DP_C")
        _focusStage = "pf-pc5-result-vis"
        if rsv and TryCall(rsv, "IsVisible") then
            pauseMenuOpen = true
            onResultScreen = true
        end
    end
    -- Ninguna de las cinco pantallas de pausa estÃ¡ presente => no insistir 62 veces por segundo. Si sÃ­ la
    -- hay, NO se enfrÃ­a: la tanda sigue cada tick para que el estado se mantenga estable (ver la nota).
    if not pauseMenuOpen then _pauseChecksMissUntil = os.clock() + 0.3 end
    end  -- cierra el "if not onMainMenu": en el menÃº se salta toda la tanda de chequeos de pausa

    -- Arma la ventana de pausa que episode_battle.PollCutsceneText usa para RETENER el
    -- dedup de subtÃ­tulos (evita re-leer la lÃ­nea al despausar). Ventana temporizada =
    -- FAIL-SAFE (LECCIÃ“N 11): si este bucle muere, expira y todo vuelve a lo normal. La
    -- gracia de 1.0s cubre ademÃ¡s el flanco de SALIDA (la lÃ­nea que reaparece al despausar).
    -- No calla barks: se probÃ³ que 0 barks caen en pausa (ver Trackers.pauseSeenUntil).
    if pauseMenuOpen then
        Trackers.pauseSeenUntil = os.clock() + 1.0
    end

    local pauseReason = nil
    if not pauseMenuOpen and os.clock() < Trackers.transitionCooldownUntil then pauseReason = "transition"
    elseif not pauseMenuOpen and os.clock() < uiChurnUntil then pauseReason = "churn"
    elseif not pauseMenuOpen and os.clock() < focusPauseUntil then pauseReason = "cutscene"
    -- Robust story-cutscene guard set by the poll-loop cutscene readers (reliable direct detection),
    -- covering the quiet gaps where the local eventSkip check went nil and the scan crashed.
    elseif not pauseMenuOpen and os.clock() < Trackers.cutsceneGuardUntil then pauseReason = "cutscene"
    elseif not pauseMenuOpen and not onMainMenu then
        -- pc6: en el MENÃš PRINCIPAL NO checar el prompt de skip (su IsVisible sobre la escena del demo
        -- tambiÃ©n truena); el demo se maneja con la banderita en los lectores de subtÃ­tulos.
        _focusStage = "pf-pc6-eventskip-find"
        local sk = H.GetCachedFirstOf("WBP_GRP_AI_EventSkip_C")
        _focusStage = "pf-pc6-eventskip-vis"
        if sk and TryCall(sk, "IsVisible") then pauseReason = "eventSkip" end
    end
    if pauseReason then
        local tag = pauseReason .. (pauseMenuOpen and " pauseVis=Y" or " pauseVis=N")
        if tag ~= lastFocusPauseReason then
            lastFocusPauseReason = tag
            print("[AE-DIAG] focus paused: " .. tag)
        end
        if lastFocusedWidget then
            lastFocusedWidget = nil
            lastFocusedName = nil
            lastSpokenLabel = nil
            lastMatchedLabelWidget = nil
        end
        focusEmptyScanStreak = 0
        return
    elseif lastFocusPauseReason then
        local wasReason = lastFocusPauseReason
        lastFocusPauseReason = nil
        print("[AE-DIAG] focus resumed")
        -- RESUME SETTLE: a pause ending can be part of a scene TEARDOWN â€” the widget tree may still
        -- be freeing at that instant, and resuming the focus scan right then walked the freeing
        -- widgets and crashed natively (crumb F:pollfocus). So skip the focus SCAN for ~0.5s (30 x
        -- 16ms) via slowPathCooldown to let the teardown finish. It MUST be slowPathCooldown, not the
        -- shared uiChurnUntil (which would make the next tick's reason "churn" and re-arm here forever,
        -- freezing the reader â€” that regression actually happened).
        --
        -- But apply it ONLY when the pause we're leaving was teardown-adjacent, decided by the pause
        -- REASON (not by which screen we're on): a cutscene / skip-prompt / transition ALWAYS tears
        -- down; a plain "churn" pause only tears down in a danger zone (battle/story). A cosmetic
        -- churn on a menu or the Episode-Battle character-select is NOT teardown, and settling there
        -- made Goku/Vegeta slow to read after each move (the "molesta" lag). Keying on the reason
        -- fixes both: the cutscene-entry crash (reason "cutscene" -> settle) AND select navigation
        -- (reason "churn", not in danger -> no settle -> snappy). Pause menu open = stable, never settle.
        local teardownExit = wasReason:find("cutscene", 1, true) or wasReason:find("eventSkip", 1, true)
                             or wasReason:find("transition", 1, true) or InDangerZone()
        if not pauseMenuOpen and teardownExit then
            slowPathCooldown = 30
            return
        end
    end

    -- Fast path: check if cached focused widget still has focus. SKIP on the result screen: its buttons
    -- churn with the scene behind them, so the cached HasKeyboardFocus check HANGS (~1.5s each â€” the 2-3s
    -- lag IvÃ¡n felt, 07-19). Going straight to ScanForFocus's cheap result fast-path (fresh scan of the 2
    -- stable buttons) avoids it.
    -- SALIDA DE MENÃš (07-21): al entrar del menÃº principal a la Enciclopedia (u otro sub-mundo), onMainMenu
    -- cae a false y este atajo cacheado se reactiva sobre `lastFocusedWidget`, que ES el botÃ³n del menÃº
    -- (WBP_OBJ_MainMenu_BTN_Sub1) EN TEARDOWN => HasKeyboardFocus sobre Ã©l TRUENA (F:pollfocus, verificado
    -- en dump_crash_entrada: Ãºltimo foco = MainMenu_BTN_Sub1). La ventana de salida de menÃº (justLeftMenu)
    -- ya frena el CHURN GUARD, pero este atajo corre ANTES. Durante 2.5s tras dejar el menÃº NO usar el
    -- atajo cacheado (su ref es del menÃº muerto): cae a ScanForFocus, cuyo churn guard frena con ventana larga.
    -- (justLeftMenu ya se calculÃ³ arriba, antes de los pause-checks â€” se reutiliza aquÃ­.)
    -- MIGAJA FINA (07-27): pasada esta marca, los pause-checks YA quedaron atrÃ¡s sin tronar. Si un crash
    -- deja `F:pf-fast`, el culpable es el atajo cacheado o el escaneo de ScanForFocus, no la tanda.
    Crumb("F:pf-fast")
    _focusStage = "pf-fastpath"
    if lastFocusedWidget and not onResultScreen and not onSkillList and not onMainMenu and not onGallery
       and not justLeftMenu and not justLeftGallery then
        _focusStage = "pf-fp-isvalid"  -- DIAG fino: Â¿se cuelga en el IsValidRef del widget cacheado?
        if not IsValidRef(lastFocusedWidget) then
            -- Widget destroyed â€” clear refs, fall through to slow path
            -- No cooldown needed: IsValid() caught it safely
            -- SELLO DE MUERTE DEL FOCO (07-28): que el widget que tenÃ­a el foco haya MUERTO es la seÃ±al mÃ¡s
            -- barata y mÃ¡s temprana de que la pantalla se estÃ¡ yendo. Se apunta la hora para que el walk no
            -- se lance justo ahÃ­ (ver el freno antes del walk). Cero llamadas nuevas: este `IsValidRef` ya
            -- se hacÃ­a.
            _focusDiedAt = os.clock()
            lastFocusedWidget = nil
            lastFocusedName = nil
            lastSpokenLabel = nil
            lastMatchedLabelWidget = nil
        else
            _focusStage = "pf-fp-haskbf"  -- DIAG fino: Â¿o en el HasKeyboardFocus?
            local ok, stillFocused = pcall(function()
                return lastFocusedWidget:HasKeyboardFocus()
            end)

            if not ok then
                -- pcall caught error after IsValid passed â€” enter brief cooldown
                print("[AE] Stale widget after IsValid, brief cooldown")
                lastFocusedWidget = nil
                lastFocusedName = nil
                lastSpokenLabel = nil
                lastMatchedLabelWidget = nil
                    TeamOV.InvalidateCache()
                Roster.InvalidateCache()
                slowPathCooldown = 6 -- 6 x 16ms = ~100ms
                return
            end

            if stillFocused then
                -- Room ID digit change polling (cached TXT_Num TextBlock ref)
                if lastScreenContext == "roomid" and IsValidRef(lastMatchedLabelWidget) then
                    local ok, gt = pcall(function() return lastMatchedLabelWidget:GetText() end)
                    if ok and gt then
                        local newDigit = TryCall(gt, "ToString")
                        if newDigit and newDigit ~= lastCaptionValue then
                            lastCaptionValue = newDigit
                            Speak(newDigit, true)
                        end
                    end
                -- Focus unchanged â€” check caption value changes (D-pad left/right)
                elseif lastCaptionRef and IsValidRef(lastCaptionRef) then
                    local ok, gt = pcall(function() return lastCaptionRef:GetText() end)
                    if ok and gt then
                        local newCaption = TryCall(gt, "ToString")
                        if newCaption and newCaption ~= lastCaptionValue then
                            lastCaptionValue = newCaption
                            Speak(newCaption, true)
                        end
                    end
                end
                -- Texture-based roster reading is per-button, no polling needed
                return
            end

            -- Focus moved â€” clear cached widget, fall through to slow path
            lastFocusedWidget = nil
        end
    end

    -- Slow path: single FindAllOf("UserWidget") scan.
    -- Throttle: after 6 consecutive empty scans (~100ms) drop to 1-in-6 cadence
    -- so we don't burn 60Hz GUObjectArray walks on screens that genuinely have
    -- no focusable widget (cutscene fades, animations, brief dialog gaps).
    -- Reset to full cadence the moment focus reappears.
    if focusEmptyScanStreak >= 6 and (focusEmptyScanStreak % 6) ~= 0 then
        focusEmptyScanStreak = focusEmptyScanStreak + 1
        return
    end

    local focused = ScanForFocus()
    if focused then
        focusEmptyScanStreak = 0
        OnWidgetFocused(focused)
        return
    end

    -- El escaneo se cortÃ³ por un FRENO (settle, enfriamiento, espera, bloqueo del walk...): eso significa
    -- "no he mirado", NO "no hay foco". Borrar el dedup aquÃ­ es lo que hacÃ­a repetir la opciÃ³n al quedarse
    -- parado (07-27). Se sale sin tocar nada; el estado sigue siendo vÃ¡lido.
    if not _scanReachedWalk then return end

    focusEmptyScanStreak = focusEmptyScanStreak + 1
    -- Nothing focused
    if lastFocusedName ~= nil then
        lastFocusedName = nil
        lastFocusedWidget = nil
        lastSpokenLabel = nil
    end
end

-- === MAIN LOOP ===

local focusLoopHeartbeat = 0
local pollLoopHeartbeat = 0

local function ResetStaleState(preserveDedup)
    -- preserveDedup (07-20): el watchdog reinicia el foco tras un cuelgue; si borra el dedup de "quÃ©
    -- acabo de decir" (lastSpokenLabel/lastFocusedName), el siguiente escaneo RE-LEE el Ã­tem donde el
    -- usuario estÃ¡ parado (la repeticiÃ³n que oÃ­a IvÃ¡n: "repite el nombre de donde estoy parado"). Con
    -- preserveDedup=true conservamos ese dedup para NO re-anunciar el mismo Ã­tem. lastFocusedWidget SÃ
    -- se limpia siempre (la ref puede estar muerta); si el usuario se moviÃ³ durante el cuelgue, el
    -- nuevo Ã­tem tiene otra etiqueta y se anuncia igual. Solo lo usa el reinicio del watchdog.
    -- AMPLIADO 07-20: preservar lastSpokenLabel/lastFocusedName no bastaba. El watchdog seguÃ­a
    -- borrando el dedup de los OTROS lectores (barra de guÃ­a, char-select de Episodio, Tienda,
    -- tÃ­tulos de lista), asÃ­ que cada reinicio re-anunciaba la pantalla entera CON INTERRUPCIÃ“N y
    -- se comÃ­a la descripciÃ³n. Medido: 8 reinicios = 8 veces "Episode Battle" + la barra de
    -- controles + "Goku". Regla: en un reinicio se limpian las REFERENCIAS (pueden estar muertas)
    -- pero NUNCA el dedup de "quÃ© acabo de decir" â€” el usuario no se moviÃ³, no hay nada nuevo que
    -- anunciar. Si sÃ­ se moviÃ³ durante el cuelgue, el texto cambia y se anuncia solo.
    if not preserveDedup then
        lastFocusedName = nil
        lastSpokenLabel = nil
        lastGuideMessage = nil
        lastListTitle = nil
        lastCaptionValue = nil
        lastAnnouncedDialogId = nil
        lastOptionsTip = nil
        lastCharaName = nil
    end
    -- Referencias y cachÃ©s: SIEMPRE se limpian (una ref muerta cuelga la siguiente lectura nativa).
    lastFocusedWidget = nil
    lastMatchedLabelWidget = nil
    lastCaptionRef = nil
    focusEmptyScanStreak = 0
    teamSlotPollFrames = 0
    roomIdDigitRefs = {}
    TeamOV.InvalidateCache()
    Roster.InvalidateCache()
    EpisodeBattle.Reset(preserveDedup)
    Shop.Reset(preserveDedup)
    if not preserveDedup then Gallery.Reset() end  -- limpia el dedup del personaje (no en reinicio del watchdog)
end

-- Quick world liveness check â€” if this fails, we're in a transition.
-- GameInstance is a process-lifetime singleton, so we cache it and only
-- re-fetch when IsValidRef reports the cached ref is dead. This avoids a
-- full GUObjectArray scan every loop tick (previously 120/sec across both
-- loops).
local _cachedGameInstance = nil

local function IsWorldAlive()
    if _cachedGameInstance and IsValidRef(_cachedGameInstance) then
        return true
    end
    _cachedGameInstance = nil
    local ok, gi = pcall(FindFirstOf, "GameInstance")
    if ok and gi then
        _cachedGameInstance = gi
        return true
    end
    return false
end

-- === MAP TRANSITION DETECTION (polling â€” no LoadMap hooks) ===
-- We used to pause the loops and reset state via RegisterLoadMapPre/PostHook,
-- but those native engine hooks crash the current game build on the first map
-- load. Instead we poll the current World's identity every tick. GameInstance
-- is a process-lifetime singleton (never changes), but the World is torn down
-- and rebuilt on a real map load â€” exactly the transition signal we want.
-- All access is pcall + IsValid, so a stale ref mid-transition degrades to a
-- skipped tick, never a crash.
local _cachedWorld = nil
local _cachedWorldName = nil    -- name paired with _cachedWorld (see CurrentWorldName)
local _lastWorldName = nil
local _worldWasLost = false
local _pendingWorldName = nil  -- a differing World we're waiting to confirm
local _pendingSince = 0

-- Read the current game World's identity (its GetFullName), or nil if none is
-- live right now. Caches the World object AND its name.
local function CurrentWorldName()
    -- If the cached World is still alive, its identity (GetFullName) has NOT changed â€” a World's
    -- full name is stable for its whole lifetime â€” so return the STORED name WITHOUT calling
    -- GetFullName again. This is the crash fix for crumb P:worldtrans: the old code called
    -- GetFullName on the cached World every throttled tick, and during a real map load that World is
    -- mid-teardown (IsValidRef can still say "valid" for a stale ref), so the native read crashed.
    -- Now GetFullName runs only ONCE per World â€” when a NEW one is first found â€” after the old one
    -- has already been torn down (which is exactly the transition we detect). Correctness is
    -- unchanged: a map load invalidates this ref, we then find the new World and its new name.
    if _cachedWorld and _cachedWorldName and IsValidRef(_cachedWorld) then
        return _cachedWorldName
    end
    _cachedWorld = nil
    _cachedWorldName = nil
    local ok, world = pcall(FindFirstOf, "World")
    if ok and world and IsValidRef(world) then
        local nok, n = pcall(function() return world:GetFullName() end)
        if nok and n then
            _cachedWorld = world
            _cachedWorldName = n
            return n
        end
    end
    return nil
end

local _worldCheckAt = 0
local function CheckWorldTransition()
    -- THROTTLE: this reads the game World object (FindFirstOf + GetFullName), and during a real map
    -- LOAD that object is being torn down/rebuilt â€” the native read then crashes (crumb P:worldtrans,
    -- seen loading into the Majin-Vegeta battle). It ran every tick of BOTH loops (~70Ã—/s), so every
    -- load had ~70 chances to hit the teardown. Map changes take seconds, so ~7Ã—/s (150ms) detects
    -- them just as well while cutting the crash exposure ~10Ã—. Shared across both loops.
    if os.clock() - _worldCheckAt < 0.15 then return end
    _worldCheckAt = os.clock()

    local wname = CurrentWorldName()

    if not wname then
        -- No live World this tick (brief mid-load). Drop cached singleton refs
        -- once, but do NOT pause the loops: story cutscenes make FindFirstOf
        -- ("World") flicker empty for long stretches while still showing dialog,
        -- and pausing here muted the reader for the whole scene. The pollers are
        -- IsValidRef/pcall-guarded, so reading straight through is safe.
        if _lastWorldName ~= nil and not _worldWasLost then
            _worldWasLost = true
            pcall(H.InvalidateCachedFirstOf)
        end
        return
    end
    _worldWasLost = false

    if _lastWorldName == nil then
        -- First World of the session: record it, do NOT reset.
        _lastWorldName = wname
        _pendingWorldName = nil
        return
    end

    if wname == _lastWorldName then
        _pendingWorldName = nil
        return
    end

    -- The World name differs. DEBOUNCE before calling it a real screen transition:
    -- cutscenes flip FindFirstOf("World") between worlds tick to tick, and reacting
    -- to every flip kept resetting/pausing the reader for the whole scene. Only
    -- fire once the NEW name has stayed put for ~0.6s.
    if wname ~= _pendingWorldName then
        _pendingWorldName = wname
        _pendingSince = os.clock()
        return
    end
    if (os.clock() - _pendingSince) < 0.6 then
        return
    end

    -- Stable new World => real transition. Same work the old PostHook did.
    print("[AE] Map changed: " .. tostring(_lastWorldName) .. " -> " .. tostring(wname))
    _lastWorldName = wname
    _pendingWorldName = nil
    ResetStaleState()
    SkillList.Reset()
    Battle.Reset()
    TeamOV.ClearCapturedName()
    EpisodeBattle.FullReset()
    Trackers.ArmTransitionCooldown(0.8)
end

-- TEMP hang breadcrumb (re-added to locate a new freeze during the Nappa-saga
-- cutscene; remove once found). Writes the current step to AE_debug/ae_crumb.txt
-- right before running it; io.open "w"+close flushes, so on a hang the file holds
-- the culprit.
-- OJO: SIN `local` â€” asigna al local declarado ARRIBA (declaraciÃ³n adelantada, ver la nota allÃ­).
-- UNA MIGAJA POR BUCLE (07-26 noche). PROBLEMA QUE RESUELVE: los dos bucles escribÃ­an en el MISMO
-- archivo, y como el de FOCO corre a 16ms y el de POLL a 100ms, la migaja de REPOSO del foco
-- (`F:idle`) PISA la migaja de trabajo del poll casi siempre. El crash del arranque de hoy quedÃ³ en
-- `F:idle` = "el foco no estaba trabajando", pero sin poder saber quÃ© hacÃ­a el poll: informaciÃ³n
-- perdida. La LECCIÃ“N 17 (nombre propio para el reposo) fue solo media soluciÃ³n; la otra media es
-- SEPARAR LOS ARCHIVOS. Enrutar por prefijo NO cuesta ni una escritura mÃ¡s: cada bucle sigue
-- escribiendo una vez, solo que en su propio archivo.
--   ae_crumb.txt       -> bucle de FOCO (tags `F:*`) y cualquier otro
--   ae_crumb_poll.txt  -> bucle de POLL (tags `P:*`)
--   ae_crumb_dump.txt  -> volcado continuo del F5 (lo escribe debug_tools, bucle aparte SIN frenos)
-- AL DIAGNOSTICAR HAY QUE LEER LOS TRES.
function Crumb(tag)
    if not AE_DIAG then return end  -- versiÃ³n pÃºblica: no se escribe ninguna migaja
    local path = "AE_debug/ae_crumb.txt"
    if tag:sub(1, 2) == "P:" then path = "AE_debug/ae_crumb_poll.txt" end
    local ok, f = pcall(io.open, path, "w")
    if ok and f then f:write(tag); f:close() end
end

-- Lee las tres migajas de un tirÃ³n, para el watchdog y para el historial de arranque.
local function ReadAllCrumbs()
    local parts = {}
    local files = { { "foco", "AE_debug/ae_crumb.txt" },
                    { "poll", "AE_debug/ae_crumb_poll.txt" },
                    { "dump", "AE_debug/ae_crumb_dump.txt" } }
    for i = 1, #files do
        local okc, cf = pcall(io.open, files[i][2], "r")
        if okc and cf then
            local v = cf:read("*a"); cf:close()
            if v and v ~= "" then parts[#parts + 1] = files[i][1] .. "=" .. v end
        end
    end
    if #parts == 0 then return "?" end
    return table.concat(parts, " | ")
end

-- Rolling log mirror. UE4SS.log is wiped by UE4SS on each launch, BEFORE this mod loads, so a
-- crash's context is gone the moment the game restarts â€” the crash HISTORY keeps the culprit
-- label (P:hud, F:pollfocus...) but not the story around it. Fix: while playing, periodically
-- copy the live log to a persistent mirror. On the next launch the init block archives that
-- mirror (see bottom of file) with a timestamp + the final crumb, so EVERY crash keeps its full
-- context, not just the most recent. Fully pcall-wrapped: a file-lock miss or any error just
-- skips that snapshot, never touches the game. CWD is Binaries/Win64, same as AE_debug and
-- UE4SS.log, so plain relative paths resolve correctly.
--
-- Timing matters: the mirror is only as fresh as its last snapshot, so a crash could lose the
-- final seconds of CONTEXT (the CRUMB still pins the exact crashing step â€” that's never stale).
-- To shrink that blind spot: a short 3s base cadence for quiet play, PLUS a forced snapshot the
-- instant a big UI churn is detected (SnapshotLog(true) from the poll self-check). Crashes
-- cluster on those churns, so capturing the lead-in right when one starts means the mirror holds
-- the moments that matter even if the game dies a beat later. The log is tiny (~48K), so copying
-- it often is cheap.
local _lastLogSnapshot = 0
local function SnapshotLog(force)
    if not AE_DIAG then return end  -- versiÃ³n pÃºblica: no se copia el log ni se recorta nada
    if not force and os.clock() - _lastLogSnapshot < 3 then return end
    _lastLogSnapshot = os.clock()
    pcall(function()
        local src = io.open("UE4SS.log", "r")
        if not src then return end
        local data = src:read("*a"); src:close()
        if not data or data == "" then return end
        -- Keep only the tail if the log grew big, so the write stays cheap and holds the
        -- most recent (crash-relevant) context.
        if #data > 600000 then data = data:sub(#data - 600000) end
        local dst = io.open("AE_debug/ae_lastlog.txt", "w")
        if not dst then return end
        dst:write(data); dst:close()
    end)
    -- Keep the zero-gap live event log bounded. Only on the base cadence (never during a forced
    -- churn snapshot), and only when it has actually grown large, so the read+rewrite almost
    -- never runs and can't race the per-line appends in practice.
    if not force then
        pcall(function()
            local f = io.open("AE_debug/ae_livelog.txt", "r")
            if not f then return end
            local d = f:read("*a"); f:close()
            if d and #d > 2000000 then
                local w = io.open("AE_debug/ae_livelog.txt", "w")
                if w then w:write(d:sub(#d - 1500000)); w:close() end
            end
        end)
    end
end

local function StartFocusLoop()
    LoopAsync(16, function()
        -- MIGAJA DE REPOSO (07-22). Antes aquÃ­ decÃ­a "F:worldtrans", y como el bucle escribe migaja cada
        -- 16ms y en cuanto se frena hace `return false` SIN avanzar, la migaja quedaba clavada en
        -- "F:worldtrans" AUNQUE NUNCA hubiera leÃ­do el World â€” eso hizo AMBIGUOS los 44 crashes con ese
        -- nombre (podÃ­an ser el foco congelado y el crash venir de otro lado). Ahora el reposo es "F:idle"
        -- y "F:worldtrans" se escribe SOLO justo antes de llamar de verdad. Si vuelve a salir F:idle,
        -- significa "el foco estaba congelado, mira al bucle de poll"; F:worldtrans ya seÃ±ala de verdad.
        Crumb("F:idle")
        -- FRENO ANTI-CRASH (07-20): NO leer el World durante el churn pesado de una carga de mapa. Es
        -- cuando GetFullName sobre el World a medio construir TRUENA nativo (crumb F:/P:worldtrans, 2 de
        -- 3 crashes esta sesiÃ³n). Durante el churn la detecciÃ³n de transiciÃ³n espera; se detecta al
        -- asentarse (~1-2s), sin costo de accesibilidad real (la identidad del World es interna). Los
        -- pollers ya estÃ¡n frenados por el mismo churn, asÃ­ que no leen de mÃ¡s mientras tanto.
        -- FRENO ADICIONAL (07-21): NO leer el World durante una TRANSICIÃ“N (transitionCooldown, armado por
        -- los diÃ¡logos de guardado/carga del ARRANQUE). CRASH F:worldtrans al arrancar (crumb, en "Revisando
        -- contenido descargable" / "Dialog dismissed"): durante la carga de datos el World estÃ¡ a medio crear
        -- y GetFullName sobre Ã©l TRUENA (carrera nativa, IsValidRef no la elimina â€” LECCIÃ“N 1). IsWorldAlive
        -- NO sirve aquÃ­ (solo mira GameInstance, singleton de proceso => siempre true tras el arranque). La
        -- transiciÃ³n sÃ­ se detecta al asentarse (CheckWorldTransition ya acepta ese retraso). Fail-safe: si
        -- IsInTransition nunca es true, el gate no cambia nada.
        -- `not Trackers.onMainMenu` (07-22): CRASH F:worldtrans al ENTRAR a la Enciclopedia desde el menÃº.
        -- CheckWorldTransition corre AL INICIO del loop, ANTES de que ScanForFocus arme el churn del tick
        -- actual; en el 1er tick de la transiciÃ³n el churn viejo ya expirÃ³ y lee el World reconstruyÃ©ndose.
        -- El menÃº es SIEMPRE el mismo World (Korat_P) => nunca hace falta leer el World ahÃ­, y como
        -- Trackers.onMainMenu es del tick ANTERIOR, cubre tambiÃ©n el tick de la transiciÃ³n (cuando aÃºn
        -- refleja el menÃº). Las transiciones a MUNDO nuevo (pelea/historia) tienen onMainMenu=false => se
        -- detectan normal, al asentarse.
        -- VENTANA DE SALIDA DE MENÃš (07-22, CRASH F:worldtrans AL ENTRAR A LA ENCICLOPEDIA, 2Âª vez).
        -- INCOHERENCIA que lo causaba: el gate de MÃS ABAJO decidÃ­a "estos 2.5s son demasiado peligrosos
        -- para leer widgets" y aquÃ­ arriba, en el mismo tick, SÃ se leÃ­a el World â€” que es MÃS peligroso.
        -- `not onMainMenu` solo aplazaba UN tick (en cuanto PollFocus recalcula onMainMenu=false, esta
        -- lÃ­nea se suelta). Ahora comparte la MISMA ventana que el resto del bucle.
        local justLeftMenuNow = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5
        if os.clock() >= uiChurnUntil and not Trackers.IsInTransition() and not Trackers.onMainMenu and not justLeftMenuNow then
            Crumb("F:worldtrans")
            pcall(CheckWorldTransition)
        end
        -- ANTI-CRASH (07-20): durante el CHURN pesado (reconstrucciÃ³n/transiciÃ³n) el bucle de foco NO
        -- lee NADA â€” ni el World ni los widgets. Es JUSTO cuando todo se destruye/reconstruye y las
        -- lecturas nativas truenan (F:pollfocus 40 + F:worldtrans 33 = ~65% de los crashes). `churn`
        -- va PRIMERO (corto-circuito) para ni siquiera llamar IsWorldAlive en ese momento. Se retoma al
        -- asentarse (churn 0.3-3s). La navegaciÃ³n normal del menÃº NO arma churn (saltos <200), asÃ­ que
        -- sigue Ã¡gil; solo se frena en las reconstrucciones, que es donde truena. Costo: el menÃº de
        -- pausa puede leer un instante mÃ¡s tarde si lo abres en pleno churn (raro; la pausa normal estÃ¡
        -- congelada y no churnea sostenido).
        -- SALIDA DE MENÃš (07-21): durante 2.5s tras DEJAR el menÃº principal, NO leer el foco â€” cubre el
        -- teardown del menÃº (el conteo aÃºn no armÃ³ churn, pero los botones ya se destruyen => F:pollfocus).
        -- CondiciÃ³n `not Trackers.onMainMenu`: DENTRO del menÃº NO frena (si no, mudez), solo al salir.
        -- Cierra el hueco de 1 tick entre que onMainMenu cae y el churn se arma. La Enciclopedia se lee por
        -- su poller (poll loop), no por foco, asÃ­ que no pierde nada; Ajustes lee ~2.5s mÃ¡s tarde (aceptado).
        -- `justLeftMenuNow` YA se calculÃ³ arriba (mismo tick, mismo valor) â€” no recalcular.
        if not readerEnabled or os.clock() < uiChurnUntil or justLeftMenuNow or Trackers.IsInTransition() or not IsWorldAlive() then
            -- LA VENTANA DE SALIDA NO DEBE ENVEJECER MIENTRAS EL BUCLE ESTÃ CONGELADO (07-22, causa raÃ­z
            -- del crash de la Enciclopedia). `_lastOnMainMenuClock` solo se sella dentro de PollFocus
            -- (~L1219), y PollFocus NO CORRE mientras el churn frena el bucle. Resultado medido: la
            -- cortinilla del menÃº armÃ³ churn 22:18:09 y 22:18:11 (2s cada uno); durante ~4s el reloj se
            -- quedÃ³ parado en el Ãºltimo tick con menÃº, asÃ­ que al soltarse el freno la ventana de 2.5s YA
            -- HABÃA CADUCADO y no protegiÃ³ nada â€” se leyÃ³ el World de la Enciclopedia a medio construir.
            -- Refrescarlo aquÃ­ hace que los 2.5s empiecen a contar cuando el bucle REANUDA de verdad.
            -- NO se retroalimenta (LECCIÃ“N 6): si el freno es el propio justLeftMenuNow, onMainMenu es
            -- false por definiciÃ³n y esta lÃ­nea no toca el reloj, asÃ­ que la ventana sÃ­ expira.
            if Trackers.onMainMenu then _lastOnMainMenuClock = os.clock() end
            -- Mismo motivo para la ENCICLOPEDIA (07-27): si el bucle estÃ¡ frenado mientras sigues DENTRO
            -- de la galerÃ­a, su ventana de salida no debe envejecer (LECCIÃ“N 16). Tampoco se retroalimenta:
            -- si el freno fuera la propia ventana de salida, onGallery ya es false y esta lÃ­nea no toca nada.
            if Trackers.onGallery then _lastOnGalleryClock = os.clock() end
            focusLoopHeartbeat = os.clock()
            return false
        end
        -- MIGAJA CON CONTEXTO (07-26). El crash de hoy al entrar a la Enciclopedia quedÃ³ en
        -- `F:pollfocus`, que solo dice "muriÃ³ dentro de PollFocus" â€” insuficiente. AÃ±adir si estÃ¡bamos
        -- en el MENÃš es GRATIS (`Trackers.onMainMenu` es una banderita ya calculada, cero llamadas
        -- nativas, misma Ãºnica escritura por tick) y contesta la pregunta que importa: Â¿fue el residual
        -- conocido del menÃº principal, o algo nuevo? Lee `F:pollfocus:menu` como "muriÃ³ con el menÃº
        -- principal (o un sub-menÃº suyo) activo".
        -- === DIAG DE ATASCOS CORTOS (07-27 noche, quitar al cerrar la lentitud del menÃº) ===
        -- El DIAG de retraso dio 12 medidas de 0.46 a 0.82s **con `fallos=0` y SIN una sola reconstrucciÃ³n
        -- durante la navegaciÃ³n**: o sea, el mod no se equivocaba ni estaba frenado por ningÃºn gate, y aun
        -- asÃ­ perdÃ­a medio segundo largo. Solo queda una explicaciÃ³n: el bucle TARDA en dar la vuelta,
        -- porque alguna llamada nativa se atasca. Y esos atascos son INVISIBLES hasta ahora, porque el
        -- watchdog solo ficha los de mÃ¡s de 1.5s â€” uno de 0.6s no deja rastro en ninguna parte.
        -- Esto mide el HUECO entre vueltas del bucle. `_focusStage` conserva la etapa donde acabÃ³ la vuelta
        -- anterior, asÃ­ que un hueco grande viene etiquetado con el punto exacto que se atascÃ³. Coste: una
        -- resta por tick y un print que en navegaciÃ³n sana no salta.
        local nowTick = os.clock()
        local gapTick = nowTick - _lastFocusTickClock
        _lastFocusTickClock = nowTick
        if _lastFocusTickClock > 0 and gapTick >= 0.15 and gapTick < 10 then
            print(string.format("[AE-DIAG] focus gap %.2fs stage=%s", gapTick, tostring(_focusStage)))
        end
        Crumb(Trackers.onMainMenu and "F:pollfocus:menu" or "F:pollfocus")
        local ok, err = pcall(PollFocus)
        if not ok then
            print("[AE] Focus loop error: " .. tostring(err))
            ResetStaleState()
        end
        focusLoopHeartbeat = os.clock()
        return false
    end)
end

local function StartPollLoop()
    -- Slow loop: dialogs, screen changes, battle HUD, cutscene text, shop categories, etc.
    -- These detect state changes on the game's timeline, not on user input, so 100ms
    -- is more than tight enough for announcements (HP thresholds, integer-second timer,
    -- dialog appearance) without burning 60Hz of FindAllOf/FindFirstOf scans.
    -- Focus tracking is on a separate 16ms loop for screen-reader responsiveness.
    LoopAsync(100, function()
        SnapshotLog() -- persist a mirror of UE4SS.log so each crash keeps its context (throttled)
        Crumb("P:tick")  -- migaja de REPOSO; ver la nota de "F:idle" en el bucle de foco (07-22)
        -- Publica el freno de churn para que el VOLCADO del F5 (debug_tools, bucle aparte) tambiÃ©n pueda
        -- respetarlo (07-27: un crash con la migaja `D:scan` demostrÃ³ que ese bucle mata si escanea en
        -- plena reconstrucciÃ³n). Una asignaciÃ³n por tick, sin llamadas nativas.
        Trackers.uiChurnUntil = uiChurnUntil
        -- Mismo freno anti-crash que en el bucle de foco: no leer el World durante el churn de carga NI
        -- durante una transiciÃ³n (transitionCooldown de los diÃ¡logos de arranque). Ver el foco loop (07-21).
        -- Y la MISMA ventana de salida de menÃº (07-22): el throttle de CheckWorldTransition es COMPARTIDO
        -- entre ambos bucles, asÃ­ que si aquÃ­ no se gatea, este bucle se come el turno y lee el World
        -- justo en la ventana que el otro estÃ¡ evitando. Los dos gates tienen que ser IDÃ‰NTICOS.
        local jlmPoll = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5
        if os.clock() >= uiChurnUntil and not Trackers.IsInTransition() and not Trackers.onMainMenu and not jlmPoll then
            Crumb("P:worldtrans")
            pcall(CheckWorldTransition)
        end
        -- Self-check the widget count on THIS 100ms tick too. The churn guard normally lives in
        -- the 16ms focus loop, but during a rapid pause/battle churn (count oscillating
        -- 1283<->2170) the focus loop might not have re-armed uiChurnUntil in the ~16ms before
        -- this tick, letting a heavy poller (P:dialogs, P:hud) run mid-churn and crash. Sampling
        -- here closes that gap. Only #array is read (no per-widget access), so it's safe.
        do
            -- Migaja propia (07-22): este `FindAllOf` es la ÃšNICA llamada nativa del mod que corre SIN
            -- freno de churn (a propÃ³sito: es quien DETECTA el churn). Al quedar bajo la migaja genÃ©rica
            -- del tick era una zona ciega en cada diagnÃ³stico. Ahora se distingue de "P:tick" (I/O del
            -- espejo de log) y de "P:worldtrans" (lectura real del World).
            --
            -- CRASH `P:wcount` (07-27, al entrar a la Enciclopedia). Las tres migajas separadas lo
            -- seÃ±alaron limpio: foco=`F:idle` (frenado por el churn, o sea los frenos del foco SÃ
            -- actuaron), dump=`D:idle`, poll=`P:wcount`. El livelog: `UI churn guard: 1756 -> 700` a las
            -- 13:26:54 y el crash a las 13:26:55, en pleno rebuild.
            -- LA PREMISA DE ARRIBA ERA OPTIMISTA. El comentario original decÃ­a "Only #array is read (no
            -- per-widget access), so it's safe": leer `#w` sÃ­ es barato, pero `FindAllOf("UserWidget")`
            -- NO es leer una longitud â€” recorre la GUObjectArray y CONSTRUYE una lista de ~1762 objetos,
            -- tocando cada uno. En pleno rebuild masivo eso puede pillar un objeto a medio liberar y
            -- tronar. No es "seguro", es "menos peligroso que acceder a los widgets".
            -- FRENO (07-27): mientras hay churn VIGENTE, este conteo pasa de 10 veces por segundo a 2.5
            -- â€” cuatro veces menos exposiciÃ³n JUSTO en el momento peligroso. Fuera del churn (pantalla
            -- asentada, sin riesgo) sigue igual de fino que siempre.
            -- POR QUÃ‰ NO SE QUITA DEL TODO DURANTE EL CHURN, que serÃ­a lo mÃ¡s seguro: este conteo es el
            -- que EXTIENDE la ventana mientras el rebuild continÃºa, y es el Ãºnico que corre cuando el
            -- bucle de foco estÃ¡ frenado. Si dejara de contar, `pollLastWidgetCount` quedarÃ­a viejo y al
            -- expirar la ventana el primer conteo verÃ­a un salto enorme y armarÃ­a OTRA ventana de 2s
            -- encadenada, retrasando la lectura tras CADA transiciÃ³n. Throttlear conserva la funciÃ³n y
            -- baja el riesgo; quitarlo cambiarÃ­a el comportamiento del churn guard, que es la pieza
            -- central anti-crash y no se toca a la ligera.
            -- HONESTIDAD: esto REDUCE la probabilidad, no la elimina. La enumeraciÃ³n durante un rebuild
            -- es una carrera nativa y `pcall` no atrapa un crash nativo (LECCIÃ“N 1).
            -- (sin `goto`: no todas las versiones de Lua lo aceptan y un error de sintaxis deja el mod
            -- sin cargar y a IvÃ¡n sin voz)
            -- SEGUNDO CRASH EN ESTE PUNTO (07-27 15:04, entrando a la Enciclopedia). Migajas: poll=`P:wcount`,
            -- foco=`F:idle` (frenado por el churn, o sea el bucle de foco no estaba implicado), y esta vez
            -- NI SIQUIERA HUBO VENTANA DE CRASH ni archivo .dmp: el proceso muriÃ³ de golpe. Livelog:
            -- `UI churn guard: 1756 -> 697` y el log se corta a mitad del rebuild (700 -> 1148).
            -- El throttle a 0.4s de esta maÃ±ana bajÃ³ la exposiciÃ³n 4x pero NO la quitÃ³, y volviÃ³ a caer aquÃ­.
            -- AHORA SE ELIMINA: durante el churn NO se cuenta, punto. Es la misma polÃ­tica que ya sigue el
            -- bucle de FOCO (que durante el churn no llega ni a enumerar), asÃ­ que el poll deja de ser la
            -- excepciÃ³n. Y el problema que me hizo dudar antes queda resuelto con el resync: la primera
            -- cuenta DESPUÃ‰S del churn solo SINCRONIZA el valor, sin evaluar el salto â€” si lo evaluara, el
            -- salto acumulado del rebuild armarÃ­a otra ventana encadenada y retrasarÃ­a la lectura tras cada
            -- transiciÃ³n, que es justo lo que querÃ­a evitar.
            -- Lo que se pierde: la auto-extensiÃ³n de la ventana mientras el rebuild continÃºa. Lo cubre el
            -- bucle de foco, que al soltarse ve el salto acumulado y arma Ã©l la ventana siguiente.
            local nowW = os.clock()
            local okW, w = nil, nil
            if nowW < uiChurnUntil then
                _pollWCountResync = true  -- al salir del churn, la primera cuenta solo sincroniza
            else
                Crumb("P:wcount")  -- PEGADA a la llamada real (LECCIÃ“N 17): si el tick no cuenta, no la escribe
                okW, w = pcall(FindAllOf, "UserWidget")
            end
            if okW and w and _pollWCountResync then
                _pollWCountResync = false
                pollLastWidgetCount = #w
                -- PUBLICAR TAMBIÃ‰N EN EL RESYNC (07-28). Antes esta rama ponÃ­a `okW = nil` y salÃ­a sin
                -- llegar a la publicaciÃ³n de abajo, asÃ­ que `Trackers.widgetCount` se quedaba con el valor
                -- ANTERIOR al churn un tick mÃ¡s â€” y el bucle de foco, que ya solo lee de ahÃ­, calculaba su
                -- salto contra un nÃºmero caduco. Publicar aquÃ­ cierra el Ãºltimo hueco por el que el conteo
                -- podÃ­a quedarse congelado.
                Trackers.widgetCount = #w
                okW = nil  -- salta la evaluaciÃ³n de este tick: solo sincronizamos
            end
            if okW and w then
                local c = #w
                local sw = math.abs(c - pollLastWidgetCount)
                if pollLastWidgetCount > 0 and sw >= 200 then
                    -- Scale the window like the focus loop: a big battle/scene rebuild (>=800,
                    -- e.g. the oscillating 1283<->2170 during heavy special-move fights) needs the
                    -- longer settle, or PollHUD reads a churning pawn in the gap and crashes (P:hud).
                    -- Long window only in a real teardown context; short everywhere else (menus,
                    -- attract-cutscene, transition gaps) so navigation stays responsive. See InDangerZone.
                    local danger = InDangerZone()
                    -- no acortar un freno vigente (ver churn guard grande, 07-21)
                    uiChurnUntil = math.max(uiChurnUntil, os.clock() + (danger and ((sw >= 800) and 3.0 or 2.0) or 0.3))
                    -- Force a fresh log mirror ONLY at crash-prone churn (danger zone). The harmless
                    -- menu/attract churns don't need it and shouldn't pay the read+write every swing.
                    if danger then SnapshotLog(true) end
                end
                pollLastWidgetCount = c
                -- Publicado para el bucle de FOCO, que ya NO enumera por su cuenta (07-27): era el mismo
                -- recorrido hecho dos veces cada 100ms y se llevaba 288 de 515 atascos.
                Trackers.widgetCount = c
            end
        end
        -- === DIAG TEMPORAL: cacerÃ­a del crash de transiciÃ³n (quitar al cerrar el caso) ===
        -- Latido de ESTADO durante y 3s DESPUÃ‰S de cada churn/transiciÃ³n/salto grande â€” la ventana
        -- volÃ¡til donde el motor truena nativo al cargar una batalla. La ÃšLTIMA lÃ­nea antes de que el
        -- log calle fija el estado justo antes del crash; el crumb dice en quÃ© poller cayÃ³. Solo LEE
        -- relojes/ventanas ya calculadas (cero llamadas nativas nuevas), no cambia nada. Throttle 150ms;
        -- en juego tranquilo no imprime.
        do
            local nowD = os.clock()
            local wc = pollLastWidgetCount
            local sw = math.abs(wc - _transDiagLastWC)
            _transDiagLastWC = wc
            local inChurn = nowD < uiChurnUntil
            local inTrans = Trackers.IsInTransition()
            if inChurn or inTrans or sw >= 200 then _transVolatileUntil = nowD + 3.0 end
            if nowD < _transVolatileUntil and (nowD - _transDiagLast) >= 0.15 then
                _transDiagLast = nowD
                print("[AE-DIAG] transcrash wc=" .. tostring(wc) .. " sw=" .. tostring(sw)
                    .. " churn=" .. tostring(inChurn) .. " trans=" .. tostring(inTrans))
            end
        end
        -- Cutscene subtitles + skip prompt run BEFORE the transition-pause guard so they
        -- read during story transitions â€” but they must STILL honour uiChurnUntil: during
        -- a big UI rebuild (post-battle result/story-return churn) they were reading a
        -- cutscene widget mid-teardown and crashing the game (crumb P:cutscenetext). No
        -- valid subtitle exists mid-rebuild anyway; normal cutscenes don't arm uiChurnUntil.
        if readerEnabled and os.clock() >= uiChurnUntil then
            Crumb("P:cutsceneskip")
            local okCS, errCS = pcall(EpisodeBattle.PollCutsceneSkip)
            if not okCS then print("[AE] PollCutsceneSkip error: " .. tostring(errCS)) end
            Crumb("P:cutscenetext")
            local okCT, errCT = pcall(EpisodeBattle.PollCutsceneText)
            if not okCT then print("[AE] PollCutsceneText error: " .. tostring(errCT)) end
        end
        -- DESACTIVADO 07-22 (experimento limpio, ver OnWidgetFocused): aquÃ­ corrÃ­a PollOptionValue ANTES
        -- del gate de churn â€” un cambio ESTRUCTURAL (corrÃ­a en TODA transiciÃ³n, sin el freno) que NO
        -- descartÃ© bien al culpar a Option_List_004. Se retira junto con el resto del lector de valores
        -- para deslindar los crashes al entrar a sub-menÃºs de Ajustes. Reactivar aquÃ­ si se confirma
        -- que los crashes NO eran esto.
        if not readerEnabled or Trackers.IsInTransition() or not IsWorldAlive()
           or os.clock() < uiChurnUntil then
            -- uiChurnUntil: the focus loop (16ms) detected a UI rebuild via widget-count
            -- swing; skip ALL heavy pollers (FindFirstOf/FindAllOf + native reads) while
            -- the widgets churn, or they crash the game (crumb P:room entering an episode
            -- battle, a same-world transition nothing else detects).
            pollLoopHeartbeat = os.clock()
            return false
        end
        Crumb("P:dialogs")
        local ok, err = pcall(Trackers.PollDialogs)
        if not ok then print("[AE] PollDialogs error: " .. tostring(err)) end
        Crumb("P:rewards")
        local okRw, errRw = pcall(Trackers.PollRewards)
        if not okRw then print("[AE] PollRewards error: " .. tostring(errRw)) end
        Crumb("P:msgnotif")
        local okMn, errMn = pcall(Trackers.PollMessageNotification)
        if not okMn then print("[AE] PollMessageNotification error: " .. tostring(errMn)) end
        Crumb("P:bracket")
        local okBr, errBr = pcall(Trackers.PollTournamentBracket)
        if not okBr then print("[AE] PollTournamentBracket error: " .. tostring(errBr)) end
        Crumb("P:prize")
        local okPz, errPz = pcall(Trackers.PollTournamentPrize)
        if not okPz then print("[AE] PollTournamentPrize error: " .. tostring(errPz)) end
        Crumb("P:levelup")
        local okLv, errLv = pcall(Trackers.PollLevelUp)
        if not okLv then print("[AE] PollLevelUp error: " .. tostring(errLv)) end
        Crumb("P:unlocks")
        local okUn, errUn = pcall(Trackers.PollUnlocks)
        if not okUn then print("[AE] PollUnlocks error: " .. tostring(errUn)) end
        Crumb("P:decision")
        local okDb, errDb = pcall(Trackers.PollDecisionBranch)
        if not okDb then print("[AE] PollDecisionBranch error: " .. tostring(errDb)) end
        Crumb("P:battledetails")
        local okBd, errBd = pcall(Trackers.PollBattleDetails)
        if not okBd then print("[AE] PollBattleDetails error: " .. tostring(errBd)) end
        Crumb("P:clash")
        -- FRENO ANTI-CRASH (07-20): NO correr PollClash durante el CHURN pesado. Su escaneo pesado
        -- (FindAllOf RichTextBlock) TRUENA cuando el forcejeo se destruye al SALIR de la pelea (crumb
        -- P:clash). El churn arma en rebuilds grandes (>=200 = la transiciÃ³n de salida); un choque real
        -- es un overlay chico (no arma churn), asÃ­ que se sigue leyendo. Se retoma al asentarse.
        if os.clock() >= uiChurnUntil then
            local okCl, errCl = pcall(Trackers.PollClash)
            if not okCl then print("[AE] PollClash error: " .. tostring(errCl)) end
        end
        Crumb("P:chart")
        local okCh, errCh = pcall(Trackers.PollChartDetails)
        if not okCh then print("[AE] PollChartDetails error: " .. tostring(errCh)) end
        Crumb("P:sysmsg")
        local okSy, errSy = pcall(Trackers.PollSystemMessage)
        if not okSy then print("[AE] PollSystemMessage error: " .. tostring(errSy)) end
        Crumb("P:help")
        local ok2, err2 = pcall(Trackers.PollHelpWindows)
        if not ok2 then print("[AE] PollHelpWindows error: " .. tostring(err2)) end
        Crumb("P:screen")
        local ok3, err3 = pcall(Trackers.PollScreenChanges)
        if not ok3 then print("[AE] PollScreenChanges error: " .. tostring(err3)) end
        -- PollIntro removed (investigating retry crash)
        Crumb("P:room")
        local ok6, err6 = pcall(Trackers.PollRoom)
        if not ok6 then print("[AE] PollRoom error: " .. tostring(err6)) end
        Crumb("P:tutorial")
        local okT, errT = pcall(Trackers.PollTutorial)
        if not okT then print("[AE] PollTutorial error: " .. tostring(errT)) end
        Crumb("P:storymap")
        local ok7, err7 = pcall(EpisodeBattle.PollStoryMap)
        if not ok7 then print("[AE] PollStoryMap error: " .. tostring(err7)) end
        Crumb("P:epmaparea")
        local okEA, errEA = pcall(EpisodeBattle.PollEpisodeMapArea)
        if not okEA then print("[AE] PollEpisodeMapArea error: " .. tostring(errEA)) end
        Crumb("P:epmapplace")
        local okEP, errEP = pcall(EpisodeBattle.PollEpisodeMapPlace)
        if not okEP then print("[AE] PollEpisodeMapPlace error: " .. tostring(errEP)) end
        Crumb("P:charaselect")
        local okCsel, errCsel = pcall(EpisodeBattle.PollCharaSelect)
        if not okCsel then print("[AE] PollCharaSelect error: " .. tostring(errCsel)) end
        Crumb("P:hud")
        local ok5, err5 = pcall(Battle.PollHUD, Speak, SpeakQueued)
        if not ok5 then print("[AE] PollHUD error: " .. tostring(err5)) end
        Crumb("P:result")
        local ok5r, err5r = pcall(Battle.PollResult, Speak, SpeakQueued)
        if not ok5r then print("[AE] PollResult error: " .. tostring(err5r)) end
        Crumb("P:shop")
        local ok10, err10 = pcall(Shop.PollCategory)
        if not ok10 then print("[AE] PollShopCategory error: " .. tostring(err10)) end
        Crumb("P:skilllist")
        local ok11, err11 = pcall(SkillList.PollCategory, Speak)
        if not ok11 then print("[AE] PollSkillListTab error: " .. tostring(err11)) end
        Crumb("P:gallery")
        local okGal, errGal = pcall(Gallery.PollCharacter)
        if not okGal then print("[AE] PollGalleryCharacter error: " .. tostring(errGal)) end
        -- VALOR DE OPCIÃ“N: aquÃ­, DETRÃS del gate de churn (pantalla asentada). NO moverlo antes del gate:
        -- eso fue lo que crasheÃ³ al entrar a sub-menÃºs de Ajustes (07-22).
        Crumb("P:optvalue")
        local okOpt, errOpt = pcall(PollOptionValue)
        if not okOpt then print("[AE] PollOptionValue error: " .. tostring(errOpt)) end
        Crumb("P:done")
        pollLoopHeartbeat = os.clock()
        return false
    end)
end

local function StartReader()
    StartFocusLoop()
    StartPollLoop()

    -- Watchdog: detects dead loops and restarts them.
    -- No UObject access â€” survives native crashes.
    LoopAsync(2000, function()
        if not readerEnabled then return false end
        local now = os.clock()
        local focusDead = (now - focusLoopHeartbeat) > 1.5
        local pollDead = (now - pollLoopHeartbeat) > 1.5

        if focusDead or pollDead then
            -- Capture which poller the hung loop was inside (the crumb) BEFORE restarting
            -- overwrites it â€” this is how we identify the culprit of a recovered hang.
            local crumb = ReadAllCrumbs()  -- las TRES migajas (foco, poll, volcado F5)
            print("[AE] Watchdog: loops died (focus=" .. tostring(focusDead)
                .. " poll=" .. tostring(pollDead) .. ") at crumb '" .. tostring(crumb)
                .. "' focusStage=" .. tostring(_focusStage) .. " idx=" .. tostring(_focusScanIdx)
                .. "/" .. tostring(_focusScanTotal) .. ", restarting")
            ResetStaleState(true)  -- preserva el dedup: un reinicio NO debe re-leer el Ã­tem actual
            if focusDead then StartFocusLoop() end
            if pollDead then StartPollLoop() end
        end
        return false
    end)

    print("[AE] Reader loops started (with watchdog)")
end

-- === DEBUG TOOLS (remove this block to disable) ===
-- Herramientas de depuraciÃ³n (F3/F4/F5). SE CARGAN SIEMPRE, tambiÃ©n en la versiÃ³n pÃºblica: son
-- funciones del proyecto que el usuario invoca a mano, no diagnÃ³sticos automÃ¡ticos.
local debugOk, debugTools = pcall(require, "debug_tools")
if debugOk and debugTools then
    debugTools.Init(Speak)
else
    print("[AE] Debug tools not loaded: " .. tostring(debugTools))
end
-- === END DEBUG TOOLS ===

-- === INIT ===
print("[AE] Initializing SparkingZeroAccess Phase 2...")
Speech.Init()
Trackers.Init(Speak, SpeakQueued, PauseFocus)
EpisodeBattle.Init(Speak, SpeakQueued, PauseFocus)
Shop.Init(Speak, SpeakQueued)
Gallery.Init(Speak, SpeakQueued)
-- TeamOV.InitHook()  -- DISABLED 2026-07-04: TextBlock:SetText hook causes a native crash during load on the current game version; it was dead code ("registered but never fired" per project_status)
Battle.Init()
Battle.SetResetCallback(function()
    print("[AE] Result screen reset triggered")
    ResetStaleState()
    SkillList.Reset()
    TeamOV.ClearCapturedName()
    Trackers.ArmTransitionCooldown(0.8)
end)

-- F6: repeat the last rewards on demand. Safety net for when the automatic reward
-- announcement lands during noisy post-battle cutscene dialogue â€” press F6 anytime
-- (even after the cutscene) to hear the last rewards again, complete.
pcall(function()
    RegisterKeyBind(Key.F6, function()
        local r = Trackers.lastRewards
        if not r or #r == 0 then
            Speak("Sin recompensas recientes", true)
            return
        end
        Speak("Ãšltimas recompensas", true)
        for _, item in ipairs(r) do
            SpeakQueued(item)
        end
    end)
    print("[AE] F6 = repeat last rewards")
end)

-- F7: repeat the last story-map details panel (Recap / Details) on demand. The game
-- keeps that panel "alive" after you hide it, so the mod can't tell you reopened it to
-- re-read automatically â€” this hotkey gives that back under your control.
pcall(function()
    RegisterKeyBind(Key.F7, function()
        local r = Trackers.lastChartItems
        if not r or #r == 0 then
            Speak("Sin detalles recientes", true)
            return
        end
        Speak(r[1], true)
        for i = 2, #r do SpeakQueued(r[i]) end
    end)
    print("[AE] F7 = repeat last story-map details")
end)

-- Map transitions are handled by CheckWorldTransition() (polling), called at the
-- top of both reader loops. The old RegisterLoadMapPreHook/PostHook were removed:
-- those native engine hooks crash the current game build on the first map load.
-- CheckWorldTransition reproduces what the PostHook did (state resets) plus the
-- PreHook's pause-during-load, using only safe reads (pcall + IsValid).

-- Crash history (persists across restarts). The live crumb (ae_crumb.txt) only holds the
-- LAST poller and is overwritten every tick; UE4SS.log is wiped on each game launch. So if
-- you play solo and crash several times, restarting each time, all but the last crumb/log
-- would be lost. Here, at startup â€” BEFORE the loops overwrite the crumb â€” append the
-- previous session's final crumb to a PERSISTENT file, never auto-cleared, so every crash
-- is on record for the next debugging session. A crash freezes the crumb at the crashing
-- poller; a clean exit leaves whatever ran last (cross-check against the .dmp files, which
-- also accumulate per crash). Fully wrapped in pcall so a file error never blocks startup.
pcall(function()
    if not AE_DIAG then return end  -- versiÃ³n pÃºblica: no se guarda historial de crashes
    local prev = ReadAllCrumbs()  -- foco + poll + volcado F5 (07-26: uno tapaba al otro)
    if not prev or prev == "" or prev == "?" then return end
    local stamp = os.date("%Y-%m-%d %H:%M:%S")
    local hf = io.open("AE_debug/ae_crash_history.txt", "a")
    if not hf then return end
    hf:write(stamp .. "  launch; previous session last crumb: " .. prev .. "\n")
    hf:close()

    -- Archive the previous session's context alongside its crumb, so we keep the full story of
    -- each crash (churn magnitudes, scene, dialogue leading in), not just the culprit label. Two
    -- complementary sources, both appended under one dated header to a single growing archive
    -- (front-trimmed at ~5MB so it keeps roughly the last several crashes):
    --   MIRROR (ae_lastlog.txt) â€” full UE4SS.log incl. engine lines, but up to ~3s stale.
    --   LIVE   (_prevLiveLog)   â€” every [AE] message written the instant it happened: zero gap,
    --                             so the final seconds before ANY crash (even a quiet one) survive.
    -- All pcall-guarded.
    pcall(function()
        local header = "\n\n========== CRASH CONTEXT " .. stamp
            .. "  (final crumb: " .. prev .. ") ==========\n"
        local mirror = ""
        local lf = io.open("AE_debug/ae_lastlog.txt", "r")
        if lf then mirror = lf:read("*a") or ""; lf:close() end
        local live = _prevLiveLog or ""
        if mirror == "" and live == "" then return end
        local block = header
            .. "----- MIRROR (UE4SS.log, ~3s stale) -----\n" .. mirror
            .. "\n----- LIVE (per-event, zero gap) -----\n" .. live
        local existing = ""
        local ef = io.open("AE_debug/ae_crashlogs.txt", "r")
        if ef then existing = ef:read("*a") or ""; ef:close() end
        local combined = existing .. block
        if #combined > 5000000 then combined = combined:sub(#combined - 5000000) end
        local of = io.open("AE_debug/ae_crashlogs.txt", "w")
        if of then of:write(combined); of:close() end
    end)
end)

if Speech.IsLoaded() then
    StartReader()
    print("[AE] Live menu reader active.")
else
    print("[AE] Speech not available.")
end
