--[[
    SparkingZeroAccess - UE4SS Lua Mod
    Phase 2: Live menu reader

    Uses targeted polling on known interactive widget classes.
    IsValid() guards all UObject access. World-identity polling
    handles screen transitions. Watchdog restarts dead loops.

    Reader starts automatically on game launch.
]]


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
-- resumes constantly — clearing it made the button re-read on every resume (Iván 07-19). This survives
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
-- DIAG TEMPORAL (cacería del colgón de foco 07-18): etapa/índice del escaneo de foco, en MEMORIA
-- (cero I/O, cero nativas). El watchdog los lee al detectar la muerte del foco para des-enmascarar
-- DÓNDE se colgó (los pause-checks, el fast-path, o el recorrido de widgets y en qué índice). Quitar
-- al cerrar el caso.

local _focusStage = "idle"
local _focusScanIdx = 0
local _focusScanTotal = 0
local lastFocusPauseReason = nil -- DIAG: last logged reason the focus scan was paused
-- DIAGNÓSTICO TEMPORAL (2026-07-17) — se quita cuando cierre la investigación.
-- Registra SOLO los flancos de pauseMenuOpen. Es OBSERVACIÓN PURA: no gatea nada.
-- Para qué: se quiere usar pauseMenuOpen como señal de "el juego está CONGELADO" para
-- arreglar el subtítulo repetido al pausar, pero NO hay forma de saber si da falsos
-- positivos — el diag existente ("focus paused: ... pauseVis=N") solo se imprime en la
-- rama `not pauseMenuOpen`, así que un pauseMenuOpen=true NUNCA queda registrado.
-- Antes de usarlo como gate hay que probar EN VIVO que solo se enciende con la pausa
-- ABIERTA (LECCIÓN 14: un gate NO se valida con el F5; el intento de presencia de
-- WBP_Pause_C se validó así y silenció los barks 4m36s seguidos).
-- QUÉ ESPERAR: pauseMenuOpen=true SOLO cuando Iván pausa de verdad, y false al salir.
-- Si aparece true en pleno combate sin que él haya pausado => la señal NO sirve y el
-- fix del subtítulo queda definitivamente descartado.

local focusPauseUntil = 0    -- pause ONLY the focus scan (NOT the whole poll loop)
local lastWidgetCount = 0    -- previous UserWidget count, to detect UI rebuilds (see ScanForFocus)
local pollLastWidgetCount = 0 -- same, but sampled on the 100ms POLL tick (closes the focus-loop gap)
-- DIAG TEMPORAL (cacería del crash de transición 07-17): estado del guardia por tick en la
-- ventana volátil. Quitar al cerrar el caso.
local _transDiagLast = 0
local _transVolatileUntil = 0
local _transDiagLastWC = 0
local churnStreak = 0        -- consecutive ticks the count kept moving (catches GRADUAL loads)
local menuWalkBlockStreak = 0 -- ticks seguidos que el walk se frenó en menús (tope anti-mudez; ver ScanForFocus)
local _lastOnMainMenuClock = 0 -- último os.clock() con onMainMenu=true; da ventana de SALIDA de menú (ver churn guard)
local _lastOnGalleryClock = 0 -- ídem para la ENCICLOPEDIA; da la ventana de SALIDA de galería (ver PollFocus)
local _lastMenuFastHitClock = 0 -- último os.clock() en que el atajo halló el foco en un botón del MENÚ
                                -- PRINCIPAL; con eso se detecta el DESMONTAJE del menú (ver ScanForFocus)
local _lastGalleryFastHitClock = 0 -- último os.clock() con el foco hallado en la Enciclopedia; detecta su
                                   -- desmontaje igual que _lastMenuFastHitClock con el menú
local _menuFastMissUntil = 0       -- enfriamiento del atajo de botones tras una pasada sin foco (07-27:
                                   -- el watchdog fichó el cuelgue en `scan-menubtn`). Ver ScanForFocus.
local _menuWalkHoldStreak = 0      -- ticks seguidos que el walk se retuvo en el menú; tope anti-mudez
                                   -- (LECCIÓN 6). Contador PROPIO: no compartir con menuWalkBlockStreak.
local _menuFastMissStreak = 0      -- fallos SEGUIDOS del atajo; da el enfriamiento progresivo (0.15 a 0.8)
local _prevOnMainMenu = false      -- onMainMenu del tick anterior, para detectar el FLANCO de entrada al menú
local _menuFocusLostAt = 0         -- instante en que el botón cacheado del menú perdió el foco; da la espera
                                   -- de 50ms antes de ir a buscar (ver ScanForFocus). 0 = no está esperando.
-- Enfriamientos de los atajos POR PANTALLA (07-27 noche). Su gate `GetCachedFirstOf` dice EXISTE, no ESTÁ
-- EN PANTALLA (LECCIÓN 14), así que sin esto se ejecutan en TODAS las pantallas y cuelgan el bucle.
local _galMissUntil = 0
local _optMissUntil = 0
local _shopMissUntil = 0
local _scanReachedWalk = false -- ¿el escaneo llegó a mirar la pantalla entera? Si NO, un resultado vacío
                               -- significa "no miré" y NO debe borrar el dedup (ver ScanForFocus/PollFocus)
local _lastFocusTickClock = 0  -- reloj de la vuelta anterior del bucle de foco; mide atascos CORTOS que el
                               -- watchdog no ve (umbral 1.5s). DIAG temporal, ver StartFocusLoop.
local _nextWidgetEnum = 0      -- SIN USO desde que el foco dejó de enumerar por su cuenta (07-27): ahora
                               -- lee `Trackers.widgetCount` del poll. Se deja declarada por si hiciera
                               -- falta volver a throttlear una enumeración propia.
local _lastGalleryWidget = nil -- panel de la Enciclopedia que tuvo el foco; se le pregunta a ÉL antes de
                               -- hacer FindAllOf (819 de 918 atascos venían de esos FindAllOf). Ver allí.
local _pauseChecksMissUntil = 0 -- enfriamiento de la tanda de pause-checks cuando NO hay ninguna pantalla de
                                -- pausa (27+16 atascos medidos el 07-27, uno de ellos fatal). Ver PollFocus.
local _focusDiedAt = 0          -- hora en que el widget enfocado MURIÓ; frena el walk medio segundo, el
                                -- tiempo que el poll necesita para armar el freno de churn (07-28)
local _menuLooksAlive = false   -- ¿el botón cacheado del menú sigue VÁLIDO? Distingue "el menú se desmonta"
                                -- (frenar) de "el foco está en algo que el atajo no cubre" (hay que buscar
                                -- con el walk). Confundir las dos dejó MUDO el menú de avisos. Ver allí.
local _lastMenuFastWidget = nil    -- último botón del menú que tuvo el foco; el atajo cacheado del menú le
                                   -- pregunta a ÉL primero (2 llamadas nativas en vez de ~24). Siempre se
                                   -- revalida con IsValidRef antes de usarlo. Ver ScanForFocus.
local MENU_MAIN_CLASSES = {     -- solo el menú principal PELÓN (no Ajustes ni Tienda). Ver ScanForFocus.
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
-- PollFocus honours this — the poll loop (HUD, rewards, dialogs...) keeps running.
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

-- VALOR de una opción de Ajustes (07-22). Estructura VERIFICADA en el volcado: el widget ENFOCADO es
-- el botón de la opción (ej. AssistControlButton, SeButton), clase Option_List_010_Text_C (texto:
-- Auto/Semiautomático/Desactivado/Personalizar) o _011_Gauge_C (volumen: 79/80). Su VALOR vive en el
-- sub-TextBlock `.Title` (ruta `...<NombreBotón>.WidgetTree.Title`). Se busca el Title cuya ruta
-- Estado del poller de valor de opción.
local _optValNextPoll = 0

-- POLLER: anuncia el VALOR de una opción de Ajustes cuando cambia con IZQUIERDA/DERECHA (el FOCO no se
-- mueve, así que el bucle de foco no lo detecta y quedaba mudo).
-- DÓNDE VIVE EL VALOR (CONFIRMADO 07-22 leyendo el volcado con el formato correcto —valor ANTES de la
-- ruta— y coherente con lo medido en vivo): en el sub-widget **`caption`** del botón:
--     caption      = "Auto" / "Semiautomático" / "Desactivado" / "Personalizar"   <- EL VALOR
--     Title        = "Asistencia de batalla"                                       <- el NOMBRE
--     Text_Disable = "No puede cambiarse en esta pantalla."                        <- tooltip
-- SEGURIDAD (tras 4 crashes): este poller corre DETRÁS del gate de churn del poll loop (pantalla ya
-- asentada) y NO se hace NADA en OnWidgetFocused (LECCIÓN 18: hurgar propiedades del widget recién
-- enfocado truena si aún se está construyendo, p.ej. al entrar a un sub-menú). Solo lee el `caption`
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

-- ENFOQUE FINAL (07-22): NO depender del FOCO. Los intentos anteriores exigían `lastFocusedWidget`
-- válido, pero el DEMO del menú lo borra sin parar (ScanForFocus devuelve nil) => casi nunca coincidía
-- con el tick del poller y NUNCA llegaba a leer (verificado: 0 lecturas, sin errores, con el foco sí
-- estando en las opciones). Aquí se vigilan los `caption` de TODAS las opciones de la pantalla (~39) y
-- se anuncia el que CAMBIE — que es justo lo que pasa al mover IZQUIERDA/DERECHA. Da igual dónde esté
-- la ref del foco. Al entrar se llena el mapa sin anunciar (prev=nil) y al salir de Ajustes se limpia.
-- SEGURIDAD: corre DETRÁS del gate de churn (pantalla asentada), gateado por el contenedor de Ajustes,
-- con IsValidRef por widget y todo en pcall/TryCall. NADA en OnWidgetFocused (LECCIÓN 18).
local OPTION_CLASSES = { "WBP_OBJ_Option_List_010_Text_C", "WBP_OBJ_Option_List_011_Gauge_C" }

-- CAUSA RAÍZ DEL v13 (hallada 07-26): la versión anterior guardaba el valor anterior en un mapa
-- indexado POR EL WIDGET (`_optCaptionMap[w]`). En Lua, una tabla indexada por un objeto acierta
-- SOLO si es el MISMO objeto Lua, y UE4SS construye un envoltorio NUEVO en cada `FindAllOf` aunque
-- en pantalla sea el mismo botón. Resultado: `prev` salía nil SIEMPRE y la condición "cambió" no se
-- cumplía NUNCA => 0 anuncios y 0 errores, exactamente lo observado. (El `==` entre widgets sí
-- funciona porque UE4SS define __eq, pero Lua NO usa __eq para buscar CLAVES de tabla. Por eso el
-- `widget == lastFocusedWidget` de OnWidgetFocused sí sirve y este mapa no servía.)
-- EVIDENCIA de que todo lo demás estaba bien (volcado F5 del 07-26, pantalla de Accesibilidad):
--   WBP_Option_C existe y es visible; hay 12 instancias de Option_List_010_Text_C
--   (AssistControlButton, AssistComboButton, ...); el valor vive en su sub-widget `caption`; y ese
--   caption pasó de "Desactivado" a "Auto" a "Personalizar" durante la prueba de Iván.
-- ENFOQUE NUEVO: comparar por POSICIÓN, no por identidad. Se recolectan los valores de todas las
-- opciones en el ORDEN de escaneo (clase, índice) y se compara la tanda con la anterior. Un
-- izquierda/derecha mueve UNA casilla => se anuncia. Si cambian muchas de golpe o cambia el número
-- de opciones, la pantalla se rehizo o se reordenó => callar y solo re-sincronizar (fail-safe: en el
-- peor caso queda mudo como hoy, nunca dice basura). NO añade ni una llamada nativa: mismas lecturas
-- que la versión anterior. Sigue corriendo DETRÁS del gate de churn y NADA en OnWidgetFocused.
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
    local ws = {}      -- refs de este MISMO tick (nunca se guardan entre ticks: LECCIÓN 19)
    local first = nil  -- primera opción, para identificar la pantalla
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
    -- Identidad de la PANTALLA: nombre de la primera opción (ej. "AssistControlButton" en Accesibilidad,
    -- "SeButton" en Sonido). Una sola llamada por tick. Si cambia, es OTRO sub-menú y NO se compara nada
    -- (evita anunciar basura al cambiar de pestaña, que es lo que antes tapaba el umbral de 3).
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

    -- PRESET EN BLOQUE (07-26, medido con Iván): "Asistencia de batalla" es una opción MAESTRA — al
    -- ponerla en Auto o Desactivado, el juego cambia DE GOLPE todas sus sub-asistencias (el log mostró
    -- "6 cambios" y "8 cambios de golpe"). Con el umbral viejo de 3 eso se ignoraba, y por eso Iván oía
    -- "Personalizar" y "Semiautomático" (que mueven pocas) pero NO "Auto" ni "Desactivado". Ahora sí se
    -- anuncia; falta elegir CUÁL de las cambiadas.
    -- ELEGIR LA CORRECTA: la que tiene el FOCO. `lastFocusedName` lo mantiene el bucle de foco y en
    -- Ajustes es fiable (Iván: al volver a una opción, la lee bien). Es una variable ya calculada: cero
    -- llamadas nativas para leerla. Solo se piden nombres de las opciones CAMBIADAS (2 a 8 como mucho, y
    -- solo en este caso raro), no de las 12 en cada tick.
    -- Si ninguna cambiada tiene el foco, se anuncia la PRIMERA cambiada: el orden de FindAllOf coincide
    -- con el orden visual (verificado en el volcado: AssistControlButton, AssistComboButton,
    -- AssistPursuitButton...), así que la primera ES la maestra, que es justo la que Iván está moviendo.
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
    -- above never dedups them; add a name-only dedup — the slot name (BTN_1/BTN_2) is stable across the
    -- churn — so they don't re-read (Iván 07-19: "me lo lee mucho sin mover"). className computed here
    -- (was a few lines down) so the check is cheap; reused below.
    local className = GetClassName(widget)
    if name == lastFocusedName and className == "WBP_OBJ_BS_BTN_Result_1_C" then return end
    -- Left the result buttons (focused a real menu widget) => allow the next result entry to re-announce.
    if className ~= "WBP_OBJ_BS_BTN_Result_1_C" then lastResultCaption = nil end

    lastFocusedName = name
    lastFocusedWidget = widget

    -- CACHEAR la ref del Title de la opción de Ajustes AQUÍ (07-22). OnWidgetFocused corre en el FOCO loop
    -- justo cuando el foco cambia a esta opción = momento ESTABLE GARANTIZADO (foco fresco, sin churn), el
    -- único seguro para el FindAllOf. Antes se intentaba cachear en el poll loop, pero ahí `lastFocusedWidget`
    -- casi nunca está válido (el demo del menú detrás de Ajustes churnea y lo borra) => 0 lecturas. Con la ref
    -- ya cacheada, PollOptionValue solo lee GetText de ella (barato/seguro) y detecta el cambio izq/der.
    -- NADA del lector de valores aquí (07-22). El "paso 1" (un diag con 5 TryGetProperty sobre el widget
    -- recién enfocado) TAMBIÉN CRASHEÓ al entrar a un sub-menú de Ajustes. Iván insistió en no descartarlo
    -- por "no imprimió": tenía razón — el print va DESPUÉS de las 5 lecturas, así que si una truena, el
    -- mensaje nunca sale y parece que no corrió. **LECCIÓN 18: OnWidgetFocused NO es un momento seguro
    -- cuando el foco ACABA de entrar a una pantalla nueva: el widget recién enfocado puede estar todavía
    -- construyéndose, y hurgarle propiedades extra (TryGetProperty, incluso de propiedades inexistentes)
    -- truena nativo. Lo que el foco ya hace ahí está probado; AÑADIR lecturas propias NO es gratis.**
    -- El dato que faltaba (qué sub-widget tiene el VALOR) se saca del VOLCADO F5, sin tocar el juego.

    -- Check if this widget's class is suppressed
    if WR.SuppressedClasses[className] then
        return
    end

    -- === BATTLE RESULT BUTTONS (Reintentar / Salir) ===
    -- Read ONLY this button's OWN "caption" child (first real Latin text; skip the あ/JP and the literal
    -- "Text Block" placeholders), matched by path PREFIX so the neighbouring rank-up panel ("Nivel de
    -- jugador", widget WBP_GRP_BS_PlayerRankUP_C) is never grabbed (Iván 07-19). Dedup by the caption
    -- text. If the caption can't be found, DON'T return — fall through to the generic handler (safe
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

    -- === TEAM OVERVIEW (check first — cheap name + path match) ===
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
-- widgets each swap, so the count swings 600<->1700 repeatedly — which the churn guard reads as a
-- full screen REBUILD and pauses navigation for the big-swing window (up to 3s). But the menu
-- itself is stable and navigable the whole time; that long pause just makes it feel unresponsive
-- ("tarda en reaccionar... luego habla bien"). On these screens we cap the churn pause short (the
-- cosmetic free-burst settles in <0.5s) so navigation stays snappy. Real teardowns (leaving the
-- menu into a mode) are covered by transitionCooldownUntil, not this. IsVisible on these top-level
-- roots is reliable (confirmed via diag). Cheap: GetCachedFirstOf caches the lookup.
-- Are we in a context that genuinely TEARS DOWN widgets/pawns, where reading mid-churn has crashed?
-- BLACKLIST, not whitelist. Only three contexts have ever crashed: an active battle (P:hud), the
-- story map (P:storymap), and a story cutscene (skip-prompt on screen -> F:pollfocus). ONLY these
-- get the long churn window. EVERYTHING else — title, menus, load screens, the looping attract-
-- cutscene banter, the episode character-select, and crucially the transition GAPS BETWEEN menus —
-- is navigable/idle menu territory that has never crashed, so it gets a SHORT window and stays
-- responsive. The earlier whitelist ("is a known menu root visible?") misfired in exactly those
-- gaps: entering Episode Battle you pass through a limbo where neither title nor main-menu root is
-- visible, so it fell through to the 3s window — the "gran tirón". A blacklist has no such gap.
local function InDangerZone()
    if EpisodeBattle.IsStoryMapActive and EpisodeBattle.IsStoryMapActive() then return true end
    if Battle.WasBattleActive and Battle.WasBattleActive() then return true end
    -- Ventana de teardown post-pelea: la salida de batalla al menú sigue churneando ~segundos
    -- después de que WasBattleActive se apaga; sin esto el foco se colgaba en ese hueco (07-20).
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
    -- === "NO MIRÉ" NO ES LO MISMO QUE "NO HAY FOCO" (07-27 noche) ===
    -- Iván: "al quedarme parado repite una y otra vez donde estoy". CAUSA, verificada en el código de
    -- PollFocus (no supuesta): cuando esta función devuelve nil, PollFocus BORRA `lastFocusedName` y
    -- `lastFocusedWidget`, que son el dedup. Al volver a encontrar el MISMO botón lo toma por nuevo y lo
    -- vuelve a leer. Cada freno que corta el escaneo con `return nil` provocaba, por tanto, una relectura.
    -- Y esta función está llena de frenos legítimos (settle, enfriamientos, espera del menú, bloqueo del
    -- walk, small-churn guard): todos ellos significan "NO HE MIRADO", no "no hay nada enfocado".
    -- Se distinguen con esta bandera: TODOS los frenos retornan antes de llegar al walk, así que si la
    -- función acaba sin haber llegado allí, es que no miró y PollFocus debe DEJAR EL DEDUP EN PAZ.
    _scanReachedWalk = false
    _focusStage = "scan-findall"
    -- MIGAJAS FINAS SOLO EN LA ENCICLOPEDIA (07-27). El crash al salir de ahí dejó `F:pf-fast`, que
    -- significa "los pause-checks pasaron limpios y murió después" — pero ese "después" abarca esta
    -- función entera. Hay DOS sospechosos muy distintos y con soluciones opuestas:
    --   (1) este `FindAllOf("UserWidget")`, que enumera ~1762 objetos tocando cada uno. Es EXACTAMENTE la
    --       operación que acaba de matar el juego en `P:wcount` durante un rebuild, solo que aquí corre a
    --       16ms y en el primer tick de la salida el freno de churn todavía no está armado.
    --   (2) alguno de los escaneos POSTERIORES (el atajo de la galería tocando sus propios botones en
    --       teardown, u otro fast-path, o el walk).
    -- Distinguirlos vale una escritura de archivo por tick, y SOLO dentro de la Enciclopedia (fuera de
    -- ella, cero coste): si el próximo crash deja `F:sf-findall` es (1); si deja `F:sf-paths` es (2).
    -- NO se toca nada del comportamiento todavía: la solución de (1) obligaría a mover la enumeración
    -- después de los atajos, y de ella depende el churn guard, que es la pieza central anti-crash. Eso
    -- NO se hace a ciegas.
    -- === EL CULPABLE DE LA LENTITUD, MEDIDO (07-27 noche) ===
    -- El DIAG `focus gap` cazó 296 atascos en 3.5 minutos y el reparto no deja lugar a dudas:
    -- **200 en `scan-findall`** (o sea AQUÍ), 31 en pf-fastpath, 30 en scan-option, 13 en scan-full,
    -- 12 en scan-menubtn, 9 en pf-fp-haskbf. Dos tercios de todo el tiempo perdido están en esta única
    -- línea. Sumados, los atascos se comían prácticamente TODO el tiempo de la sesión: el bucle apenas
    -- hacía otra cosa. Y encaja con lo ya sabido: esta misma operación (enumerar ~1762 objetos tocando
    -- cada uno) es la que mató el juego DOS veces en `P:wcount`.
    -- LO ABSURDO DE HACERLO CADA TICK: se enumeraba la pantalla entera 62 veces por segundo aunque el
    -- resultado no se fuera a usar. En el menú, la Enciclopedia, Ajustes, la Tienda o la lista de
    -- comandos resuelve un ATAJO y la lista nunca llega a recorrerse: trabajo tirado a la basura, 62
    -- veces por segundo, y encima es el trabajo más peligroso que hace el mod.
    -- AHORA: se enumera cada 100ms (para el conteo del churn guard) y, aparte, siempre que de verdad se
    -- vaya a caminar la lista. En pantallas con atajo eso baja de 62 enumeraciones por segundo a 10.
    -- QUÉ SE PIERDE Y POR QUÉ ES ASUMIBLE: el churn guard del foco pasa a evaluarse 10 veces por segundo
    -- en vez de 62, así que una reconstrucción puede detectarse hasta 100ms más tarde. El bucle de POLL
    -- ya muestrea exactamente a ese mismo ritmo, o sea que no bajamos por debajo de lo que el mod ya
    -- consideraba suficiente en el otro bucle. Y a cambio se quitan dos tercios de los atascos.
    -- === SE ELIMINA LA ENUMERACIÓN PERIÓDICA DE ESTE BUCLE (07-27 noche). ERA TRABAJO DUPLICADO ===
    -- Con los dos arreglos anteriores ya validados (`scan-gallery` 819 -> 7, `scan-option` 200 -> 2), el
    -- reparto dejó un dominador claro: **288 de 515 atascos en `scan-findall`**, sobre todo en pantallas
    -- de batalla y selección, que tienen ~2070 widgets (el doble que un menú).
    -- Y al mirarlo con calma resulta que era REDUNDANTE: el bucle de POLL ya hace exactamente el mismo
    -- `FindAllOf("UserWidget")` cada 100ms para su propio churn guard (`P:wcount`), y este bucle lo hacía
    -- OTRA VEZ, también cada 100ms desde el throttle de antes. Dos recorridos completos de la lista de
    -- objetos, cada décima, para calcular el mismo número.
    -- Ahora este bucle LEE el conteo que publica el poll en vez de recalcularlo. **No se pierde nada de
    -- detección**: ambos iban ya al mismo ritmo de 100ms, así que la latencia para detectar una
    -- reconstrucción es idéntica; simplemente deja de pagarse dos veces.
    -- La enumeración de verdad solo se hace donde hace falta de verdad: justo antes del walk.
    local allWidgets = nil

    -- UI-rebuild churn guard. Returning to the story map / entering an episode battle
    -- rebuilds a whole widget tree WITHIN THE SAME WORLD, so CheckWorldTransition never
    -- sees it (no "Map changed") and no cooldown is armed — pollers then walk widgets
    -- mid-teardown, calling IsValid/HasKeyboardFocus/IsVisible on freed objects, and
    -- CRASH the game natively (crumbs F:pollfocus AND P:room). Detecting the rebuild via
    -- the widget COUNT is safe: it reads only the array length, never touches a churning
    -- widget. A big swing => a screen is being built; arm the SHARED uiChurnUntil so BOTH
    -- the focus loop AND the poll loop back off (~0.4s, self-extends while it churns).
    -- Normal menu moves change the count by only a few, so everyday navigation is
    -- unaffected. This runs on the 16ms focus loop, so the poll loop (100ms) sees the
    -- churn flag armed before its next run.
    -- En los ticks en que NO se enumeró no hay dato nuevo: se deja prev == count para que el swing salga
    -- 0 y ningún guardia se arme con información inventada. El siguiente muestreo (a los 100ms) evaluará
    -- el salto real acumulado.
    -- El conteo viene del bucle de POLL (`Trackers.widgetCount`), que ya lo calcula cada 100ms. Mientras
    -- no cambie, `prev == count` y ningún guardia se arma con información repetida.
    local count = Trackers.widgetCount or lastWidgetCount
    local prev = lastWidgetCount
    lastWidgetCount = count

    -- RESULT SCREEN fast-path (game-over/victory: WBP_GRP_BS_Result_02_DP_C). This screen keeps the
    -- battle scene loaded and CHURNING behind it, so the churn guards below would return nil and the
    -- retry/quit menu went unread (Iván 07-19). Its buttons (WBP_OBJ_BS_BTN_Result_1_C: BTN_1
    -- "Reintentar", BTN_2 "Salir") are FEW and stable, so — exactly like the char-select HitButton
    -- fast-path — scan ONLY those, BEFORE the churn guards, and NEVER fall through to the ~2170-widget
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
    -- el crash cayó con el foco en StartButton (clase WBP_Title_Button_C) en la pantalla de título.
    -- CAUSA: al arrancar el juego ya tiene ~1615 UserWidgets creados DE FONDO (a medio construir
    -- mientras cargan assets), aunque solo 8 sean visibles; el título NO tenía atajo => caía al WALK
    -- COMPLETO de esos 1615 y HasKeyboardFocus sobre uno a medio crear TRUENA. El título solo tiene
    -- 3 botones ESTABLES (Start/Option/Quit). Mismo patrón probado que result/char-select. SEÑAL
    -- VERIFICADA: WBP_Title_C sale en 11 entradas del volcado y NUNCA coexiste con el menú principal
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
        return nil  -- título presente: nunca caer al walk sobre los ~1615 widgets de la carga
    end
    -- Measured: normal menu navigation swings the UserWidget count by ~50-145; a full scene/
    -- map rebuild swings ~950-1075. The PARTIAL "Cambiar área" map reload swings LESS than 400
    -- (no guard fired during it) yet still churns TextBlocks internally, so PollStoryMap's scan
    -- crashed mid-reload (crumb P:storymap). Lowered the arm threshold 400 -> 200 to catch these
    -- partial reloads while keeping a safe margin above menu navigation (145). Swings of 100-199
    -- are logged (not armed) so the exact "Cambiar área" magnitude can be confirmed and the
    -- cutoff tuned if it turns out to sit below 200.
    local swing = math.abs(count - prev)
    -- Immediate arm for a single BIG swing (full screen/scene rebuild, ~950-1075).
    if prev > 0 and swing >= 200 then
        -- Big rebuilds keep churning UObjects for ~1s after the count stabilizes, so a flat
        -- 0.4s window expires mid-teardown and the next poller walks a half-destroyed widget
        -- and crashes. Give big swings a longer settle. During a reload there is nothing to
        -- read, so the pause loses no data.
        -- ≥800 = a full battle/scene REBUILD (chained story battles, transformations); these
        -- churn pawns for >1.5s, and PollHUD crashed (crumb P:hud) in the GAP between two such
        -- guards firing (1287->2174 then 2174->1266 during the Ginyu-force sequence). 2.5s closes
        -- that gap. Nothing to read mid-rebuild, so the longer pause loses no data.
        -- Long window ONLY in a real teardown context (battle / story map / cutscene). Everywhere
        -- else — menus, load screens, attract-cutscene banter, the gaps between screens — a short
        -- window keeps navigation responsive (see InDangerZone; fixes the Episode-Battle entry jank).
        -- MENÚ y SUB-MENÚS (07-20): la premisa "menus never crash" resultó FALSA. Salir de la TIENDA
        -- al menú principal tronó (crumb F:pollfocus, livelog termina en la tienda): el juego destruye
        -- los botones del sub-menú y RECONSTRUYE el menú, churneando varios segundos, pero la ventana
        -- corta de 0.3s soltaba el foco a media destrucción y escaneaba botones muertos. Se le da la
        -- ventana LARGA usando la banderita NO-NATIVA Trackers.onMainMenu (la setea PollFocus; cero
        -- llamadas nuevas al motor aquí). Flat 2.0 a propósito: NO 3.0 aunque el swing sea grande,
        -- porque el demo del menú reconstruye ~950-1075 y 3s alargaría la mudez sin necesidad.
        -- VENTANA DE SALIDA DE MENÚ (07-21): DOS crashes idénticos (10:02 y 10:30) al salir del menú
        -- principal hacia la Enciclopedia. El menú tarda ~2s en DESMONTARSE, pero en el instante en que
        -- ModeMenu desaparece, onMainMenu cae a false => la transición recibía solo 0.3s => el foco se
        -- soltaba a media destrucción => F:pollfocus. math.max NO bastaba: la ventana larga del demo ya
        -- había expirado antes del desmontaje. FIX: durante 2.5s DESPUÉS de dejar el menú, las
        -- transiciones siguen recibiendo ventana LARGA (2.0s). Ventana temporizada FAIL-SAFE, mismo
        -- patrón que InPostBattleTeardown. Cubre TODAS las salidas del menú (Enciclopedia, Tienda,
        -- Ajustes, char-select). Trade: la sub-pantalla lee ~2s más tarde mientras carga (no hay
        -- pérdida de datos: nada que leer en el teardown). El demo del menú NO reactiva esto tras salir
        -- (onMainMenu ya es false y no se re-marca), así que expira limpio a los 2.5s.
        local justLeftMenu = (os.clock() - _lastOnMainMenuClock) < 2.5
        local window
        if InDangerZone() then window = (swing >= 800) and 3.0 or 2.0
        elseif Trackers.onMainMenu or justLeftMenu then window = 2.0
        else window = 0.3 end -- short: select/transitions; keep navigation snappy
        print("[AE] UI churn guard: " .. prev .. " -> " .. count .. " (" .. window .. "s)")
        -- NUNCA ACORTAR un freno vigente (07-21). Crash F:pollfocus al salir del menú principal a la
        -- Enciclopedia: se armó 2.0s (onMainMenu=true) y al tick siguiente, cuando el menú YA se estaba
        -- yendo (onMainMenu=false), un swing menor armó 0.3s que PISÓ la ventana de 2.0s => el foco se
        -- soltó a media destrucción y escaneó widgets muertos. math.max conserva la protección más
        -- larga vigente. SEGURO en el menú: ahí todas las ventanas ya son 2.0s (misma rama onMainMenu),
        -- así que entre ellas math.max no cambia nada; el menú sigue leyendo en los huecos donde el
        -- conteo se calma y la ventana EXPIRA sola (math.max no impide expirar, solo impide acortar).
        -- Fail-safe: el tope real es 3.0s, nunca enmudece permanente.
        uiChurnUntil = math.max(uiChurnUntil, os.clock() + window)
        churnStreak = 0
        return nil
    end
    -- Sustained arm for a GRADUAL load: an episode/map load ramped the count by ~130/tick for
    -- 5+ ticks (771->907->1036->1166->1296->1426) — no single swing hit 200, yet a poller
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
    -- still gets read — worst case a slightly delayed read, never a permanently silent menu. A
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

    -- ENCICLOPEDIA fast-path (07-27). MISMO patrón ya probado tres veces (char-select, resultado, lista
    -- de comandos): en esta pantalla los elementos que TOMAN FOCO son POQUÍSIMOS, así que se escanean
    -- solo ellos en vez de caminar los ~1145 widgets de la escena.
    -- MEDIDO en el volcado `dump_0726_ajustes_ency.txt` (no supuesto): de todas las clases que tuvieron
    -- el foco en esa sesión, la MÁS frecuente fue `WBP_OBJ_Gallery_BTN_Menu_C` (15 entradas, 3 instancias
    -- por entrada) y también toma foco `WBP_OBJ_Gallery_CharacterList_Panel_C` (10 instancias). Ninguna
    -- de las dos está en `menuFastClasses` — y NO deben añadirse ahí (LECCIÓN 15: esa lista corre en
    -- TODAS las pantallas y crecerla disparó las muertes de foco). Aquí van gateadas por la galería, así
    -- que fuera de ella cuestan cero.
    -- POR QUÉ IMPORTA: 13 widgets contra 1145 es ~88x menos llamadas nativas en la pantalla donde más
    -- crashes hemos tenido, y además evita que la Enciclopedia dependa del walk — que es justo lo que el
    -- bloqueo anti-crash de más abajo va a frenar durante la entrada.
    -- FAIL-SAFE: si ninguno tiene el foco (submenús de música/escenarios, etc.) cae al walk de siempre,
    -- así que no puede enmudecer nada.
    -- OJO CON LA CONDICIÓN: el enfriamiento va EN EL `if` EXTERIOR a propósito. Si estuviera dentro con un
    -- `return nil`, un atajo enfriado ABORTARÍA el escaneo entero y el resto de atajos (incluido el del
    -- menú) no llegaría a correr — eso fue exactamente el fallo del 07-27 noche que dejó el menú hasta 1.5s
    -- sin leer y repitiendo la opción al recuperarse. Estando en el `if`, un atajo enfriado simplemente SE
    -- SALTA y el flujo continúa al siguiente. NO volver a meterlo dentro.
    -- LOS ENFRIAMIENTOS SE LIMPIAN DURANTE EL CHURN (07-27), aquí y no dentro de cada atajo: un churn
    -- significa cambio de pantalla, así que todos los atajos merecen volver a probar cuando se asiente.
    -- ENFRIAMIENTO SUBIDO DE 1.5s A 30s (07-27 noche, con dato). El DIAG del menú principal enseñó el
    -- patrón en bucle: un atasco de `scan-option` de 0.5 a 1.34s CADA segundo y medio — 39 de los 157
    -- atascos de la sesión. Es el atajo de Ajustes ejecutándose EN EL MENÚ (su gate por presencia se
    -- cumple ahí, LECCIÓN 14) y pagando CUATRO recorridos completos de la lista de objetos por intento.
    -- Con 1.5s ese peaje se cobraba 40 veces por minuto para comprobar algo que casi nunca es cierto.
    -- POR QUÉ 30s NO RETRASA NADA: el reset de aquí abajo dispara con CUALQUIER churn, y entrar a Ajustes,
    -- la Tienda o la Enciclopedia mueve cientos de widgets, así que siempre hay churn y el atajo se
    -- reactiva al instante. Los 30s solo se agotan si alguna vez se entrara a una de esas pantallas SIN
    -- churn: caso improbable y, aun así, fail-safe (se leería por el walk, más lento pero se leería).
    if os.clock() < uiChurnUntil then
        _galMissUntil, _optMissUntil, _shopMissUntil = 0, 0, 0
    end

    -- === EL SETTLE TAMBIÉN VA EN EL `if` EXTERIOR (07-27 noche). MEDIDO, no supuesto ===
    -- El DIAG de retraso dio 11 medidas entre 0.59s y 1.00s **todas con `fallos=0`**, o sea el recorrido
    -- del menú acertaba A LA PRIMERA y aun así se perdían ~0.6s. Ese número es exactamente el settle
    -- post-churn de estos atajos. La causa: el settle estaba DENTRO del bloque con un `return nil`, y como
    -- el gate por presencia se cumple en TODAS las pantallas (LECCIÓN 14), el settle de una pantalla en la
    -- que NI SIQUIERA ESTAMOS abortaba el escaneo del menú durante 0.6s después de cada churn.
    -- Puesto en el `if` exterior hace lo que su propósito pide —no tocar los botones de una pantalla que
    -- está naciendo— sin secuestrar el escaneo de las demás. El walk sigue protegido por el freno de churn
    -- del bucle y por el bloqueo del walk del menú.
    if H.GetCachedFirstOf("WBP_GRP_Gallery_PictureBook_C") and os.clock() >= _galMissUntil
       and os.clock() >= uiChurnUntil + 0.6 then
        -- SETTLE POST-CHURN (07-27 tarde). EVIDENCIA: el crash de las 14:27:20 dejó la migaja `F:sf-gal`,
        -- o sea AQUÍ DENTRO, y el livelog enseña por qué: `UI churn guard: 1756 -> 1148 (2.0s)` a las
        -- 14:27:18 (la Enciclopedia naciendo) y `churn=true` en TODAS las líneas hasta el segundo del
        -- crash. La ventana de 2.0s expiró justo cuando la pantalla AÚN se estaba construyendo, el bucle
        -- de foco se soltó de golpe y este atajo fue derecho a preguntarle `HasKeyboardFocus` a unos
        -- botones a medio nacer. Es el riesgo que ya se anotó al añadir este atajo (LECCIÓN 15 aplicada a
        -- un atajo propio): tocar los botones de una pantalla que está naciendo o muriendo.
        -- El freno de churn no basta porque expira por TIEMPO, no porque la pantalla esté lista. Con
        -- medio segundo más de margen tras el churn, el árbol ya está montado.
        -- `return nil` (NO seguir al walk): si aquí no es seguro mirar 13 botones, muchísimo menos lo es
        -- caminar los ~1145 de la escena. Fail-safe y temporizado: 0.6s después se lee normal.
        -- === MI ERROR DE DISEÑO, MEDIDO (07-27 noche) ===
        -- El DIAG dio **819 de 918 atascos AQUÍ**, el 89%, tras un rato largo en la Enciclopedia. Y la
        -- causa es un fallo de razonamiento mío al crear este atajo: yo conté WIDGETS TOCADOS (13 en vez
        -- de 1145) y di por hecho que eso era el coste. **`FindAllOf(clase)` NO cuesta en proporción a los
        -- resultados: recorre la lista COMPLETA de objetos del juego para filtrarlos.** Así que este
        -- atajo hacía DOS recorridos completos por tick (uno por clase) — o sea, en la parte de búsqueda
        -- podía costar MÁS que el walk, que hace UNO solo. Ahorré en lo barato y pagué el doble en lo caro.
        -- FIX, el mismo patrón que ya funcionó en el menú: preguntarle primero al panel que YA tenía el
        -- foco. En la Enciclopedia eso acierta casi siempre — al pasar personajes con RB/LB el foco de
        -- teclado NI SIQUIERA SE MUEVE (por eso existe el poller de gallery.lua) — así que la inmensa
        -- mayoría de los ticks se resuelven con DOS llamadas y CERO recorridos de la lista de objetos.
        if _lastGalleryWidget then
            if not IsValidRef(_lastGalleryWidget) then
                _lastGalleryWidget = nil  -- murió: se cae al escaneo normal de abajo
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
        -- SEÑAL DE SALIDA POR PÉRDIDA DE FOCO (07-27), mismo patrón que ya funcionó en el menú principal:
        -- dentro de la Enciclopedia el foco SIEMPRE está en uno de estos elementos (el volcado lo
        -- confirma: `Gallery_BTN_Menu` fue la clase más enfocada de la sesión). Que de golpe NINGUNO lo
        -- tenga es la firma de que la pantalla se está desmontando porque pulsaste B. En ese instante,
        -- seguir bajando a los demás escaneos y al walk de ~1145 widgets es puro riesgo y cero beneficio:
        -- no hay nada que leer en una pantalla que se está muriendo. Se corta aquí.
        -- FAIL-SAFE: ventana temporizada (LECCIÓN 11). Si de verdad no hay foco por otro motivo, a los
        -- 0.8s se suelta y el escaneo normal vuelve a correr; no puede enmudecer nada.
        if (os.clock() - _lastGalleryFastHitClock) < 0.8 then return nil end
        _galMissUntil = os.clock() + 30  -- nadie con foco => no estamos en la Enciclopedia; no insistir
    end

    -- AJUSTES fast-path (07-27). Iván reportó que navegar Ajustes "se siente un poco lento". La causa de
    -- fondo NO era solo el bloqueo del walk (ya acortado a 0.8s): es que las OPCIONES de Ajustes dependen
    -- del walk completo, ~1148 widgets a cada tick de 16ms, porque sus clases no están en ningún atajo.
    -- Las pestañas (`WBP_OBJ_Option_List_004_C`) sí están en `menuFastClasses` y por eso siempre se
    -- sintieron ágiles; las opciones de dentro, no. Esto lo iguala.
    -- CLASES VERIFICADAS en el volcado `dump_0726_ajustes_ency.txt` (las que REALMENTE tomaron el foco):
    -- `WBP_OBJ_Option_List_010_Text_C` (4 veces; son las 12 opciones de Accesibilidad tipo Asistencia de
    -- batalla) y `WBP_OBJ_Option_List_011_Gauge_C` (3 veces; los volúmenes de Sonido — LA pantalla que se
    -- rompió el 07-21 justamente por bloquearle el walk). Se añade también `WBP_OBJ_Option_List_002_C`
    -- (DataDelete), visible en el mismo volcado.
    -- Gate `WBP_Option_C`, verificado presente en Ajustes el 07-26 (es el contenedor con TitleText
    -- "Opciones" y Text_CategoryTitle). Fuera de Ajustes no cuesta nada. Fail-safe: si nada tiene el foco,
    -- cae al walk de siempre. NO se añaden a `menuFastClasses` (LECCIÓN 15: esa lista corre en TODAS las
    -- pantallas); van gateadas por la suya.
    -- Enfriamiento en el `if` EXTERIOR: ver la nota del atajo de la Enciclopedia. Un atajo enfriado se
    -- SALTA, nunca aborta el escaneo.
    -- Settle y enfriamiento en el `if` EXTERIOR: ver la nota del atajo de la Enciclopedia.
    if H.GetCachedFirstOf("WBP_Option_C") and os.clock() >= _optMissUntil
       and os.clock() >= uiChurnUntil + 0.6 then
        -- === BUG PROPIO CORREGIDO (07-27 noche). LECCIÓN 14, y la cometí yo el mismo día ===
        -- Iván: "el menú principal más pesado, 3 o 4 segundos en nombrar cada cosa". EVIDENCIA: 4 cuelgues
        -- del bucle de foco en 3 minutos, DOS de ellos con `focusStage=scan-option` — y en TODA esa sesión
        -- no se salió del menú principal (el livelog solo tiene los dos churn del arranque, ninguna
        -- transición). O sea: este atajo se estaba ejecutando EN EL MENÚ, donde Ajustes no está en
        -- pantalla, tocando widgets de Ajustes que existen en memoria pero no se muestran. Esos cuelgues
        -- de 1.5-3s son exactamente el retraso que Iván oye. **`GetCachedFirstOf` responde "EXISTE", no
        -- "ESTÁ EN PANTALLA"** — usar presencia como gate de pantalla es el error que la LECCIÓN 14
        -- describe, y lo repetí al crear estos atajos.
        -- NO se arregla con IsVisible: sobre contenedores en teardown es justamente lo que cuelga
        -- (LECCIÓN 1, y los 224 colgones del 07-19). Se arregla con la señal que YA tenemos gratis: si el
        -- atajo no encuentra foco, es que NO estamos en su pantalla, así que se enfría 1.5s en vez de
        -- reintentar 62 veces por segundo. Cuando de verdad entras a Ajustes, el primer intento acierta y
        -- el enfriamiento no llega a armarse. Y en cada cambio de pantalla (settle de arriba) se limpia,
        -- para que entrar a Ajustes nunca herede un enfriamiento viejo.
        _focusStage = "scan-option"
        -- `WBP_OBJ_Option_List_004_C` (las PESTAÑAS de Ajustes) se MUEVE aquí desde `menuFastClasses`
        -- (07-27). Estaba en la lista global, que corre en TODAS las pantallas; aquí solo corre en Ajustes.
        -- Con esto la lista global baja a 4 clases (empezó en 6) y el menú principal paga menos por tick.
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

    -- TIENDA fast-path (07-27). ARREGLA UN BUG REPORTADO Y ADEMÁS ADELGAZA LA LISTA GLOBAL.
    -- Iván: "cuando entro a la tienda y cambio entre shop y customize, solo nombra a shop". CAUSA
    -- ENCONTRADA EN EL VOLCADO (no supuesta): son DOS clases distintas, `WBP_OBJ_SH_BTN_Shop_C` (tuvo el
    -- foco 7 veces) y `WBP_OBJ_SH_BTN_Customize_C` (3 veces) — y solo la PRIMERA estaba en
    -- `menuFastClasses`. Con el foco en Customize el atajo global fallaba, se enfriaba, y como el bloqueo
    -- del walk se apoya en ese enfriamiento, no quedaba NADIE escaneando: silencio total en esa pestaña.
    -- Esto explica de paso parte de la lentitud que Iván nota: cada vez que el foco cae en algo que el
    -- atajo global no cubre, se dispara el enfriamiento y el walk se retiene.
    -- LO CORRECTO NO ERA CRECER LA LISTA GLOBAL (LECCIÓN 15: eso subió las muertes de foco de 2 a 12),
    -- sino MOVER la tienda a su propio atajo gateado — y de paso `WBP_OBJ_SH_BTN_Shop_C` SALE de la lista
    -- global, que baja de 6 clases a 5. La lista global se ADELGAZA, que es justo lo que pide la lección.
    -- Clases verificadas en el volcado: Shop (1 instancia), Customize (1), Category_00 (7) e ItemIcon_S00
    -- (16, los artículos del catálogo; uno tuvo el foco). Máximo ~25 widgets contra los ~1145 del walk.
    -- Gate `WBP_GRP_SH_Top_C`: aparece en 11 entradas, las mismas que los dos botones => está presente en
    -- toda la tienda. Con settle post-churn DESDE EL PRIMER DÍA (patrón aprendido hoy a golpes).
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
    -- previews (the command-list lag Iván reported). Falls through to the full walk if none is focused
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

    -- MENU BUTTON fast-path: en el menú principal (y Shenron) el walk completo (~1762 widgets con la
    -- escena del demo cargada) va LENTO y tropieza (los ~10s de retraso + pesadez al volver de pelea,
    -- 07-20). Los botones focables son POCOS y de clases CONFIRMADAS EN VIVO, así que escanea SOLO
    -- esos, como los atajos de char-select / lista de comandos. CAE al walk completo si ninguno tiene
    -- foco (NUNCA mudea). La repetición que esto causaba antes ya se arregló aparte (preserveDedup).
    -- WBP_OBJ_Option_List_004_C = botones de AJUSTES (Options). Ajustes es un SUB-MENÚ del principal
    -- (WBP_MainMenu_ModeMenu_C sigue presente => onMainMenu=true => el return-nil de abajo bloquea el
    -- walk), así que sin su clase aquí, Ajustes quedaba MUDO (regresión 07-20 de mi cambio del menú).
    -- NO CRECER ESTA LISTA (medido 07-20, evidencia dura): agregar 3 clases (Option_List_010_Text/
    -- Text2 + SH_BTN_Customize) subió las muertes del bucle de FOCO de 2 a 12 en una sola sesión, y
    -- las 12 con focusStage=scan-menubtn. Motivo: este atajo corre a 16ms y hace UN GetCachedFirstOf
    -- + FindAllOf POR CLASE; 9 clases = ~540 consultas nativas por segundo en el punto más caliente.
    -- Peor: las clases de Tienda/Ajustes hacen que al SALIR de esas pantallas el atajo vaya a buscar
    -- justo los botones que el juego está destruyendo => cuelgue nativo (LECCIÓN 1). Cada cuelgue =
    -- reinicio del watchdog = el silencio de 13-20s que reporta Iván. Los sub-menús NO se arreglan
    -- enumerando clases aquí (whack-a-mole): se arreglan dejando que el walk completo los lea (abajo).
    -- NOTA 07-22: se probó quitar `WBP_OBJ_Option_List_004_C` culpándola del crash al entrar a sub-menús de
    -- Ajustes, pero era CORRELACIÓN (el foco estaba ahí), no causa probada: esa clase lleva desde el 07-20
    -- aquí SIN causar ese crash. RESTAURADA. La sospecha real pasa al código NUEVO del lector de valores
    -- (ver PollOptionValue, desactivado para el experimento limpio).
    -- 07-27: `WBP_OBJ_SH_BTN_Shop_C` SALE de aquí — la tienda pasa a tener su propio atajo gateado (ver
    -- `scan-shop` arriba), que además cubre Customize, que aquí faltaba. La lista global baja de 6 a 5
    -- clases: menos consultas por tick en TODAS las pantallas, que es exactamente lo que pide la LECCIÓN 15.
    local menuFastClasses = { "WBP_OBJ_MainMenu_BTN_Sub1_C", "WBP_MainMenu_Base_C", "WBP_OBJ_WishSR_BTN_Sub_C", "WBP_OBJ_WishSR_BTN_Talk_C" }
    -- Subconjunto: las clases del MENÚ PRINCIPAL PELÓN. Verificado en el volcado del 07-27: son
    -- exactamente las tres que tuvieron el foco en el menú justo antes del crash (BTN_Sub1, MainMenu_Base
    -- y WishSR_BTN_Sub). `Option_List_004` (Ajustes) y `SH_BTN_Shop` (Tienda) quedan FUERA a propósito.
    -- NO buscar los botones del MENÚ durante la VENTANA DE SALIDA (07-22). CRASH F:pollfocus al entrar a
    -- EPISODIO DE BATALLA (y a Historia): el foco estaba en `WBP_OBJ_MainMenu_BTN_Sub1` — que está en esta
    -- lista — y al pulsar A esos botones se DESTRUYEN para cargar el modo, mientras este atajo va justo a
    -- buscarlos (FindAllOf + HasKeyboardFocus sobre botones en teardown) => cuelgue nativo. Mismo mecanismo
    -- de la LECCIÓN 15, ahora con las clases del MENÚ PRINCIPAL. Gate idéntico al del skip del foco loop:
    -- `not Trackers.onMainMenu` es CLAVE — DENTRO del menú (onMainMenu=true) el atajo SIGUE corriendo, así
    -- que el menú NO pierde agilidad; solo se omite en los 2.5s posteriores a DEJARLO, cuando esos botones
    -- ya no sirven de nada. Si no hay atajo, cae al walk (que sí lleva el 2º IsValidRef pegado a la nativa).
    -- === FRENO AL PROPIO ATAJO (07-27). EVIDENCIA DIRECTA, no teoría ===
    -- El watchdog capturó un CUELGUE 3 segundos antes del crash fatal con
    -- `focusStage=scan-menubtn` — o sea, AQUÍ DENTRO — y el crash fatal dejó la misma migaja `F:pf-fast`.
    -- Además ese cuelgue ocurrió con el menú ASENTADO (wc=1755, churn=false), así que no hace falta ni
    -- una transición para que este atajo se atragante. Es la LECCIÓN 15 en vivo.
    -- EL PROBLEMA DE FONDO: cuando el atajo SÍ halla el botón enfocado hace `return` inmediato y toca
    -- poquísimo. Pero cuando NO lo halla —justo lo que pasa en el instante en que pulsas A y los botones
    -- del menú se están destruyendo— recorre las SEIS clases, con un `FindAllOf` y un `HasKeyboardFocus`
    -- por cada botón de cada una: decenas de llamadas nativas sobre widgets moribundos, 62 veces por
    -- segundo mientras dura el desmontaje (~2s = más de cien pasadas). Máxima exposición en el peor
    -- momento posible.
    -- EL FRENO: en cuanto una pasada falla, no se vuelve a intentar durante 0.8s. Eso convierte esas
    -- ~120 pasadas del desmontaje en 2 o 3. No cambia NADA cuando el menú está sano (ahí el atajo acierta
    -- y ni siquiera llega al final del bucle), y es FAIL-SAFE (LECCIÓN 11): si el foco vuelve a un botón,
    -- a los 0.8s se reintenta y lo encuentra. Coste peor caso: recuperar el foco en el menú hasta 0.8s
    -- más tarde tras un hueco.
    -- NO se toca el ORDEN ni el CONTENIDO de `menuFastClasses` (LECCIÓN 15: no crecerla, no reordenarla).
    local justLeftMenuScan = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5

    -- === ATAJO CACHEADO DEL MENÚ (07-27). LA SOLUCIÓN DE FONDO, no otro parche de ventana ===
    -- POR QUÉ HACÍA FALTA: `scan-menubtn` ya se colgó dos veces (watchdog 14:05:07 y 14:39:44) y por fin
    -- MATÓ el juego a las 14:55:30 (migaja `F:sf-menubtn`, menú asentado en wc=1755 y sin churn, o sea al
    -- pulsar A). El enfriamiento progresivo NO puede salvarlo: el crash ocurre en la PRIMERA pasada
    -- fallida, y el enfriamiento solo evita de la segunda en adelante. No hay ninguna señal previa que
    -- mirar, así que hay que atacar el COSTE, que es lo que en este proyecto siempre ha funcionado.
    -- LA CUENTA: recorrer las clases cuesta, por tick, un GetCachedFirstOf + un FindAllOf + dos IsValidRef
    -- y un HasKeyboardFocus POR BOTÓN (unos 8 en el menú) => del orden de 24 llamadas nativas. Preguntarle
    -- a la ref que YA tenía el foco cuesta DOS. Doce veces menos superficie de choque, y de paso el menú
    -- va más rápido (justo lo que pidió Iván).
    -- Y LO IMPORTANTE: `IsValidRef` sobre esa única ref es la forma MÁS BARATA de enterarse de que el
    -- botón murió. Si murió, estamos en el desmontaje: se corta el tick AHÍ MISMO, sin FindAllOf ni
    -- HasKeyboardFocus sobre nada. Antes ese descubrimiento se hacía a base de tocar los 8 botones.
    -- SOBRE LA DECISIÓN DEL 07-21 (se prohibió el atajo cacheado de PollFocus en el menú porque tronó al
    -- SALIR con la ref del menú muerto): esto NO la revierte. Aquel corría también DESPUÉS de que
    -- `onMainMenu` cayera; este solo corre CON `onMainMenu` true, y la salida sigue cubierta por
    -- `justLeftMenu`, el enfriamiento y el bloqueo del walk. Además revalida antes de cada uso.
    -- Por defecto se asume que el menú NO está vivo; solo la comprobación de abajo puede confirmarlo. Así,
    -- si no hay ref cacheada (recién arrancado, o acaba de morir), el bloqueo del walk mantiene su
    -- protección; y en cuanto se confirma que el botón vive, el walk queda libre para buscar el foco donde
    -- el atajo no llega (el menú de avisos, por ejemplo). Ver la nota del bloqueo del walk.
    _menuLooksAlive = false
    if Trackers.onMainMenu and _lastMenuFastWidget then
        if not IsValidRef(_lastMenuFastWidget) then
            -- El botón que tenía el foco YA NO EXISTE => el menú se está desmontando. Cortar el tick sin
            -- tocar ni un widget más, y armar el enfriamiento para que el resto del desmontaje no insista.
            _lastMenuFastWidget = nil
            _menuFastMissStreak = _menuFastMissStreak + 1
            local coolD = 0.15 * (2 ^ math.min(_menuFastMissStreak - 1, 3))
            if coolD > 0.8 then coolD = 0.8 end
            _menuFastMissUntil = os.clock() + coolD
            return nil
        end
        _menuLooksAlive = true  -- el botón del menú SIGUE VIVO: el menú no se está desmontando
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
        -- El atajo cacheado NO cubrió el crash y ahora sé por qué: cuando pulsas A, el juego primero le
        -- QUITA el foco al botón y luego lo destruye. Así que el botón cacheado sigue VIVO pero ya sin
        -- foco — exactamente el mismo estado que cuando mueves el stick — y el flujo caía al recorrido de
        -- clases, que es donde murió (migaja `F:sf-menubtn`).
        -- No hay forma de distinguir "moviste el stick" de "pulsaste A" en ese instante... pero NO HACE
        -- FALTA ADIVINAR: basta con ESPERAR 50ms (3 parpadeos) antes de ir a buscar. Si pulsaste A, en
        -- esos 50ms el conteo de widgets ya se mueve y el freno de churn (o el small-churn guard) corta el
        -- tick ANTES de llegar aquí. Si solo moviste el stick, a los 50ms se busca normal y se lee.
        -- COSTE REAL: 50 milésimas de retraso al cambiar de botón en el menú. NVDA tarda más que eso en
        -- arrancar a hablar, así que es inaudible. Y a cambio, el recorrido peligroso deja de ejecutarse
        -- justo en el instante del pulsado, que es el único momento en que ha matado.
        -- Esto es esperar a que la señal LLEGUE en vez de intentar predecirla — el mismo principio que
        -- ya funcionó con el settle post-churn de los atajos de pantalla.
        if _menuFocusLostAt == 0 then _menuFocusLostAt = os.clock() end
        if (os.clock() - _menuFocusLostAt) < 0.05 then return nil end
    end

    if not justLeftMenuScan and os.clock() >= _menuFastMissUntil then
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
                                -- SELLO DEL MENÚ PRINCIPAL (07-27, ver el bloqueo del walk más abajo).
                                -- Solo con las clases del menú PELÓN, NUNCA con las de Ajustes/Tienda:
                                -- si se sellara con `Option_List_004` (las pestañas de Ajustes), al bajar
                                -- a Sonido el walk quedaría bloqueado y se repetiría la regresión del
                                -- 07-21 ("Sonido tarda mucho y repite la opción").
                                if MENU_MAIN_CLASSES[cls] then _lastMenuFastHitClock = os.clock() end
                                -- DIAG TEMPORAL DE RETRASO (07-27, quitar al cerrar el caso de la lentitud).
                                -- Mide lo que de verdad importa: cuánto pasó entre que el botón anterior
                                -- perdió el foco y este quedó leído. Solo imprime si supera 0.2s, así que
                                -- en navegación sana no ensucia el log. Si sale mucho y con valores altos,
                                -- el tiempo se va en los frenos; si no sale, la lentitud viene de otro lado
                                -- y hay que buscarla fuera del bucle de foco.
                                if _menuFocusLostAt > 0 then
                                    local lag = os.clock() - _menuFocusLostAt
                                    if lag >= 0.2 then
                                    end
                                end
                                _menuFastMissStreak = 0  -- acertó: el enfriamiento vuelve a cero
                                _menuFocusLostAt = 0     -- foco recuperado: la espera de 50ms se reinicia
                                _lastMenuFastWidget = w  -- para el atajo cacheado del menú (ver arriba)
                                return w
                            end
                        end
                    end
                end
            end
        end
        -- Pasada COMPLETA sin encontrar foco: o el menú se está desmontando, o el foco está en algo que
        -- este atajo no cubre. En ambos casos repetir la búsqueda cada 16ms no aporta nada y es justo lo
        -- que cuelga.
        -- ENFRIAMIENTO PROGRESIVO (07-27, tras el reporte de Iván: "siento el menú principal menos ágil...
        -- tarda más segundos en leerme"). El enfriamiento FIJO de 0.8s era el culpable: un solo fallo
        -- aislado —normal al moverse entre botones o al pasar el foco por algo no cubierto— frenaba el
        -- atajo Y, por dependencia, también el walk, así que la siguiente lectura llegaba casi un segundo
        -- tarde. Ahora arranca en 0.15s (imperceptible) y solo se va doblando si los fallos SIGUEN
        -- llegando, que es la firma del desmontaje: 0.15, 0.3, 0.6 y tope 0.8.
        -- Así se conserva lo que importa —durante los ~2s de un desmontaje se pasa de ~120 pasadas a unas
        -- pocas— sin castigar la navegación normal, donde los fallos son sueltos y el contador se pone a
        -- cero en cuanto el atajo vuelve a acertar.
        -- ENFRIAMIENTO REDUCIDO A 0.05s FIJO (07-27 noche). Iván sigue notando el menú lento, pero esta
        -- sesión tuvo **CERO cuelgues** (antes 4 en 3 minutos), así que el retraso que le queda YA NO son
        -- cuelgues: es tiempo de espera que pongo yo. Y el mayor sospechoso es este enfriamiento, que con
        -- el backoff llegaba a 0.8s: si al mover el stick el juego tarda un pelín en asignar el foco al
        -- botón siguiente, la pasada falla y el mod se queda callado 0.15s, luego 0.3s, luego 0.6s...
        -- POR QUÉ AHORA SE PUEDE BAJAR SIN PERDER PROTECCIÓN: el enfriamiento nació para no repetir ~120
        -- pasadas durante el desmontaje del menú, pero ese trabajo lo hace YA la espera de 50ms de arriba
        -- (que impide el recorrido justo en el instante del pulsado) y, pasado ese instante, el freno de
        -- churn congela el bucle entero. El enfriamiento largo había quedado redundante y solo cobraba
        -- peaje en la navegación normal. Con 0.05s sigue habiendo tope de insistencia (20 pasadas por
        -- segundo en vez de 62) sin que se oiga.
        -- Si volviera a crashear en `scan-menubtn`, esto es lo PRIMERO a revisar.
        _menuFastMissStreak = _menuFastMissStreak + 1
        _menuFastMissUntil = os.clock() + 0.05
    end

    -- QUITADO 07-20 (era la RAÍZ de la mudez de sub-menús). Aquí había un
    --     if H.GetCachedFirstOf("WBP_MainMenu_ModeMenu_C") then return nil end
    -- para no caminar los ~1762 widgets de la escena del demo. PERO Ajustes, Tienda y demás son
    -- SUB-MENÚS del principal: ModeMenu sigue presente en ellos => el return-nil los tapaba y los
    -- dejaba MUDOS salvo que su clase estuviera enumerada arriba (whack-a-mole infinito: leían los
    -- interruptores de activar/desactivar y no los de subir/bajar, que son otra clase). Iván señaló
    -- el dato clave: esas pantallas SÍ leían antes de esta línea. El walk completo las lee TODAS solo.
    -- Por qué es razonable volver a él AHORA (no es revertir a ciegas): (1) cuando esta línea se puso,
    -- el foco leía DURANTE el churn (bypass) y por eso el walk tronaba en las cargas; ese bypass ya
    -- NO existe, el foco se frena por churn; (2) hoy el menú recibe ventana LARGA de 2.0s, así que el
    -- walk solo corre con la pantalla ASENTADA; (3) el walk hace UNA sola consulta nativa (un
    -- FindAllOf) contra las ~9 por tick del atajo, que es lo que estaba colgando el bucle.
    -- Si volviera a crashear al entrar a sub-menús, esta línea es lo primero a restaurar.
    -- FRENO FINO DEL WALK EN ZONA DE MENÚS (07-20). EVIDENCIA: crash F:pollfocus al entrar a Episodio
    -- de Batalla; el volcado guardó los 12 instantes previos y los 2 últimos (2s antes) muestran los
    -- widgets visibles desplomándose 42 -> 9 -> 8 y NADA enfocado = el menú desmontándose. El churn
    -- guard grande no lo atrapa: solo arma con saltos >=200, y un desmontaje que mata widgets de a
    -- pocos se le cuela. Aquí el walk (1762 widgets) camina objetos a medio liberar y truena.
    -- POR QUÉ ES SEGURO NO CAMINAR AQUÍ: en el menú principal pelón el ATAJO de botones (arriba) ya
    -- devolvió el botón enfocado — el volcado lo confirma (foco en WBP_OBJ_MainMenu_BTN_Sub1_C en
    -- todas las entradas con el menú normal). El walk solo entra cuando el atajo NO halló foco, que
    -- en el menú es justo el hueco del desmontaje: puro riesgo, cero beneficio. En sub-menús
    -- (Ajustes/Tienda) el walk SÍ es indispensable, y ahí solo se aplaza 16ms por tick movido.
    -- `swing` y `count` salen de la LONGITUD del arreglo: cero llamadas nativas nuevas.
    -- TOPE ANTI-MUDEZ (LECCIÓN 6: un freno sin salida deja el lector mudo PARA SIEMPRE): tras 8 ticks
    -- frenados se camina igual y el contador se reinicia. Con movimiento sostenido eso da 1 walk cada
    -- ~9 ticks (~144ms) — baja muchísimo la exposición SIN poder enmudecer nunca.
    -- REVERTIDO 07-22: el intento del 07-21 de bloquear el walk SIEMPRE (quitando `swing ~= 0`, para
    -- reducir el crash del menú principal) fue una REGRESIÓN: los sub-menús de Ajustes PROFUNDO (Sonido,
    -- clase Option_List_011_Gauge que NO está en el fast-path) DEPENDEN del walk cada tick, y bloquearlo
    -- 8 de cada 9 ticks los volvió LENTOS y con re-lectura (Iván: "Sonido tarda mucho y repite la opción";
    -- 0 loops died => no era cuelgue, era el freno). Vuelve a `swing ~= 0`: el freno solo bloquea el walk
    -- durante CHURN (transición/reconstrucción); en un sub-menú ESTABLE (swing==0) el walk corre cada tick
    -- => Sonido lee rápido de nuevo. COSTO: el crash del menú principal (walk sobre la escena del demo con
    -- conteo estable) vuelve a ser residual intermitente — se prioriza la lectura de Ajustes (constante y
    -- usada) sobre ese crash raro. Vía de fondo pendiente sigue siendo la BASE COMÚN de botones.
    -- === EL FIX DEL CRASH `F:menuwalk` (07-27) ===
    -- EVIDENCIA (crash al entrar a la Enciclopedia, 12:56:09): migaja del foco = `F:menuwalk`, o sea
    -- murió AQUÍ, caminando los ~1762 widgets del menú. El volcado F5 de esa misma sesión enseña por qué:
    -- en las entradas previas el foco estaba en botones del menú (`WBP_OBJ_MainMenu_BTN_Sub1_01` a las
    -- 12:56:06) y en la ÚLTIMA entrada, 12:56:08, NO HAY FOCO NINGUNO — el menú desmontándose tras pulsar
    -- A. Sin foco, el atajo de arriba no halla nada y el flujo cae a este walk, justo sobre los widgets
    -- que se están liberando. Y el bloqueo de abajo no actuó porque el conteo aún no se había movido
    -- (`swing == 0`): el livelog no tiene ni una línea de churn antes del crash.
    -- LA SEÑAL BUENA NO ES EL CONTEO, ES EL FOCO. En el menú sano el atajo SIEMPRE halla el botón
    -- enfocado (y hace return, sin llegar aquí); que de golpe no halle nada ES la firma del desmontaje.
    -- Por eso basta con recordar cuándo fue la última vez que el atajo acertó en una clase del menú
    -- PELÓN: si fue hace un instante y ahora no hay nada, estamos en el hueco peligroso y NO se camina.
    -- POR QUÉ NO REPITE LA REGRESIÓN DEL 07-21 (Sonido lento y repitiendo): aquel intento bloqueaba el
    -- walk SIEMPRE que `onMainMenu` fuera true, y `onMainMenu` también es true en los sub-menús, así que
    -- mataba a Sonido, que DEPENDE del walk (su clase `Option_List_011_Gauge` no está en ningún atajo —
    -- confirmado en el volcado: tuvo el foco 3 veces). Aquí el sello SOLO se pone con las clases del menú
    -- pelón, que en Sonido no se enfocan nunca; su reloj queda viejo y el walk corre igual que hoy.
    -- FAIL-SAFE: es una ventana temporizada (LECCIÓN 11). Si el menú desaparece de verdad, nadie vuelve a
    -- sellar el reloj y a los 2.0s el walk se suelta solo. No puede enmudecer nada de forma permanente.
    -- COSTO ACEPTADO: al entrar del menú a un modo, el walk se aplaza hasta 2.0s. La Enciclopedia ya no
    -- lo nota (tiene su propio atajo, añadido arriba) y las pestañas de Ajustes/Tienda tampoco (están en
    -- `menuFastClasses`). Reversible: borrar este bloque.
    -- === VERSIÓN 3 DE ESTE BLOQUEO (07-27 tarde). ERROR PROPIO CORREGIDO ===
    -- Historia, porque la lección importa: v1 usaba 2.0s desde el último acierto del atajo y funcionó
    -- contra el walk, pero ralentizó Ajustes (que entonces dependía del walk). v2 bajó a 0.8s... y el
    -- crash `F:menuwalk` VOLVIÓ. CAUSA, y fue culpa de una interacción que yo mismo introduje: el
    -- enfriamiento del atajo (`_menuFastMissUntil`) hace que, tras fallar, el atajo NO se vuelva a
    -- ejecutar durante 0.8s — y como el atajo es quien SELLA `_lastMenuFastHitClock`, el sello deja de
    -- refrescarse y a los 0.8s este bloqueo se soltaba... justo en mitad del desmontaje del menú, que
    -- dura ~2s. O sea: mi propio arreglo del atajo abrió la puerta del walk. Verificado en el volcado del
    -- 07-27 14:21: foco en `WBP_OBJ_MainMenu_BTN_Sub1_01` hasta las 14:21:18 y SIN FOCO en la entrada de
    -- las 14:21:21, el segundo del crash.
    -- v3 mira las DOS señales, no solo el sello: se bloquea también mientras el atajo esté ENFRIADO (que
    -- es tanto como decir "el atajo acaba de fallar", o sea estamos en el hueco). Como el atajo reintenta
    -- cada 0.8s y vuelve a fallar mientras el menú se desmonta, el enfriamiento se renueva y el bloqueo
    -- aguanta los ~2s completos, sin depender de un número fijo.
    -- Y la ventana del sello vuelve a 2.5s: ya NO penaliza a Ajustes, porque Ajustes tiene desde hoy su
    -- propio atajo (`scan-option`) y no depende del walk. Ese era el motivo de haberla acortado.
    -- TOPE ANTI-MUDEZ OBLIGATORIO (LECCIÓN 6): un freno sin salida enmudece PARA SIEMPRE. Si en el menú
    -- llegara a haber un elemento enfocable que ningún atajo cubre (p.ej. un diálogo de confirmación), el
    -- atajo fallaría siempre y sin tope no se leería jamás. Con el tope, tras ~1.9s se camina igual y se
    -- lee; el contador se reinicia en cuanto el walk corre una vez.
    -- === REGRESIÓN CORREGIDA (07-28). Iván: "el menú del botón X, el de los avisos, ya no lo lee" ===
    -- CAUSA, verificada en el volcado: en ese menú el foco lo tienen `WBP_OBJ_Present_MailTitle_C` (8
    -- focos), `WBP_GRP_PresentBox_Main_C` y `WBP_OBJ_OLB_MenuBTN_C` — **ninguna está en `menuFastClasses`
    -- ni en ningún atajo**, así que esa pantalla SIEMPRE ha dependido del walk. Y yo bloqueé el walk en el
    -- menú. El atajo fallaba (esas clases no están), el fallo armaba el enfriamiento, el enfriamiento
    -- activaba este bloqueo, y la pantalla se quedaba sin nadie que la leyera.
    -- EL ERROR DE CONCEPTO: estaba tratando "el atajo no encuentra el foco" como si SIEMPRE significara
    -- "el menú se está desmontando". Son dos cosas distintas:
    --   * el menú se DESMONTA (pulsaste A) => el botón que tenía el foco MUERE. Aquí sí hay que frenar.
    --   * el foco se fue a algo que el atajo no cubre (avisos, un diálogo...) => el botón sigue VIVO,
    --     el menú está sano y hay que ir a buscar el foco con el walk. Aquí frenar es dejar mudo.
    -- La señal para distinguirlos ya la tenía delante: si `_lastMenuFastWidget` sigue VÁLIDO, el menú no se
    -- está muriendo. `_menuLooksAlive` guarda justo eso, y el bloqueo solo actúa cuando el menú NO parece
    -- vivo — que es el caso peligroso de verdad y el único que quería frenar.
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

    -- MIGAJA FINA (07-26): el walk completo sobre la escena del menú (~1762 widgets) es el candidato más
    -- caro del residual del menú principal, y está declarado como riesgo ACEPTADO en la nota de arriba
    -- ("el crash del menú principal vuelve a ser residual intermitente"). Marcarlo aparte permite que el
    -- PRÓXIMO crash distinga el WALK del atajo de botones, sin tener que adivinar. Casi no cuesta: en el
    -- menú sano el atajo halla el botón enfocado y retorna ANTES de llegar aquí, así que esta escritura
    -- solo ocurre en el hueco del desmontaje, que es justo el instante que queremos fichar.

    -- === FRENO DEL WALK POR MUERTE DEL FOCO (07-28). CON DATO ===
    -- Crash al entrar al torneo: migaja `F:pf-fast` y, en la línea inmediatamente anterior del livelog, un
    -- atasco de **3.02s en `scan-findall`** — la enumeración de aquí abajo — con el conteo saltando de 1758
    -- a 695. En esa sesión `scan-findall` acumuló 89 atascos, el grupo más grande.
    -- POR QUÉ EL FRENO DE CHURN NO LLEGÓ A TIEMPO: desde que el foco dejó de enumerar por su cuenta, el
    -- churn lo detecta el bucle de POLL, que va a 100ms. El foco va a 16ms, así que tiene ~6 vueltas de
    -- ventaja antes de que el poll se entere y arme el freno. En una de esas vueltas enumeró y murió.
    -- LA SEÑAL QUE SÍ LLEGA A TIEMPO: que el widget que tenía el foco haya MUERTO. Eso lo detecta el propio
    -- foco, en el mismo tick, con un `IsValidRef` que ya hacía. Si el foco acaba de morir, la pantalla se
    -- está yendo: no hay NADA que leer y caminar 2000 widgets moribundos es puro riesgo.
    -- Medio segundo basta para que el poll se entere y arme el freno de churn de verdad. Y es fail-safe:
    -- pasado ese tiempo el walk vuelve a estar disponible, así que no puede enmudecer nada.
    if (os.clock() - _focusDiedAt) < 0.5 then return nil end

    -- Aquí SÍ hace falta la lista de verdad. Si este tick no la enumeró (throttle de arriba), se pide
    -- ahora: la enumeración cara solo se paga cuando se va a USAR, no en los ticks que resuelve un atajo.
    if not allWidgets then
        _focusStage = "scan-findall"
        local okW, wAll = pcall(FindAllOf, "UserWidget")
        if not okW or not wAll then return nil end
        allWidgets = wAll
        -- AQUÍ NO SE ESCRIBE `lastWidgetCount` (07-28). ERA EL SEGUNDO ESCRITOR Y CAUSABA VENTANAS FALSAS.
        -- La auditoría multiagente lo localizó como CAUSA RAÍZ COMÚN de los tres síntomas: `lastWidgetCount`
        -- tenía DOS dueños con valores distintos — este conteo FRESCO del walk, y el que publica el poll
        -- (`Trackers.widgetCount`), que desde hoy se CONGELA durante todo el churn porque el poll dejó de
        -- contar. El churn guard comparaba uno contra otro, así que la resta salía de cientos o miles sin
        -- que hubiera pasado nada, y armaba ventanas de 2.0s (3.0s en zona de peligro) una detrás de otra.
        -- MEDIDO en el livelog: "UI churn guard: 1777 -> 860 (3.0s)" y "860 -> 1777 (3.0s)" en 11 segundos,
        -- y un 78% de churn=true justo en los momentos en que habla el presentador del torneo. Eso es lo
        -- que dejó mudos sus subtítulos: `PollCutsceneText` corre detrás de `uiChurnUntil`.
        -- Con un solo dueño (el poll), prev y count vienen siempre de la misma fuente y un salto solo puede
        -- ser un salto de verdad. La lista sigue usándose aquí para el walk; simplemente ya no se publica.
    end

    -- A partir de aquí SÍ se mira de verdad la pantalla entera: si no se encuentra nada, es que
    -- realmente no hay nada enfocado y PollFocus puede limpiar el dedup con razón.
    _scanReachedWalk = true
    _focusStage = "scan-full"; _focusScanTotal = #allWidgets
    for i = 1, #allWidgets do
        _focusScanIdx = i
        local w = allWidgets[i]
        if IsValidRef(w) then
            -- Re-validate INSIDE the pcall, immediately before the native HasKeyboardFocus call.
            -- On the tournament team/roster select a widget can be freed in the gap between the
            -- IsValidRef above and the call below (the fundamental F:pollfocus race — invisible to
            -- the count guards because the total stays stable when a single widget dies). This
            -- second check narrows that window to the smallest it can be from Lua. It does NOT close
            -- it — pcall can't catch a native access violation or hang — but it makes the crash
            -- markedly rarer. Nothing is removed, so it can't silence any reading.
            local fok, focused = pcall(function()
                if not IsValidRef(w) then return false end
                return w.HasKeyboardFocus and w:HasKeyboardFocus()
            end)
            if fok and focused then
                -- EL WALK TAMBIÉN ALIMENTA LA SONDA DE VIDA DEL MENÚ (07-28). Iván: al volver al MENÚ DEL
                -- TORNEO el lector se quedaba MUDO. La auditoría lo explicó: sus botones son
                -- `WBP_OBJ_OLB_MenuBTN_C`, que NO está en `menuFastClasses` ni en ningún atajo, así que esa
                -- pantalla depende del walk al cien por cien. Y mi bloqueo del walk solo se abre si
                -- `_menuLooksAlive` es true, que hasta ahora solo podía ponerse cuando el ATAJO acertaba —
                -- cosa que allí no pasa NUNCA. Resultado: bloqueo permanente y pantalla muda.
                -- Guardando aquí el widget, la primera vuelta que el walk consiga correr deja la sonda
                -- cargada y el bloqueo se abre solo. NO se toca `_lastMenuFastHitClock`, que debe seguir
                -- sellándose únicamente con las clases del menú principal (si no, se falsearía la ventana
                -- de salida del menú). Y NO se crece `menuFastClasses` (LECCIÓN 15).
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
    --   transition  — dialog dismissed / map loading (transitionCooldownUntil)
    --   churn       — UI rebuild in progress (uiChurnUntil)
    --   cutscene    — story-cutscene focus-only pause (focusPauseUntil)
    --   eventSkip   — a cutscene SKIP prompt is on screen (cinematic churning)
    -- The eventSkip / cutscene pauses protect the fast path from reading a cached menu widget
    -- mid-teardown (crumb F:pollfocus). DIAG (temporary): log the reason once per change so we can
    -- see WHY the pause menu doesn't read in some story scenes.
    -- Is the PAUSE MENU open? Confirmed via diag that WBP_EventPause_C:IsVisible reliably flips
    -- (Y when open, N when closed). If open, the game is PAUSED (frozen) and stable, and the user
    -- needs the menu read — so IGNORE ALL the focus pauses, including churn/transition. Previously we
    -- kept churn/transition "for the pause-open rebuild", but that backfired: pausing DURING a
    -- special move (Genkidama) armed a 2-3s churn guard that persisted into the freeze and left the
    -- pause menu SILENT until it expired (Iván: "no reaccionaba el menú de pausa... luego funcionaba").
    -- The game is frozen while paused, so those guards are stale; the only churn is the pause menu's
    -- own CONSTRUCTION (adding widgets, not tearing a scene down), which the per-widget IsValidRef in
    -- ScanForFocus handles. Reading a frozen pause menu is safe.
    -- ¿MENÚ PRINCIPAL? Se computa PRIMERO. Si sí, SE SALTA toda la tanda de chequeos de pausa de
    -- BATALLA (pc1-pc5): son widgets de PELEA que en el menú no aplican, y sus IsVisible sobre la escena
    -- del demo (que churnea) son los que TRUENAN (F:pollfocus al volver al menú, 07-20). En el menú el
    -- foco hace SOLO el atajo de botones + return-nil. La banderita la leen los lectores de subtítulos.
    local onMainMenu = H.GetCachedFirstOf("WBP_MainMenu_ModeMenu_C") and true or false
    -- FLANCO DE ENTRADA AL MENÚ (07-27). Iván: al salir de la Enciclopedia, el menú tarda casi 5 segundos
    -- en decirle "Enciclopedia". MEDIDO en el livelog: salida de la galería a las 15:09:21, el menú acaba
    -- de montarse a las 15:09:24 (3s que son del JUEGO cargando, no del mod) y ahí se arma la ventana de
    -- churn de 2.0s. Encima, el enfriamiento del atajo venía cargado de la racha de fallos del
    -- desmontaje anterior y sumaba hasta 0.8s MÁS sobre un menú que ya estaba montado y sano.
    -- Ese último tramo sí es puro desperdicio: cuando el menú REAPARECE, la racha de fallos vieja ya no
    -- significa nada. Se limpia en el flanco. Ahorra hasta 0.8s de los ~5, sin tocar ningún freno de
    -- seguridad (los otros 2 segundos son el escudo anti-crash de la reconstrucción y NO se toca aquí).
    if onMainMenu and not _prevOnMainMenu then
        _menuFastMissUntil = 0
        _menuFastMissStreak = 0
        _menuWalkHoldStreak = 0
    end
    _prevOnMainMenu = onMainMenu
    Trackers.onMainMenu = onMainMenu
    if onMainMenu then _lastOnMainMenuClock = os.clock() end  -- marca de tiempo para la ventana de SALIDA de menú
    -- ¿ENCICLOPEDIA (pantalla "Gallery")? Medido 07-20: las 5 muertes del bucle de foco de esa sesión
    -- cayeron TODAS en la ventana de la Enciclopedia y TODAS en el atajo CACHEADO (pf-fastpath 3,
    -- pf-fp-haskbf 2) = la lentitud que reporta Iván al navegar con las flechas. Es EL MISMO mecanismo
    -- que causaba el lag de 2-3s por opción en el menú principal, resuelto saltando el atajo cacheado.
    -- Se aplica aquí el mismo patrón ya probado. SEÑAL VERIFICADA en el volcado (no supuesta):
    -- WBP_GRP_Gallery_PictureBook_C aparece en 12 entradas y NUNCA coexiste con los botones del menú
    -- principal ni con HitButton (pelea/char-select) — exclusividad limpia. UNA sola consulta por tick
    -- a propósito: inflar el número de consultas del hot path fue lo que disparó los cuelgues cuando
    -- crecí menuFastClasses. Saltar el atajo NO enmudece: cae al escaneo fresco de ScanForFocus.
    local onGallery = H.GetCachedFirstOf("WBP_GRP_Gallery_PictureBook_C") and true or false
    -- VENTANA DE SALIDA DE LA ENCICLOPEDIA (07-27). CRASH F:pollfocus AL SALIR de la Enciclopedia al
    -- menú, con `onMainMenu=false` (la migaja nueva por bucle lo confirmó: foco=F:pollfocus SIN el
    -- sufijo `:menu`, poll=P:done o sea el poll había terminado limpio, dump=D:off o sea el volcado
    -- estaba apagado). ASIMETRÍA QUE LO CAUSABA: `onGallery` salta el atajo cacheado MIENTRAS estás
    -- dentro, pero en cuanto sales, el widget de la galería desaparece, `onGallery` cae a false y el
    -- atajo se REACTIVA sobre `lastFocusedWidget`, que es un widget DE LA GALERÍA en pleno teardown =>
    -- HasKeyboardFocus sobre él truena. Es EXACTAMENTE el mismo mecanismo (y el mismo fix) que ya se
    -- aplicó el 07-21 a la salida del MENÚ con `justLeftMenu`; simplemente faltaba el simétrico aquí.
    -- Respaldo histórico: el 07-20 se midió que las 5 muertes del foco de aquella sesión cayeron TODAS
    -- en la ventana de la Enciclopedia y TODAS en el atajo cacheado (pf-fastpath 3, pf-fp-haskbf 2).
    -- El reloj se sella aquí y TAMBIÉN mientras el bucle está congelado (ver el gate del focus loop),
    -- porque si no la ventana envejecería durante el freno sin haber protegido nada (LECCIÓN 16).
    Trackers.onGallery = onGallery
    if onGallery then _lastOnGalleryClock = os.clock() end
    local justLeftGallery = (not onGallery) and (os.clock() - _lastOnGalleryClock) < 2.5
    -- VENTANA DE SALIDA DE MENÚ: se calcula AQUÍ (antes se calculaba 138 líneas más abajo y por eso NO
    -- protegía la tanda de pause-checks de justo debajo).
    local justLeftMenu = (os.clock() - _lastOnMainMenuClock) < 2.5
    local pauseMenuOpen, onSkillList, onResultScreen = false, false, false
    -- `and not justLeftMenu` (07-22): CRASH F:pollfocus al entrar a HISTORIA desde el menú (y antes a la
    -- Enciclopedia). CAUSA REAL (no "hay que esperar más"): mientras estás en el menú, toda esta tanda de
    -- PAUSE-CHECKS se salta por `not onMainMenu`; en cuanto onMainMenu cae (transición), se REACTIVA DE
    -- GOLPE y hace IsVisible sobre widgets de pausa/resultado que están naciendo/muriendo => truena. Y el
    -- diagnóstico del 07-19 (_focusStage) ya había medido que el foco NO muere en el recorrido de widgets
    -- sino EN ESTOS PAUSE-CHECKS (13/14 muertes). Saltarlos durante la ventana de salida ataca la causa
    -- SIN frenar la lectura: el foco sigue leyendo normal (fast-path/walk), solo se omiten estos IsVisible.
    -- COSTO REAL Y MÍNIMO: durante 2.5s tras dejar el menú no se detecta un menú de PAUSA — y saliendo del
    -- menú principal no hay ninguno (la pausa aparece dentro de una partida, no en esa transición).
    -- === ENFRIAMIENTO DE LA TANDA DE PAUSE-CHECKS (07-27 noche). CON DATO ===
    -- Crash al pasar a otra batalla en el torneo: migaja `F:pf-checks` (o sea AQUÍ) y las últimas ocho
    -- líneas del livelog son atascos de **1.18 a 1.20s en `pf-pc5-result-vis`, uno detrás de otro**. En el
    -- reparto de esa sesión: 27 atascos en `pf-pc5-result-vis` + 16 en `pf-pausecheck`.
    -- EL DERROCHE: esta tanda son CINCO comprobaciones en cadena, y solo se detiene cuando una acierta.
    -- Durante una batalla normal —sin pausa— ninguna acierta, así que se pagaban las cinco ENTERAS 62
    -- veces por segundo, y cada `IsVisible` sobre un contenedor de batalla puede tardar más de un segundo.
    -- NO se cambia CÓMO se comprueba (la LECCIÓN 1 es tajante: meter `SafeIsVisible` aquí disparó 224
    -- colgones en julio y se revirtió). Se cambia CADA CUÁNTO, que es la técnica que hoy ya funcionó dos
    -- veces (`scan-gallery` 819->7, `scan-option` 200->2).
    -- SOLO SE ENFRÍA SI NO ENCONTRÓ NADA. Si hay un menú de pausa abierto, la tanda sigue corriendo cada
    -- tick para que el estado no oscile y la pantalla se lea estable. El único coste es que abrir la pausa
    -- puede tardar hasta 0.3s en detectarse — y estando el juego congelado ahí, eso no pierde nada.
    -- Se limpia con cualquier churn (cambio de pantalla), como el resto de enfriamientos.
    if os.clock() < uiChurnUntil then _pauseChecksMissUntil = 0 end
    if not onMainMenu and not justLeftMenu and os.clock() >= _pauseChecksMissUntil then
    -- MIGAJA FINA (07-27): esta tanda se lleva 13 de cada 14 muertes históricas del foco, pero la migaja
    -- decía solo "F:pollfocus" y no distinguía tramos. Con esta marca, el próximo crash dirá si cayó AQUÍ
    -- o más adelante. Es UNA escritura más por tick y SOLO cuando la tanda se ejecuta de verdad (en el
    -- menú y en su ventana de salida se salta entera, así que ahí no cuesta nada).
    _focusStage = "pf-pc1-eventpause-find"
    local pvw = H.GetCachedFirstOf("WBP_EventPause_C")
    _focusStage = "pf-pc1-eventpause-vis"
    pauseMenuOpen = pvw and TryCall(pvw, "IsVisible") and true or false
    -- The in-BATTLE pause menu is a DIFFERENT widget: WBP_Pause_C (confirmed in the F5 dump — it
    -- holds ResumeButton "Continuar", RetryButton "Reintentar", OptionButton "Opciones", QuitButton,
    -- BattleDetailsButton...). WBP_EventPause_C is only the story/cutscene pause. So the battle pause
    -- menu wasn't being detected and the focus guards kept it silent (Iván: "no me lee bien el menú
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
    -- still "active" the danger-zone logic armed a long churn window that paused the focus scan — so
    -- the focused skill never got read (Iván: "me muevo con el joystick dentro de las opciones y ya
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
    -- guards kept running and the screen read late / not at all (Iván: "da tirón... entré a detalles
    -- de batalla, que antes sí leía y ahora no"; the diag logged "focus paused: cutscene pauseVis=N"
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
    -- guards paused the focus and this menu went unread (Iván 07-19: "el menú de reintentar no lee").
    -- Treat it like the pause menu — bypass the guards — and let ScanForFocus's dedicated result
    -- fast-path scan ONLY its buttons (never the churning scene). WBP_GRP_BS_Result_02_DP_C is its
    -- root (F5: BTN_1 "Reintentar", BTN_2 "Salir", both WBP_OBJ_BS_BTN_Result_1_C). Same TryCall
    -- pattern as the checks above (NOT SafeIsVisible — that IsValid hangs on teardown widgets).
    if not pauseMenuOpen then
        _focusStage = "pf-pc5-result-find"
        local rsv = H.GetCachedFirstOf("WBP_GRP_BS_Result_02_DP_C")
        _focusStage = "pf-pc5-result-vis"
        if rsv and TryCall(rsv, "IsVisible") then
            pauseMenuOpen = true
            onResultScreen = true
        end
    end
    -- Ninguna de las cinco pantallas de pausa está presente => no insistir 62 veces por segundo. Si sí la
    -- hay, NO se enfría: la tanda sigue cada tick para que el estado se mantenga estable (ver la nota).
    if not pauseMenuOpen then _pauseChecksMissUntil = os.clock() + 0.3 end
    end  -- cierra el "if not onMainMenu": en el menú se salta toda la tanda de chequeos de pausa

    -- Arma la ventana de pausa que episode_battle.PollCutsceneText usa para RETENER el
    -- dedup de subtítulos (evita re-leer la línea al despausar). Ventana temporizada =
    -- FAIL-SAFE (LECCIÓN 11): si este bucle muere, expira y todo vuelve a lo normal. La
    -- gracia de 1.0s cubre además el flanco de SALIDA (la línea que reaparece al despausar).
    -- No calla barks: se probó que 0 barks caen en pausa (ver Trackers.pauseSeenUntil).
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
        -- pc6: en el MENÚ PRINCIPAL NO checar el prompt de skip (su IsVisible sobre la escena del demo
        -- también truena); el demo se maneja con la banderita en los lectores de subtítulos.
        _focusStage = "pf-pc6-eventskip-find"
        local sk = H.GetCachedFirstOf("WBP_GRP_AI_EventSkip_C")
        _focusStage = "pf-pc6-eventskip-vis"
        if sk and TryCall(sk, "IsVisible") then pauseReason = "eventSkip" end
    end
    if pauseReason then
        local tag = pauseReason .. (pauseMenuOpen and " pauseVis=Y" or " pauseVis=N")
        if tag ~= lastFocusPauseReason then
            lastFocusPauseReason = tag
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
        -- RESUME SETTLE: a pause ending can be part of a scene TEARDOWN — the widget tree may still
        -- be freeing at that instant, and resuming the focus scan right then walked the freeing
        -- widgets and crashed natively (crumb F:pollfocus). So skip the focus SCAN for ~0.5s (30 x
        -- 16ms) via slowPathCooldown to let the teardown finish. It MUST be slowPathCooldown, not the
        -- shared uiChurnUntil (which would make the next tick's reason "churn" and re-arm here forever,
        -- freezing the reader — that regression actually happened).
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
    -- churn with the scene behind them, so the cached HasKeyboardFocus check HANGS (~1.5s each — the 2-3s
    -- lag Iván felt, 07-19). Going straight to ScanForFocus's cheap result fast-path (fresh scan of the 2
    -- stable buttons) avoids it.
    -- SALIDA DE MENÚ (07-21): al entrar del menú principal a la Enciclopedia (u otro sub-mundo), onMainMenu
    -- cae a false y este atajo cacheado se reactiva sobre `lastFocusedWidget`, que ES el botón del menú
    -- (WBP_OBJ_MainMenu_BTN_Sub1) EN TEARDOWN => HasKeyboardFocus sobre él TRUENA (F:pollfocus, verificado
    -- en dump_crash_entrada: último foco = MainMenu_BTN_Sub1). La ventana de salida de menú (justLeftMenu)
    -- ya frena el CHURN GUARD, pero este atajo corre ANTES. Durante 2.5s tras dejar el menú NO usar el
    -- atajo cacheado (su ref es del menú muerto): cae a ScanForFocus, cuyo churn guard frena con ventana larga.
    -- (justLeftMenu ya se calculó arriba, antes de los pause-checks — se reutiliza aquí.)
    -- MIGAJA FINA (07-27): pasada esta marca, los pause-checks YA quedaron atrás sin tronar. Si un crash
    -- deja `F:pf-fast`, el culpable es el atajo cacheado o el escaneo de ScanForFocus, no la tanda.
    _focusStage = "pf-fastpath"
    if lastFocusedWidget and not onResultScreen and not onSkillList and not onMainMenu and not onGallery
       and not justLeftMenu and not justLeftGallery then
        _focusStage = "pf-fp-isvalid"  -- DIAG fino: ¿se cuelga en el IsValidRef del widget cacheado?
        if not IsValidRef(lastFocusedWidget) then
            -- Widget destroyed — clear refs, fall through to slow path
            -- No cooldown needed: IsValid() caught it safely
            -- SELLO DE MUERTE DEL FOCO (07-28): que el widget que tenía el foco haya MUERTO es la señal más
            -- barata y más temprana de que la pantalla se está yendo. Se apunta la hora para que el walk no
            -- se lance justo ahí (ver el freno antes del walk). Cero llamadas nuevas: este `IsValidRef` ya
            -- se hacía.
            _focusDiedAt = os.clock()
            lastFocusedWidget = nil
            lastFocusedName = nil
            lastSpokenLabel = nil
            lastMatchedLabelWidget = nil
        else
            _focusStage = "pf-fp-haskbf"  -- DIAG fino: ¿o en el HasKeyboardFocus?
            local ok, stillFocused = pcall(function()
                return lastFocusedWidget:HasKeyboardFocus()
            end)

            if not ok then
                -- pcall caught error after IsValid passed — enter brief cooldown
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
                -- Focus unchanged — check caption value changes (D-pad left/right)
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

            -- Focus moved — clear cached widget, fall through to slow path
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

    -- El escaneo se cortó por un FRENO (settle, enfriamiento, espera, bloqueo del walk...): eso significa
    -- "no he mirado", NO "no hay foco". Borrar el dedup aquí es lo que hacía repetir la opción al quedarse
    -- parado (07-27). Se sale sin tocar nada; el estado sigue siendo válido.
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
    -- preserveDedup (07-20): el watchdog reinicia el foco tras un cuelgue; si borra el dedup de "qué
    -- acabo de decir" (lastSpokenLabel/lastFocusedName), el siguiente escaneo RE-LEE el ítem donde el
    -- usuario está parado (la repetición que oía Iván: "repite el nombre de donde estoy parado"). Con
    -- preserveDedup=true conservamos ese dedup para NO re-anunciar el mismo ítem. lastFocusedWidget SÍ
    -- se limpia siempre (la ref puede estar muerta); si el usuario se movió durante el cuelgue, el
    -- nuevo ítem tiene otra etiqueta y se anuncia igual. Solo lo usa el reinicio del watchdog.
    -- AMPLIADO 07-20: preservar lastSpokenLabel/lastFocusedName no bastaba. El watchdog seguía
    -- borrando el dedup de los OTROS lectores (barra de guía, char-select de Episodio, Tienda,
    -- títulos de lista), así que cada reinicio re-anunciaba la pantalla entera CON INTERRUPCIÓN y
    -- se comía la descripción. Medido: 8 reinicios = 8 veces "Episode Battle" + la barra de
    -- controles + "Goku". Regla: en un reinicio se limpian las REFERENCIAS (pueden estar muertas)
    -- pero NUNCA el dedup de "qué acabo de decir" — el usuario no se movió, no hay nada nuevo que
    -- anunciar. Si sí se movió durante el cuelgue, el texto cambia y se anuncia solo.
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
    -- Referencias y cachés: SIEMPRE se limpian (una ref muerta cuelga la siguiente lectura nativa).
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

-- Quick world liveness check — if this fails, we're in a transition.
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

-- === MAP TRANSITION DETECTION (polling — no LoadMap hooks) ===
-- We used to pause the loops and reset state via RegisterLoadMapPre/PostHook,
-- but those native engine hooks crash the current game build on the first map
-- load. Instead we poll the current World's identity every tick. GameInstance
-- is a process-lifetime singleton (never changes), but the World is torn down
-- and rebuilt on a real map load — exactly the transition signal we want.
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
    -- If the cached World is still alive, its identity (GetFullName) has NOT changed — a World's
    -- full name is stable for its whole lifetime — so return the STORED name WITHOUT calling
    -- GetFullName again. This is the crash fix for crumb P:worldtrans: the old code called
    -- GetFullName on the cached World every throttled tick, and during a real map load that World is
    -- mid-teardown (IsValidRef can still say "valid" for a stale ref), so the native read crashed.
    -- Now GetFullName runs only ONCE per World — when a NEW one is first found — after the old one
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
    -- LOAD that object is being torn down/rebuilt — the native read then crashes (crumb P:worldtrans,
    -- seen loading into the Majin-Vegeta battle). It ran every tick of BOTH loops (~70×/s), so every
    -- load had ~70 chances to hit the teardown. Map changes take seconds, so ~7×/s (150ms) detects
    -- them just as well while cutting the crash exposure ~10×. Shared across both loops.
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




local function StartFocusLoop()
    LoopAsync(16, function()
        -- MIGAJA DE REPOSO (07-22). Antes aquí decía "F:worldtrans", y como el bucle escribe migaja cada
        -- 16ms y en cuanto se frena hace `return false` SIN avanzar, la migaja quedaba clavada en
        -- "F:worldtrans" AUNQUE NUNCA hubiera leído el World — eso hizo AMBIGUOS los 44 crashes con ese
        -- nombre (podían ser el foco congelado y el crash venir de otro lado). Ahora el reposo es "F:idle"
        -- y "F:worldtrans" se escribe SOLO justo antes de llamar de verdad. Si vuelve a salir F:idle,
        -- significa "el foco estaba congelado, mira al bucle de poll"; F:worldtrans ya señala de verdad.
        -- FRENO ANTI-CRASH (07-20): NO leer el World durante el churn pesado de una carga de mapa. Es
        -- cuando GetFullName sobre el World a medio construir TRUENA nativo (crumb F:/P:worldtrans, 2 de
        -- 3 crashes esta sesión). Durante el churn la detección de transición espera; se detecta al
        -- asentarse (~1-2s), sin costo de accesibilidad real (la identidad del World es interna). Los
        -- pollers ya están frenados por el mismo churn, así que no leen de más mientras tanto.
        -- FRENO ADICIONAL (07-21): NO leer el World durante una TRANSICIÓN (transitionCooldown, armado por
        -- los diálogos de guardado/carga del ARRANQUE). CRASH F:worldtrans al arrancar (crumb, en "Revisando
        -- contenido descargable" / "Dialog dismissed"): durante la carga de datos el World está a medio crear
        -- y GetFullName sobre él TRUENA (carrera nativa, IsValidRef no la elimina — LECCIÓN 1). IsWorldAlive
        -- NO sirve aquí (solo mira GameInstance, singleton de proceso => siempre true tras el arranque). La
        -- transición sí se detecta al asentarse (CheckWorldTransition ya acepta ese retraso). Fail-safe: si
        -- IsInTransition nunca es true, el gate no cambia nada.
        -- `not Trackers.onMainMenu` (07-22): CRASH F:worldtrans al ENTRAR a la Enciclopedia desde el menú.
        -- CheckWorldTransition corre AL INICIO del loop, ANTES de que ScanForFocus arme el churn del tick
        -- actual; en el 1er tick de la transición el churn viejo ya expiró y lee el World reconstruyéndose.
        -- El menú es SIEMPRE el mismo World (Korat_P) => nunca hace falta leer el World ahí, y como
        -- Trackers.onMainMenu es del tick ANTERIOR, cubre también el tick de la transición (cuando aún
        -- refleja el menú). Las transiciones a MUNDO nuevo (pelea/historia) tienen onMainMenu=false => se
        -- detectan normal, al asentarse.
        -- VENTANA DE SALIDA DE MENÚ (07-22, CRASH F:worldtrans AL ENTRAR A LA ENCICLOPEDIA, 2ª vez).
        -- INCOHERENCIA que lo causaba: el gate de MÁS ABAJO decidía "estos 2.5s son demasiado peligrosos
        -- para leer widgets" y aquí arriba, en el mismo tick, SÍ se leía el World — que es MÁS peligroso.
        -- `not onMainMenu` solo aplazaba UN tick (en cuanto PollFocus recalcula onMainMenu=false, esta
        -- línea se suelta). Ahora comparte la MISMA ventana que el resto del bucle.
        local justLeftMenuNow = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5
        if os.clock() >= uiChurnUntil and not Trackers.IsInTransition() and not Trackers.onMainMenu and not justLeftMenuNow then
            pcall(CheckWorldTransition)
        end
        -- ANTI-CRASH (07-20): durante el CHURN pesado (reconstrucción/transición) el bucle de foco NO
        -- lee NADA — ni el World ni los widgets. Es JUSTO cuando todo se destruye/reconstruye y las
        -- lecturas nativas truenan (F:pollfocus 40 + F:worldtrans 33 = ~65% de los crashes). `churn`
        -- va PRIMERO (corto-circuito) para ni siquiera llamar IsWorldAlive en ese momento. Se retoma al
        -- asentarse (churn 0.3-3s). La navegación normal del menú NO arma churn (saltos <200), así que
        -- sigue ágil; solo se frena en las reconstrucciones, que es donde truena. Costo: el menú de
        -- pausa puede leer un instante más tarde si lo abres en pleno churn (raro; la pausa normal está
        -- congelada y no churnea sostenido).
        -- SALIDA DE MENÚ (07-21): durante 2.5s tras DEJAR el menú principal, NO leer el foco — cubre el
        -- teardown del menú (el conteo aún no armó churn, pero los botones ya se destruyen => F:pollfocus).
        -- Condición `not Trackers.onMainMenu`: DENTRO del menú NO frena (si no, mudez), solo al salir.
        -- Cierra el hueco de 1 tick entre que onMainMenu cae y el churn se arma. La Enciclopedia se lee por
        -- su poller (poll loop), no por foco, así que no pierde nada; Ajustes lee ~2.5s más tarde (aceptado).
        -- `justLeftMenuNow` YA se calculó arriba (mismo tick, mismo valor) — no recalcular.
        if not readerEnabled or os.clock() < uiChurnUntil or justLeftMenuNow or Trackers.IsInTransition() or not IsWorldAlive() then
            -- LA VENTANA DE SALIDA NO DEBE ENVEJECER MIENTRAS EL BUCLE ESTÁ CONGELADO (07-22, causa raíz
            -- del crash de la Enciclopedia). `_lastOnMainMenuClock` solo se sella dentro de PollFocus
            -- (~L1219), y PollFocus NO CORRE mientras el churn frena el bucle. Resultado medido: la
            -- cortinilla del menú armó churn 22:18:09 y 22:18:11 (2s cada uno); durante ~4s el reloj se
            -- quedó parado en el último tick con menú, así que al soltarse el freno la ventana de 2.5s YA
            -- HABÍA CADUCADO y no protegió nada — se leyó el World de la Enciclopedia a medio construir.
            -- Refrescarlo aquí hace que los 2.5s empiecen a contar cuando el bucle REANUDA de verdad.
            -- NO se retroalimenta (LECCIÓN 6): si el freno es el propio justLeftMenuNow, onMainMenu es
            -- false por definición y esta línea no toca el reloj, así que la ventana sí expira.
            if Trackers.onMainMenu then _lastOnMainMenuClock = os.clock() end
            -- Mismo motivo para la ENCICLOPEDIA (07-27): si el bucle está frenado mientras sigues DENTRO
            -- de la galería, su ventana de salida no debe envejecer (LECCIÓN 16). Tampoco se retroalimenta:
            -- si el freno fuera la propia ventana de salida, onGallery ya es false y esta línea no toca nada.
            if Trackers.onGallery then _lastOnGalleryClock = os.clock() end
            focusLoopHeartbeat = os.clock()
            return false
        end
        -- MIGAJA CON CONTEXTO (07-26). El crash de hoy al entrar a la Enciclopedia quedó en
        -- `F:pollfocus`, que solo dice "murió dentro de PollFocus" — insuficiente. Añadir si estábamos
        -- en el MENÚ es GRATIS (`Trackers.onMainMenu` es una banderita ya calculada, cero llamadas
        -- nativas, misma única escritura por tick) y contesta la pregunta que importa: ¿fue el residual
        -- conocido del menú principal, o algo nuevo? Lee `F:pollfocus:menu` como "murió con el menú
        -- principal (o un sub-menú suyo) activo".
        -- === DIAG DE ATASCOS CORTOS (07-27 noche, quitar al cerrar la lentitud del menú) ===
        -- El DIAG de retraso dio 12 medidas de 0.46 a 0.82s **con `fallos=0` y SIN una sola reconstrucción
        -- durante la navegación**: o sea, el mod no se equivocaba ni estaba frenado por ningún gate, y aun
        -- así perdía medio segundo largo. Solo queda una explicación: el bucle TARDA en dar la vuelta,
        -- porque alguna llamada nativa se atasca. Y esos atascos son INVISIBLES hasta ahora, porque el
        -- watchdog solo ficha los de más de 1.5s — uno de 0.6s no deja rastro en ninguna parte.
        -- Esto mide el HUECO entre vueltas del bucle. `_focusStage` conserva la etapa donde acabó la vuelta
        -- anterior, así que un hueco grande viene etiquetado con el punto exacto que se atascó. Coste: una
        -- resta por tick y un print que en navegación sana no salta.
        local nowTick = os.clock()
        local gapTick = nowTick - _lastFocusTickClock
        _lastFocusTickClock = nowTick
        if _lastFocusTickClock > 0 and gapTick >= 0.15 and gapTick < 10 then
        end
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
        -- Publica el freno de churn para que el VOLCADO del F5 (debug_tools, bucle aparte) también pueda
        -- respetarlo (07-27: un crash con la migaja `D:scan` demostró que ese bucle mata si escanea en
        -- plena reconstrucción). Una asignación por tick, sin llamadas nativas.
        Trackers.uiChurnUntil = uiChurnUntil
        -- Mismo freno anti-crash que en el bucle de foco: no leer el World durante el churn de carga NI
        -- durante una transición (transitionCooldown de los diálogos de arranque). Ver el foco loop (07-21).
        -- Y la MISMA ventana de salida de menú (07-22): el throttle de CheckWorldTransition es COMPARTIDO
        -- entre ambos bucles, así que si aquí no se gatea, este bucle se come el turno y lee el World
        -- justo en la ventana que el otro está evitando. Los dos gates tienen que ser IDÉNTICOS.
        local jlmPoll = (not Trackers.onMainMenu) and (os.clock() - _lastOnMainMenuClock) < 2.5
        if os.clock() >= uiChurnUntil and not Trackers.IsInTransition() and not Trackers.onMainMenu and not jlmPoll then
            pcall(CheckWorldTransition)
        end
        -- Self-check the widget count on THIS 100ms tick too. The churn guard normally lives in
        -- the 16ms focus loop, but during a rapid pause/battle churn (count oscillating
        -- 1283<->2170) the focus loop might not have re-armed uiChurnUntil in the ~16ms before
        -- this tick, letting a heavy poller (P:dialogs, P:hud) run mid-churn and crash. Sampling
        -- here closes that gap. Only #array is read (no per-widget access), so it's safe.
        do
            -- Migaja propia (07-22): este `FindAllOf` es la ÚNICA llamada nativa del mod que corre SIN
            -- freno de churn (a propósito: es quien DETECTA el churn). Al quedar bajo la migaja genérica
            -- del tick era una zona ciega en cada diagnóstico. Ahora se distingue de "P:tick" (I/O del
            -- espejo de log) y de "P:worldtrans" (lectura real del World).
            --
            -- CRASH `P:wcount` (07-27, al entrar a la Enciclopedia). Las tres migajas separadas lo
            -- señalaron limpio: foco=`F:idle` (frenado por el churn, o sea los frenos del foco SÍ
            -- actuaron), dump=`D:idle`, poll=`P:wcount`. El livelog: `UI churn guard: 1756 -> 700` a las
            -- 13:26:54 y el crash a las 13:26:55, en pleno rebuild.
            -- LA PREMISA DE ARRIBA ERA OPTIMISTA. El comentario original decía "Only #array is read (no
            -- per-widget access), so it's safe": leer `#w` sí es barato, pero `FindAllOf("UserWidget")`
            -- NO es leer una longitud — recorre la GUObjectArray y CONSTRUYE una lista de ~1762 objetos,
            -- tocando cada uno. En pleno rebuild masivo eso puede pillar un objeto a medio liberar y
            -- tronar. No es "seguro", es "menos peligroso que acceder a los widgets".
            -- FRENO (07-27): mientras hay churn VIGENTE, este conteo pasa de 10 veces por segundo a 2.5
            -- — cuatro veces menos exposición JUSTO en el momento peligroso. Fuera del churn (pantalla
            -- asentada, sin riesgo) sigue igual de fino que siempre.
            -- POR QUÉ NO SE QUITA DEL TODO DURANTE EL CHURN, que sería lo más seguro: este conteo es el
            -- que EXTIENDE la ventana mientras el rebuild continúa, y es el único que corre cuando el
            -- bucle de foco está frenado. Si dejara de contar, `pollLastWidgetCount` quedaría viejo y al
            -- expirar la ventana el primer conteo vería un salto enorme y armaría OTRA ventana de 2s
            -- encadenada, retrasando la lectura tras CADA transición. Throttlear conserva la función y
            -- baja el riesgo; quitarlo cambiaría el comportamiento del churn guard, que es la pieza
            -- central anti-crash y no se toca a la ligera.
            -- HONESTIDAD: esto REDUCE la probabilidad, no la elimina. La enumeración durante un rebuild
            -- es una carrera nativa y `pcall` no atrapa un crash nativo (LECCIÓN 1).
            -- (sin `goto`: no todas las versiones de Lua lo aceptan y un error de sintaxis deja el mod
            -- sin cargar y a Iván sin voz)
            -- SEGUNDO CRASH EN ESTE PUNTO (07-27 15:04, entrando a la Enciclopedia). Migajas: poll=`P:wcount`,
            -- foco=`F:idle` (frenado por el churn, o sea el bucle de foco no estaba implicado), y esta vez
            -- NI SIQUIERA HUBO VENTANA DE CRASH ni archivo .dmp: el proceso murió de golpe. Livelog:
            -- `UI churn guard: 1756 -> 697` y el log se corta a mitad del rebuild (700 -> 1148).
            -- El throttle a 0.4s de esta mañana bajó la exposición 4x pero NO la quitó, y volvió a caer aquí.
            -- AHORA SE ELIMINA: durante el churn NO se cuenta, punto. Es la misma política que ya sigue el
            -- bucle de FOCO (que durante el churn no llega ni a enumerar), así que el poll deja de ser la
            -- excepción. Y el problema que me hizo dudar antes queda resuelto con el resync: la primera
            -- cuenta DESPUÉS del churn solo SINCRONIZA el valor, sin evaluar el salto — si lo evaluara, el
            -- salto acumulado del rebuild armaría otra ventana encadenada y retrasaría la lectura tras cada
            -- transición, que es justo lo que quería evitar.
            -- Lo que se pierde: la auto-extensión de la ventana mientras el rebuild continúa. Lo cubre el
            -- bucle de foco, que al soltarse ve el salto acumulado y arma él la ventana siguiente.
            local nowW = os.clock()
            local okW, w = nil, nil
            if nowW < uiChurnUntil then
                _pollWCountResync = true  -- al salir del churn, la primera cuenta solo sincroniza
            else
                okW, w = pcall(FindAllOf, "UserWidget")
            end
            if okW and w and _pollWCountResync then
                _pollWCountResync = false
                pollLastWidgetCount = #w
                -- PUBLICAR TAMBIÉN EN EL RESYNC (07-28). Antes esta rama ponía `okW = nil` y salía sin
                -- llegar a la publicación de abajo, así que `Trackers.widgetCount` se quedaba con el valor
                -- ANTERIOR al churn un tick más — y el bucle de foco, que ya solo lee de ahí, calculaba su
                -- salto contra un número caduco. Publicar aquí cierra el último hueco por el que el conteo
                -- podía quedarse congelado.
                Trackers.widgetCount = #w
                okW = nil  -- salta la evaluación de este tick: solo sincronizamos
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
                end
                pollLastWidgetCount = c
                -- Publicado para el bucle de FOCO, que ya NO enumera por su cuenta (07-27): era el mismo
                -- recorrido hecho dos veces cada 100ms y se llevaba 288 de 515 atascos.
                Trackers.widgetCount = c
            end
        end
        -- === DIAG TEMPORAL: cacería del crash de transición (quitar al cerrar el caso) ===
        -- Latido de ESTADO durante y 3s DESPUÉS de cada churn/transición/salto grande — la ventana
        -- volátil donde el motor truena nativo al cargar una batalla. La ÚLTIMA línea antes de que el
        -- log calle fija el estado justo antes del crash; el crumb dice en qué poller cayó. Solo LEE
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
            end
        end
        -- Cutscene subtitles + skip prompt run BEFORE the transition-pause guard so they
        -- read during story transitions — but they must STILL honour uiChurnUntil: during
        -- a big UI rebuild (post-battle result/story-return churn) they were reading a
        -- cutscene widget mid-teardown and crashing the game (crumb P:cutscenetext). No
        -- valid subtitle exists mid-rebuild anyway; normal cutscenes don't arm uiChurnUntil.
        if readerEnabled and os.clock() >= uiChurnUntil then
            local okCS, errCS = pcall(EpisodeBattle.PollCutsceneSkip)
            if not okCS then print("[AE] PollCutsceneSkip error: " .. tostring(errCS)) end
            local okCT, errCT = pcall(EpisodeBattle.PollCutsceneText)
            if not okCT then print("[AE] PollCutsceneText error: " .. tostring(errCT)) end
        end
        -- DESACTIVADO 07-22 (experimento limpio, ver OnWidgetFocused): aquí corría PollOptionValue ANTES
        -- del gate de churn — un cambio ESTRUCTURAL (corría en TODA transición, sin el freno) que NO
        -- descarté bien al culpar a Option_List_004. Se retira junto con el resto del lector de valores
        -- para deslindar los crashes al entrar a sub-menús de Ajustes. Reactivar aquí si se confirma
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
        local ok, err = pcall(Trackers.PollDialogs)
        if not ok then print("[AE] PollDialogs error: " .. tostring(err)) end
        local okRw, errRw = pcall(Trackers.PollRewards)
        if not okRw then print("[AE] PollRewards error: " .. tostring(errRw)) end
        local okMn, errMn = pcall(Trackers.PollMessageNotification)
        if not okMn then print("[AE] PollMessageNotification error: " .. tostring(errMn)) end
        local okBr, errBr = pcall(Trackers.PollTournamentBracket)
        if not okBr then print("[AE] PollTournamentBracket error: " .. tostring(errBr)) end
        local okPz, errPz = pcall(Trackers.PollTournamentPrize)
        if not okPz then print("[AE] PollTournamentPrize error: " .. tostring(errPz)) end
        local okLv, errLv = pcall(Trackers.PollLevelUp)
        if not okLv then print("[AE] PollLevelUp error: " .. tostring(errLv)) end
        local okUn, errUn = pcall(Trackers.PollUnlocks)
        if not okUn then print("[AE] PollUnlocks error: " .. tostring(errUn)) end
        local okDb, errDb = pcall(Trackers.PollDecisionBranch)
        if not okDb then print("[AE] PollDecisionBranch error: " .. tostring(errDb)) end
        local okBd, errBd = pcall(Trackers.PollBattleDetails)
        if not okBd then print("[AE] PollBattleDetails error: " .. tostring(errBd)) end
        -- FRENO ANTI-CRASH (07-20): NO correr PollClash durante el CHURN pesado. Su escaneo pesado
        -- (FindAllOf RichTextBlock) TRUENA cuando el forcejeo se destruye al SALIR de la pelea (crumb
        -- P:clash). El churn arma en rebuilds grandes (>=200 = la transición de salida); un choque real
        -- es un overlay chico (no arma churn), así que se sigue leyendo. Se retoma al asentarse.
        if os.clock() >= uiChurnUntil then
            local okCl, errCl = pcall(Trackers.PollClash)
            if not okCl then print("[AE] PollClash error: " .. tostring(errCl)) end
        end
        local okCh, errCh = pcall(Trackers.PollChartDetails)
        if not okCh then print("[AE] PollChartDetails error: " .. tostring(errCh)) end
        local okSy, errSy = pcall(Trackers.PollSystemMessage)
        if not okSy then print("[AE] PollSystemMessage error: " .. tostring(errSy)) end
        local ok2, err2 = pcall(Trackers.PollHelpWindows)
        if not ok2 then print("[AE] PollHelpWindows error: " .. tostring(err2)) end
        local ok3, err3 = pcall(Trackers.PollScreenChanges)
        if not ok3 then print("[AE] PollScreenChanges error: " .. tostring(err3)) end
        -- PollIntro removed (investigating retry crash)
        local ok6, err6 = pcall(Trackers.PollRoom)
        if not ok6 then print("[AE] PollRoom error: " .. tostring(err6)) end
        local okT, errT = pcall(Trackers.PollTutorial)
        if not okT then print("[AE] PollTutorial error: " .. tostring(errT)) end
        local ok7, err7 = pcall(EpisodeBattle.PollStoryMap)
        if not ok7 then print("[AE] PollStoryMap error: " .. tostring(err7)) end
        local okEA, errEA = pcall(EpisodeBattle.PollEpisodeMapArea)
        if not okEA then print("[AE] PollEpisodeMapArea error: " .. tostring(errEA)) end
        local okEP, errEP = pcall(EpisodeBattle.PollEpisodeMapPlace)
        if not okEP then print("[AE] PollEpisodeMapPlace error: " .. tostring(errEP)) end
        local okCsel, errCsel = pcall(EpisodeBattle.PollCharaSelect)
        if not okCsel then print("[AE] PollCharaSelect error: " .. tostring(errCsel)) end
        local ok5, err5 = pcall(Battle.PollHUD, Speak, SpeakQueued)
        if not ok5 then print("[AE] PollHUD error: " .. tostring(err5)) end
        local ok5r, err5r = pcall(Battle.PollResult, Speak, SpeakQueued)
        if not ok5r then print("[AE] PollResult error: " .. tostring(err5r)) end
        local ok10, err10 = pcall(Shop.PollCategory)
        if not ok10 then print("[AE] PollShopCategory error: " .. tostring(err10)) end
        local ok11, err11 = pcall(SkillList.PollCategory, Speak)
        if not ok11 then print("[AE] PollSkillListTab error: " .. tostring(err11)) end
        local okGal, errGal = pcall(Gallery.PollCharacter)
        if not okGal then print("[AE] PollGalleryCharacter error: " .. tostring(errGal)) end
        -- VALOR DE OPCIÓN: aquí, DETRÁS del gate de churn (pantalla asentada). NO moverlo antes del gate:
        -- eso fue lo que crasheó al entrar a sub-menús de Ajustes (07-22).
        local okOpt, errOpt = pcall(PollOptionValue)
        if not okOpt then print("[AE] PollOptionValue error: " .. tostring(errOpt)) end
        pollLoopHeartbeat = os.clock()
        return false
    end)
end

local function StartReader()
    StartFocusLoop()
    StartPollLoop()

    -- Watchdog: detects dead loops and restarts them.
    -- No UObject access — survives native crashes.
    LoopAsync(2000, function()
        if not readerEnabled then return false end
        local now = os.clock()
        local focusDead = (now - focusLoopHeartbeat) > 1.5
        local pollDead = (now - pollLoopHeartbeat) > 1.5

        if focusDead or pollDead then
            print("[AE] Watchdog: loops died (focus=" .. tostring(focusDead)
                .. " poll=" .. tostring(pollDead) .. "), restarting")
            ResetStaleState(true)  -- preserva el dedup: un reinicio NO debe re-leer el ítem actual
            if focusDead then StartFocusLoop() end
            if pollDead then StartPollLoop() end
        end
        return false
    end)

    print("[AE] Reader loops started (with watchdog)")
end

-- === DEBUG TOOLS (remove this block to disable) ===
-- Herramientas de depuración (F3/F4/F5). SE CARGAN SIEMPRE, también en la versión pública: son
-- funciones del proyecto que el usuario invoca a mano, no diagnósticos automáticos.
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
-- announcement lands during noisy post-battle cutscene dialogue — press F6 anytime
-- (even after the cutscene) to hear the last rewards again, complete.
pcall(function()
    RegisterKeyBind(Key.F6, function()
        local r = Trackers.lastRewards
        if not r or #r == 0 then
            Speak("Sin recompensas recientes", true)
            return
        end
        Speak("Últimas recompensas", true)
        for _, item in ipairs(r) do
            SpeakQueued(item)
        end
    end)
    print("[AE] F6 = repeat last rewards")
end)

-- F7: repeat the last story-map details panel (Recap / Details) on demand. The game
-- keeps that panel "alive" after you hide it, so the mod can't tell you reopened it to
-- re-read automatically — this hotkey gives that back under your control.
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


if Speech.IsLoaded() then
    StartReader()
    print("[AE] Live menu reader active.")
else
    print("[AE] Speech not available.")
end
