--[[
    gallery.lua — Enciclopedia (pantalla "Gallery") accessibility
    Al navegar personajes con RB/LB dentro de la enciclopedia, el FOCO de teclado NO se mueve
    (igual que las pestañas de la tienda), así que el bucle de foco no tiene nada que detectar
    y el cambio de personaje quedaba MUDO. Este poller vigila el nombre del personaje mostrado
    y lo anuncia cuando cambia, y detrás encola sus categorías y habilidades.

    WIDGET DEL NOMBRE (verificado 07-21 con una captura de RB pasando personajes):
      WBP_OBJ_Gallery_CharacterSelect_C  (UNA sola instancia — el detalle del personaje SELECCIONADO,
      no las 3 fichas del carrusel de fondo). Sus TextBlocks:
        - Caption_02 = nombre completo del personaje (ej. "Goku (Z - Temprano)", "Shallot");
                       PERO si el personaje tiene una TRANSFORMACIÓN activa, Caption_02 = la forma
                       (ej. "Supersaiyajin") y Caption_01 = el nombre base (ej. "Goku (Z - Medio)").
        - Caption_01 = nombre base SOLO cuando hay transformación (ausente/plantilla si no).
        - Caption_00 = plantilla japonesa "キャラクター名" (ignorar).
    FICHA DE DETALLE: todo bajo `CharacterList_01_C` (clase _01, única; las _00/_03 son las fichas del
    carrusel). Movimientos en `CharaSkill_1..4`, categorías en `CharacterInfo_Panel00_00..06`. El
    TextBlock final SIEMPRE se llama `caption` (re-verificado en el volcado del 07-26), por eso el
    match es por RUTA, no por nombre de widget. `CharaSkill_0` es plantilla.
    NOTA 07-26: el volcado tiene Panel00_05 y _06, así que se leen 00..06 (antes solo 00..04 y a los
    personajes con muchas categorías se les perdían las últimas). Con la pasada única sale gratis.
    OJO — NO confundir con `Text_CharaName` de `WBP_MainMenu_Base_TextSub_C`: ese es el SUBTÍTULO
    del demo del menú de fondo (quién habla en la cinemática), NO el personaje de la enciclopedia.
    Por eso el gate y el filtro exigen la RUTA `Gallery_CharacterSelect_C` (LECCIÓN 14: match por
    ruta, no por nombre de widget).

    UNA SOLA PASADA (07-26). Antes: `ReadSelectCaption` x2 + `ReadDetail` (que llamaba
    `ReadDetailByPath` NUEVE veces) = ONCE recorridos completos de la lista de TextBlocks, y cada
    recorrido pedía `GetFullName` de CADA texto (GetWidgetName TAMBIÉN hace GetFullName por dentro,
    así que "filtrar por nombre primero" no ahorraba nada). Eran MILES de llamadas nativas cada
    250ms en una pantalla de ~1145 widgets — y los DOS colgones del bucle de poll de la sesión del
    07-26 (14:31:38 y 14:37:01, ambos `focusStage=pf-fastpath`) cayeron justo aquí. Ahora se recorre
    la lista UNA vez pidiendo `GetFullName` una sola vez por texto, y todo el filtrado se hace en Lua
    puro (gratis). Menos carga que antes en TODOS los casos, incluso cuando no hay detalle pendiente.

    NOMBRES REPETIDOS (07-26, reportado por Iván): dos personajes DISTINTOS pueden llamarse IGUAL
    (Goku Z temprano y Goku Z base son los dos "Son Goku"; hay tres "Vegeta" y varios "Trunks"). El
    dedup era por TEXTO del nombre, así que al pasar de uno al otro el texto no cambiaba y el mod se
    quedaba CALLADO (en el registro del 07-26 hay un hueco de 1m34s, de 14:29:24 a 14:30:58,
    navegando sin oír nada). NO existe ningún campo de índice ni de número de personaje que sirva
    para distinguirlos al instante: el panel del nombre solo tiene Caption_00/01/02 y los dos botones
    de flecha (verificado en el volcado). Lo ÚNICO que los distingue de verdad es su FICHA (sus
    habilidades y categorías son distintas). Así que la ficha se sigue vigilando DESPUÉS de haberla
    anunciado: si el nombre no cambió pero la ficha cambió a otra COMPLETA y ESTABLE, es OTRO
    personaje y se re-anuncia nombre + ficha. Coste: dos lecturas estables (~0.5s tras detenerse),
    inevitable sin un dato de identidad que el juego no expone.

    SEGURIDAD: solo LEE texto (nunca toca el foco ni el HUD — LECCIÓN 3). Corre en el poll loop
    (100ms), que ya respeta uiChurnUntil. Gate por presencia con GetCachedFirstOf (barato, revalida).
    Dedup por VALOR (no flag persistente — LECCIÓN 11): al salir de la galería se limpia solo.
]]

local H = require("helpers")
local IsValidRef = H.IsValidRef

local Gallery = {}

local Speak = nil
local SpeakQueued = nil
local _lastCharaName = nil   -- nombre YA anunciado
local _announcedSig = nil    -- firma de la ficha YA anunciada para ese nombre
local _prevSig = nil         -- firma vista en el poll anterior (se exigen DOS lecturas iguales)
local _pendingDetail = false -- falta anunciar la ficha del nombre actual
local _nextPoll = 0          -- throttle: la pasada recorre TODOS los TextBlocks de la pantalla

-- FRENO ANTI-VERBORREA para el re-anuncio por "otro personaje con el mismo nombre". Si el panel de
-- ficha (`CharacterList_01_C`) llegara a OSCILAR solo entre dos contenidos estables sin que Iván se
-- mueva, la detección por firma hablaría cada ~0.5s para siempre. Este tope corta esa posibilidad de
-- raíz y NO estorba el uso real: el contador se pone a cero en cuanto el nombre cambia, así que solo
-- se agota si hay 4+ personajes ADYACENTES llamados exactamente igual. Si aparece en el log, sabremos
-- que el panel oscila y habrá que atacar eso en vez de tapar el síntoma.
local _sameNameAnnounces = 0
local SAME_NAME_LIMIT = 4

-- Contadores del DIAG temporal de tiempos ficha-tras-nombre (07-27). Quitar con el DIAG.
local _detailTicks = 0
local _detailWaits = 0

-- Valores PLANTILLA a ignorar (07-21, medido EN VIVO): FindAllOf devuelve VARIAS instancias de
-- CharacterSelect (LECCIÓN 14): una VISIBLE con el nombre real y una OCULTA con estos marcadores.
-- El F5 solo muestra la visible, así que estos NO aparecían en el volcado — solo se vieron cuando
-- el poller en vivo anunció basura ("キャラクター名称2, Name"). Hay que SALTARLOS y seguir buscando
-- la instancia con el nombre real, NO quedarse con la primera. Se añaden las plantillas de la ficha
-- de detalle (paso 2): "アイテム名" (CharaSkill_0), "Habilidad", "次へ", "9999" (encabezados/relleno).
local TEMPLATES = {
    ["キャラクター名"] = true,
    ["キャラクター名称2"] = true,
    ["アイテム名"] = true,
    ["Name"] = true,
    ["Habilidad"] = true,
    ["次へ"] = true,
    ["9999"] = true,
    [""] = true,
}

-- Texto REAL de un TextBlock, o nil si es plantilla/vacío/ilegible.
local function ReadText(tb)
    local ok, text = pcall(function() return tb:GetText():ToString() end)
    if ok and type(text) == "string" and not TEMPLATES[text] then return text end
    return nil
end

-- PASADA ÚNICA: un solo recorrido de la lista de TextBlocks, un solo GetFullName por texto.
-- Devuelve: form (Caption_02), base (Caption_01), catsStr, skillsStr.
local function ScanGallery(textBlocks)
    local form, base = nil, nil
    local cats, skills = {}, {}
    for i = 1, #textBlocks do
        local tb = textBlocks[i]
        if IsValidRef(tb) then
            local okP, path = pcall(function() return tb:GetFullName() end)
            if okP and type(path) == "string" then
                local leaf = path:match("%.([^%.]+)$")
                if leaf == "Caption_02" or leaf == "Caption_01" then
                    -- Nombre: exige la ruta del panel del personaje SELECCIONADO.
                    if path:find("Gallery_CharacterSelect_C", 1, true) then
                        local t = ReadText(tb)
                        if t then
                            if leaf == "Caption_02" then
                                if not form then form = t end
                            else
                                if not base then base = t end
                            end
                        end
                    end
                elseif leaf == "caption" then
                    -- Ficha: exige la ruta del panel de detalle del personaje actual.
                    if path:find("CharacterList_01_C", 1, true) then
                        local sk = path:match("CharaSkill_(%d+)%.")
                        if sk then
                            local n = tonumber(sk)
                            if n and n >= 1 and n <= 4 and not skills[n] then
                                skills[n] = ReadText(tb)
                            end
                        else
                            local ct = path:match("CharacterInfo_Panel00_(%d+)%.")
                            if ct then
                                local n = tonumber(ct)
                                if n and n >= 0 and n <= 6 and not cats[n + 1] then
                                    cats[n + 1] = ReadText(tb)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Compactar en orden de índice (no en orden de aparición).
    local catList, skillList = {}, {}
    for n = 1, 7 do if cats[n] then catList[#catList + 1] = cats[n] end end
    for n = 1, 4 do if skills[n] then skillList[#skillList + 1] = skills[n] end end
    return form, base, table.concat(catList, ", "), table.concat(skillList, ", ")
end

-- Encola (SpeakQueued, NO interrumpe) la ficha DESPUÉS del nombre. Al cambiar de personaje,
-- Speak(nombre, true) interrumpe y LIMPIA esta cola => navegando rápido solo suenan nombres; al
-- detenerse, suena nombre + categorías + habilidades. (El diseño que pidió Iván.)
local function SpeakDetail(catsStr, skillsStr)
    if catsStr ~= "" then SpeakQueued(catsStr) end
    if skillsStr ~= "" then SpeakQueued("Habilidades: " .. skillsStr) end
end

-- Poll: anuncia el personaje mostrado en la enciclopedia cuando cambia (RB/LB).
function Gallery.PollCharacter()
    if not Speak then return end

    -- Gate barato: ¿estamos en el detalle de personaje de la enciclopedia?
    if not H.GetCachedFirstOf("WBP_OBJ_Gallery_CharacterSelect_C") then
        -- fuera de la galería: limpia el dedup (fail-safe, no flag persistente)
        _lastCharaName = nil
        _announcedSig = nil
        _prevSig = nil
        _pendingDetail = false
        _sameNameAnnounces = 0
        return
    end

    -- THROTTLE BAJADO 0.25 -> 0.15 (07-27). Iván: "de repente demora en distinguir uno del otro".
    -- La detección exige DOS lecturas seguidas iguales de la ficha, así que el suelo teórico era 2 x 0.25
    -- = 0.5s; con 0.15 baja a 0.3s. La pasada única (un solo recorrido en vez de once) dejó margen de
    -- sobra para pagar esto: sigue costando MUCHO menos que la versión anterior a hoy.
    if os.clock() < _nextPoll then return end
    _nextPoll = os.clock() + 0.15

    local ok, textBlocks = pcall(FindAllOf, "TextBlock")
    if not ok or not textBlocks then return end

    local form, base, catsStr, skillsStr = ScanGallery(textBlocks)
    if not form then return end

    -- Si hay nombre base (transformación), el completo es "base, forma"; si no, es form solo.
    local full = form
    if base then full = base .. ", " .. form end

    local sig = catsStr .. "||" .. skillsStr
    local complete = (catsStr ~= "" and skillsStr ~= "")
    local prevSig = _prevSig
    _prevSig = sig

    if full ~= _lastCharaName then
        -- CAMBIO DE NOMBRE: anunciar YA. La ficha se DIFIERE (el nombre se actualiza al instante pero
        -- la ficha tarda un pelín; leyéndolas juntas salía la del personaje ANTERIOR — Iván 07-21).
        _lastCharaName = full
        _announcedSig = nil
        _pendingDetail = true
        _sameNameAnnounces = 0  -- el tope anti-verborrea solo cuenta seguidas SIN cambio de nombre
        _detailTicks, _detailWaits = 0, 0  -- contadores del DIAG de tiempos
        -- CLAVE: descartar la firma leída en ESTE tick. Es todavía la ficha del personaje ANTERIOR
        -- (el nombre se actualiza antes que la ficha), y si se dejara como "lectura previa" el
        -- siguiente tick podría casarla y anunciar la ficha equivocada — justo el bug de
        -- desincronización del 07-21. Así se exigen DOS lecturas POSTERIORES al cambio de nombre.
        _prevSig = nil
        Speak(full, true)
        print("[AE] Gallery character: " .. full)
        return
    end

    -- MISMO texto de nombre. Se espera a que la ficha DEJE DE CAMBIAR (dos lecturas iguales): cubre
    -- un desfase de cualquier duración, no un tiempo fijo. Se exige ficha COMPLETA (categorías Y
    -- habilidades) para no anunciar sobre una carga a medias.
    -- Contadores del DIAG de tiempos (ver más abajo): cuántas pasadas del poller han hecho falta desde el
    -- cambio de nombre, y cuántas de ellas se fueron en esperar a que la ficha estuviera completa y quieta.
    if _pendingDetail then
        _detailTicks = _detailTicks + 1
        if not complete or sig ~= prevSig then _detailWaits = _detailWaits + 1 end
    end
    if not complete or sig ~= prevSig then return end

    if _pendingDetail then
        _pendingDetail = false
        _announcedSig = sig
        -- DIAG TEMPORAL DE TIEMPOS (07-27, quitar al cerrar el caso). Medido en el livelog: entre anunciar
        -- el NOMBRE y anunciar la FICHA pasan 3 a 5 segundos de forma MUY constante, cuando el mecanismo
        -- (dos lecturas iguales) debería tardar unas 3 décimas. Esa regularidad huele a que el JUEGO tarda
        -- en poblar el panel de habilidades, no a que el mod ande lento — y encima los mismos 4-5s salían
        -- ya en el registro del 07-26, ANTES de tocar nada de esto. Pero eso es una sospecha, no un dato:
        -- este contador de ticks lo resuelve. Si sale `ticks=2` con un `esperas=` alto, el mod está listo
        -- enseguida y el tiempo se lo come el juego rellenando la ficha; si sale `ticks` alto, la culpa es
        -- del throttle o del gate de churn y hay que mirar ahí.
        print("[AE-DIAG] Gallery detail for " .. full .. " (ticks=" .. tostring(_detailTicks)
              .. " esperas=" .. tostring(_detailWaits) .. "): cats=[" .. catsStr .. "] skills=[" .. skillsStr .. "]")
        SpeakDetail(catsStr, skillsStr)
    elseif sig ~= _announcedSig then
        -- Ficha ESTABLE y DISTINTA de la ya anunciada con este mismo nombre => es OTRO personaje que
        -- se llama igual (Goku Z temprano y Goku Z base son los dos "Son Goku"). Re-anunciar
        -- nombre + ficha. `_announcedSig` se actualiza SIEMPRE (aunque el tope calle el anuncio), para
        -- no quedar comparando contra una firma ya caduca.
        _announcedSig = sig
        if _sameNameAnnounces >= SAME_NAME_LIMIT then
            print("[AE-DIAG] Gallery: tope de re-anuncios con el mismo nombre, se calla (¿panel oscilando?)")
        else
            _sameNameAnnounces = _sameNameAnnounces + 1
            Speak(full, true)
            print("[AE] Gallery character (otro con el mismo nombre): " .. full)
            print("[AE-DIAG] Gallery detail for " .. full .. ": cats=[" .. catsStr .. "] skills=[" .. skillsStr .. "]")
            SpeakDetail(catsStr, skillsStr)
        end
    end
end

function Gallery.Reset()
    _lastCharaName = nil
    _announcedSig = nil
    _prevSig = nil
    _pendingDetail = false
    _sameNameAnnounces = 0
end

function Gallery.Init(speakFn, speakQueuedFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
end

return Gallery
