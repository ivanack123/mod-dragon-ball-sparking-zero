--[[
    episode_battle.lua — Episode Battle (Story Mode) accessibility
    Handles two screens:
    1. Character Select — pick a character, continue/new game/story map
    2. Story Map — navigate chapter nodes within a character's saga

    Character select uses focus-based reading (HitButtons inside
    WBP_GRP_AI_CharacterSelect_C). Story map uses poll-based reading
    (no keyboard focus on nodes — text changes on WBP_GRP_AI_ChartTitle_C).

    Key discovery: both character panels AND action buttons (Continue,
    Story Map, New Game) receive focus as WBP_OBJ_Common_HitButton_C.
    The BTN_Menu widgets are visual labels only. We map HitButton suffix
    to BTN_Menu suffix to read button captions.
]]

local H = require("helpers")
local TryCall = H.TryCall
local TryGetProperty = H.TryGetProperty
local IsValidRef = H.IsValidRef
local GetWidgetName = H.GetWidgetName
local GetClassName = H.GetClassName
local GetCachedFirstOf = H.GetCachedFirstOf

local IconParser = require("icon_parser")

local EpisodeBattle = {}

-- === STATE ===

local Speak = nil
local SpeakQueued = nil
local ArmCooldown = nil  -- main.lua PauseFocus (set in Init): pauses ONLY the focus
                         -- scan while a story cutscene is on screen (NOT the poll loop,
                         -- so the battle HUD / rewards keep reading)

-- Character select state
local _lastCharaName = nil        -- last announced character name (CaracterText_0)
local _lastHitButtonWidget = nil  -- last focused HitButton widget ref (identity check)
local _lastChapterTitle = nil     -- last TXT_ChapterTitle value
local _announcedEntry = false     -- whether we announced entry to this screen
local _focusedSuffix = nil        -- suffix of the currently focused action button (for caption)
local _lastAnnouncedCaption = nil -- last spoken button caption (Continue/New Game/Story Map)
local _charaPendingName = nil     -- saga just announced, waiting to read its description
local _charaSettle = 0            -- ticks to wait for TXT_ChapterTitle/TXT_main to catch up

-- Story map state
local _storyMapActive = false
local _lastEventTitle = nil       -- last Text_EventTitle value
local _lastChapter = nil          -- last Text_Chapter value
local _lastScenario0 = nil        -- last Text_ScenarioTitle_0 (character saga)
local _lastScenario1 = nil        -- last Text_ScenarioTitle_1 (arc name)
local _lastEpisodeMapName = nil   -- last Episode-Map (RT) highlighted saga name
local _lastEpisodeMapArea = nil   -- last Episode-Map (RB/LB) highlighted area (chapter+arc)
local _announcedMapEntry = false  -- whether we announced entry to story map
local _mapEntryDelay = 0          -- countdown before entry announcement (lets transition finish)

-- Branch conditions state
local _lastBranchConditions = ""  -- serialized string of last announced conditions
local _lastGuideButtonCount = 0   -- visible guide button count (story node vs path node detection)
local _onPathNode = false         -- true when on a path/connector node

-- Cutscene state
local _announcedSkip = false      -- whether we announced "hold to skip" for this cutscene
local _skipIconAt = nil           -- os.clock() to do the deferred skip-icon scan (crash avoidance)
local _lastCutsceneText = nil     -- last RichText_MainTalk content (narration/dialog)

-- === SUBTÍTULO REPETIDO AL PAUSAR — fix por VENTANA DE PAUSA (2026-07-17) ===
-- PollCutsceneText clears _lastCutsceneText whenever it finds no valid line, which re-announces
-- the SAME line when it comes back. That clear is CORRECT during combat — it's what makes
-- repeated barks work (Goku fires the same "¡Kaaameee...!" ~30s apart and each must be spoken).
-- It's WRONG only while PAUSED: the game is frozen, MainTalk just went to placeholders, the line
-- never actually changed, so on un-pause Iván hears it twice.
--
-- So we hold the clear ONLY while paused, using Trackers.pauseSeenUntil (armed by main.lua
-- PollFocus from pauseMenuOpen — the REAL freeze signal, IsVisible on the pause widgets, which
-- is allowed there: PollFocus is NOT a pre-guard reader). Here we only READ a number (os.clock
-- comparison) — no widget touch, no IsVisible — so LESSON 2 (the P:cutscenetext crash) is safe.
--
-- A FAILED earlier attempt keyed this off widget PRESENCE (GetCachedFirstOf("WBP_Pause_C")),
-- inferred "not a ghost" from an F5 dump. That was invalid — the F5 lists VISIBLE widgets but
-- FindFirstOf finds ones that merely EXIST, and WBP_Pause_C exists all fight — so the hold stayed
-- armed 4m36s of combat and silenced Iván's ki-attack barks (LESSON 14). The temporized window
-- fixes both bugs: it's driven by the VISIBLE pause menu, and it's FAIL-SAFE (if the focus loop
-- dies it expires). Validated 2026-07-17: 0 barks fell inside a pause, so this never mutes one.
-- Replaces the bare `_lastCutsceneText = nil` in the two "no valid line" branches.
local function ClearCutsceneDedup(where)
    if not _lastCutsceneText then return end

    local Trackers = require("poll_trackers")  -- lazy: evita problemas de orden de carga
    -- HOLD the clear while paused (Trackers.pauseSeenUntil armed by main.lua from the VISIBLE
    -- pause menu): the frozen line never really changed, so clearing it would re-read on un-pause.
    -- Only a number comparison here (no widget touch) — LESSON 2 safe. Fail-safe: the window
    -- expires on its own if the focus loop dies. Confirmed clean 2026-07-17 (0 barks muted).
    if os.clock() < (Trackers.pauseSeenUntil or 0) then
        return
    end

    _lastCutsceneText = nil
end

function EpisodeBattle.Init(speakFn, speakQueuedFn, armCooldownFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
    ArmCooldown = armCooldownFn
end

--- preserveDedup (07-20): lo pasa SOLO el watchdog tras un cuelgue del bucle de foco. Un reinicio
--- NO es un cambio de pantalla: el usuario sigue EXACTAMENTE donde estaba. Si aquí se borra
--- `_announcedEntry` y `_lastCharaName`, al siguiente tick el lector vuelve a anunciar "Episode
--- Battle" + la BARRA DE CONTROLES completa y otra vez el nombre del personaje, ambos con
--- interrupción (Speak(..., true)) => pisa la descripción que se estaba leyendo. Medido 07-20:
--- 8 reinicios = 8 repeticiones de "Goku" + los controles, y la descripción nunca alcanzaba a
--- salir (justo lo que reportó Iván). Con preserveDedup solo se limpia la REF (que puede estar
--- muerta); los dedups de "qué ya dije" se conservan y el reinicio pasa inadvertido.
function EpisodeBattle.Reset(preserveDedup)
    _lastHitButtonWidget = nil
    if preserveDedup then return end
    _lastCharaName = nil
    _lastChapterTitle = nil
    _announcedEntry = false
    _focusedSuffix = nil
    _lastAnnouncedCaption = nil
    _charaPendingName = nil
    _charaSettle = 0
    -- Do NOT reset story map state here — story map survives screen resets
    -- because it's poll-based and the chart widget persists independently
end

function EpisodeBattle.FullReset()
    _lastCharaName = nil
    _lastHitButtonWidget = nil
    _lastChapterTitle = nil
    _announcedEntry = false
    _focusedSuffix = nil
    _lastAnnouncedCaption = nil
    _charaPendingName = nil
    _charaSettle = 0
    _storyMapActive = false
    _lastEventTitle = nil
    _lastChapter = nil
    _lastScenario0 = nil
    _lastScenario1 = nil
    _announcedMapEntry = false
    _mapEntryDelay = 0
    _lastBranchConditions = ""
    _lastGuideButtonCount = 0
    _onPathNode = false
    _announcedSkip = false
    _lastCutsceneText = nil
end

-- === PARENT CONTAINER DETECTION ===

local CONTAINER_CLASS = "WBP_GRP_AI_CharacterSelect_C"

--- Check if a widget is inside the Episode Battle character select screen.
function EpisodeBattle.IsCharaSelect(widget)
    local ok, path = pcall(function() return widget:GetFullName() end)
    if not ok then return false end
    return path:find(CONTAINER_CLASS, 1, true) ~= nil
end

-- === TEXT READING HELPERS ===

--- Find a TextBlock by name inside a container class and read its text.
local function ReadTextInContainer(fieldName, containerClass)
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == fieldName then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find(containerClass, 1, true)
               and tbPath:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    return text
                end
            end
        end
    end
    return nil
end

-- Like ReadTextInContainer but returns the VISIBLE copy's text. The Episode Map loads
-- every saga/area's ChartTitle at once (many copies with different values), so the plain
-- first-match read grabs a stale copy; reading the visible one gives the highlighted area.
local function ReadVisibleTextInContainer(fieldName, containerClass)
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end
    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == fieldName then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find(containerClass, 1, true)
               and tbPath:find("Transient", 1, true) then
                local vok, vis = pcall(function() return tb:IsVisible() end)
                if vok and vis then
                    local ok2, text = pcall(function() return tb:GetText():ToString() end)
                    if ok2 and text and text ~= "" then
                        return text
                    end
                end
            end
        end
    end
    return nil
end

local function ReadCharaSelectText(fieldName)
    return ReadTextInContainer(fieldName, CONTAINER_CLASS)
end

local function ReadChartText(fieldName)
    return ReadTextInContainer(fieldName, "WBP_GRP_AI_ChartTitle_C")
end

--- Read the button caption from a BTN_Menu widget matching a suffix.
local function ReadBtnMenuCaption(suffix)
    local targetName = "WBP_OBJ_AI_BTN_Menu_" .. suffix
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return nil end

    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "caption" then
            local ok, tbPath = pcall(function() return tb:GetFullName() end)
            if ok and tbPath:find(targetName, 1, true)
               and tbPath:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    return text
                end
            end
        end
    end
    return nil
end

--- Read guide bar from the visible WBP_GRP_GuideSet_C.
--- guideSetFilter: optional string to match a specific GuideSet instance.
--- Returns a list of readable guide button strings.
local function ReadGuideBar(guideSetFilter)
    local richBlocks = FindAllOf("RichTextBlock")
    if not richBlocks then return {} end

    local guideNames = {
        "WBP_OBJ_Guide_Btn_Present",
        "WBP_OBJ_Guide_Btn_0",
        "WBP_OBJ_Guide_Btn_1",
        "WBP_OBJ_Guide_Btn_2",
        "WBP_OBJ_Guide_Btn_3",
        "WBP_OBJ_Guide_Btn_4",
    }

    -- Japanese placeholder patterns to filter out
    local jpFilters = {
        "\227\131\152\227\131\171\227\131\151",  -- ヘルプ
        "\227\131\151\227\131\172\227\130\188",  -- プレゼ
        "\227\131\156\227\130\191\227\131\179",  -- ボタン
    }

    local results = {}
    for _, gw in ipairs(guideNames) do
        for _, rb in ipairs(richBlocks) do
            local ok, rbPath = pcall(function() return rb:GetFullName() end)
            if ok and rbPath:find(gw, 1, true)
               and rbPath:find("Transient", 1, true)
               and (not guideSetFilter or rbPath:find(guideSetFilter, 1, true)) then
                local rbName = GetWidgetName(rb)
                if rbName == "RTEXT_Help_0" or rbName == "RTEXT_Help_1" then
                    local ok2, text = pcall(function() return rb:GetText():ToString() end)
                    if ok2 and text and text:match("%S") then
                        -- Filter out Japanese placeholder text
                        local isJp = false
                        for _, jp in ipairs(jpFilters) do
                            if text:find(jp, 1, true) then
                                isJp = true
                                break
                            end
                        end
                        if not isJp then
                            table.insert(results, text)
                        end
                    end
                end
            end
        end
    end
    return results
end

-- === CHARACTER SELECT: FOCUS HANDLER ===

--- Called from main.lua OnWidgetFocused when widget is inside the character select.
function EpisodeBattle.OnCharaSelectFocused(widget)
    if not Speak then return false end

    local name = GetWidgetName(widget)

    -- Announce screen entry
    if not _announcedEntry then
        _announcedEntry = true
        _storyMapActive = false
        _announcedMapEntry = false
        Speak("Episode Battle", true)
        print("[AE] Episode Battle character select entered")

        -- Queue guide bar on first entry
        local guideBar = ReadGuideBar()
        if #guideBar > 0 then
            for _, text in ipairs(guideBar) do
                SpeakQueued(text)
            end
            print("[AE] Episode guide bar: " .. table.concat(guideBar, ", "))
        end
    end

    -- Only handle HitButton — that's what gets focus here
    local className = GetClassName(widget)
    if className ~= "WBP_OBJ_Common_HitButton_C" then
        return true
    end

    -- Track by widget identity, not name — different characters can reuse
    -- the same HitButton name (e.g. HitButton_1 for both Goku and Frieza)
    if widget == _lastHitButtonWidget then
        return true
    end
    _lastHitButtonWidget = widget

    -- Just record which action button is focused. PollCharaSelect (100ms) reads the
    -- saga name, its description and this button's caption in order, decoupled from
    -- focus timing — the game refreshes CaracterText_0 / TXT_main a frame or two AFTER
    -- the focus moves, so reading them here raced and produced skipped names, wrong
    -- descriptions, and a caption that cut off the description.
    local suffix = name:match("_(%d+)$")
    _focusedSuffix = suffix or "0"

    return true
end

--- Read the character-select saga name, description and focused button caption
--- on a 100ms cadence, in the order the user asked for and without races.
--- Sequence on a saga change: name (interrupts), then — after a short settle so the
--- game's TXT_ChapterTitle/TXT_main catch up — chapter + description, then the button
--- caption (queued, so it never cuts the description). On plain button navigation
--- (same saga) only the caption changes, and the queue is empty so it plays at once.
function EpisodeBattle.PollCharaSelect()
    if not Speak then return end
    if not _announcedEntry or _storyMapActive then return end

    local name = ReadCharaSelectText("CaracterText_0")

    -- 1) Saga changed: announce the name now, defer the description a couple of ticks
    --    so TXT_ChapterTitle/TXT_main (which lag the name) settle to the right saga.
    if name and name ~= _lastCharaName then
        _lastCharaName = name
        Speak(name, true)
        print("[AE] Episode char: " .. name)
        _charaPendingName = name
        _charaSettle = 2
        _lastAnnouncedCaption = nil  -- re-announce the button after the description
        return
    end

    -- 2) After the settle delay, read the (now caught-up) chapter + description.
    if _charaPendingName then
        if _charaSettle > 0 then
            _charaSettle = _charaSettle - 1
            return
        end
        _charaPendingName = nil

        local chapterTitle = ReadCharaSelectText("TXT_ChapterTitle")
        if chapterTitle then
            SpeakQueued(chapterTitle)
            _lastChapterTitle = chapterTitle
        end

        local storyText = ReadCharaSelectText("TXT_main")
        if storyText then
            local collapsed = storyText:gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
            if collapsed and collapsed ~= "" then
                SpeakQueued(collapsed)
            end
        end
        -- fall through so the button caption is queued right after the description
    end

    -- 3) Button caption (Continue / New Game / Story Map) for the focused button.
    --    Queued, never interrupting: on a saga change it lands after the description;
    --    on plain button navigation the queue is empty so it is spoken immediately.
    local caption = ReadBtnMenuCaption(_focusedSuffix or "0")
    if caption and caption ~= _lastAnnouncedCaption then
        _lastAnnouncedCaption = caption
        SpeakQueued(caption)
        print("[AE] Episode button: " .. caption)
    end
end

-- === EPISODE MAP: CHANGE-BASED HIGHLIGHT READING ===
-- The Episode Map (RT overview) loads every area/saga at once, so a field has ~30 STATIC
-- duplicate copies PLUS one on-screen "summary" copy that gets rewritten as you move the
-- highlight. IsVisible() can't tell them apart — off-highlight copies are marked
-- SelfHitTestInvisible, which STILL reports visible=true (that's why the visible-copy read
-- was silent). So detect the highlight by CHANGE: the summary copy is the one instance
-- whose value differs from the previous 100ms tick.
local _emArcPrev, _emArcPrimed, _emAreaSettleUntil, _emAreaLast = {}, false, 0, nil
local _emPlacePrev, _emPlacePrimed, _emPlaceSettleUntil, _emPlaceLast = {}, false, 0, nil

-- instance ("<container>_<N>") -> value for one field; also returns copy count.
local function SnapField(fieldName, container)
    local out, n = {}, 0
    local tbs = FindAllOf("TextBlock")
    if not tbs then return out, 0 end
    for _, tb in ipairs(tbs) do
        if GetWidgetName(tb) == fieldName then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path:find(container, 1, true) and path:find("Transient", 1, true) then
                local inst = path:match("(" .. container .. "_%d+)")
                if inst then
                    local ok2, txt = pcall(function() return tb:GetText():ToString() end)
                    if ok2 and txt and txt ~= "" then out[inst] = txt; n = n + 1 end
                end
            end
        end
    end
    return out, n
end

-- Which present-in-both instance changed value, and how many changed.
local function DiffExisting(cur, prev)
    local inst, count = nil, 0
    for k, v in pairs(cur) do
        local pv = prev[k]
        if pv ~= nil and pv ~= v then count = count + 1; inst = k end
    end
    return inst, count
end

-- Gather all copies of a field in a container, each with its RenderOpacity + Visibility.
local function GatherCopies(fieldName, container)
    local copies = {}
    local tbs = FindAllOf("TextBlock")
    if not tbs then return copies end
    for _, tb in ipairs(tbs) do
        if GetWidgetName(tb) == fieldName then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path:find(container, 1, true) and path:find("Transient", 1, true) then
                local vok, val = pcall(function() return tb:GetText():ToString() end)
                if vok and val and val ~= "" then
                    local _, op = pcall(function() return tb:GetRenderOpacity() end)
                    local _, ve = pcall(function() return tb:GetVisibility() end)
                    copies[#copies + 1] = {
                        inst = path:match("(" .. container .. "_%d+)") or "?",
                        val  = val,
                        op   = (type(op) == "number") and op or -1,
                        ve   = ve,
                    }
                end
            end
        end
    end
    return copies
end

-- AREA ("Cambiar área" / switch between Namek & Saiyan, via History-Map nodes or the Episode
-- Map RT+RB+A teleport): RESOLVED. The definitive diag (2026-07-10) proved the arc
-- (Text_ScenarioTitle_1) and chapter (Text_Chapter) DO change live and single-copy when you
-- switch area ("Arco del planeta Namekusei"/"Capítulo 2" <-> "Arco saiyajin"/"Capítulo 1"), so
-- they are NOT pause-shadowed. Switching area also changes the selected NODE, so PollStoryMap's
-- node-change block already speaks the new arc+chapter before the node name for the A-CONFIRM
-- case (works). RB PREVIEW is NOT cleanly solvable: the definitive diag (2026-07-10) proved the
-- readable header (Text_ScenarioTitle_1 / Text_Chapter) does NOT change while cycling RB/LB — it
-- stayed on "Arco del planeta Namekusei / Capítulo 2" the whole time, and only commits on A. So
-- the previewed area's name lives only in the block highlight (no live-readable marker: op/vis
-- both useless) or in churn-transient widgets the poll is paused over. Reading it would need the
-- same risky churn-reading that crashes (this very test crashed at P:storymap during the reload).
-- No-op: the A-confirm path covers hearing the area, and this poll's extra FindAllOf only added
-- crash exposure during the "Cambiar área" map churn.
function EpisodeBattle.PollEpisodeMapArea()
    return
end

-- PLACE (left stick): announce the description of the one Map_CharacterSelect copy that
-- changed. Saga names ("Saga de ...") are left to the saga reader in PollStoryMap.
function EpisodeBattle.PollEpisodeMapPlace()
    if not Speak then return end
    -- Same as PollEpisodeMapArea: only scan while a map is up, never during entry teardown.
    if not _storyMapActive then return end
    local CONT = "WBP_OBJ_AI_Map_CharacterSelect_C"
    local now, n = SnapField("TXT_CharacterName", CONT)
    if n < 2 then _emPlacePrimed, _emPlacePrev, _emPlaceLast = false, {}, nil; return end
    if not _emPlacePrimed then _emPlacePrev = now; _emPlacePrimed = true; return end
    if os.clock() < _emPlaceSettleUntil then _emPlacePrev = now; return end

    local inst, count = DiffExisting(now, _emPlacePrev)
    _emPlacePrev = now
    if count == 0 then return end
    if count >= 2 then _emPlaceSettleUntil = os.clock() + 0.3; return end

    local desc = now[inst]
    if desc and desc:match("%a") and not desc:match("^Saga") and desc ~= _emPlaceLast then
        _emPlaceLast = desc
        Speak(desc, true)
        print("[AE] Episode map place: " .. desc)
    end
end

-- === STORY MAP: POLL-BASED READING ===

--- Poll for story map visibility and node changes.
--- Uses safe FindAllOf("TextBlock") scan — no FindFirstOf crash risk.
function EpisodeBattle.PollStoryMap()
    if not Speak then return end

    -- Cheap gate BEFORE the heavy scan. ReadChartText does a full FindAllOf("TextBlock")
    -- with a GetFullName per widget; running that EVERY tick — including the story-mode intro
    -- cutscene while the scene loads — walked a widget mid-teardown and crashed natively
    -- (crumb P:storymap entering an episode). Only the History/Episode map has a ChartTitle
    -- container, so GetCachedFirstOf (cached singleton, misses throttled to 500ms) lets us
    -- skip the scan entirely when no map is up. If the map was up and the container is now
    -- gone, fall through with saga=nil so the close/reset path below still runs.
    local chartTitle = GetCachedFirstOf("WBP_GRP_AI_ChartTitle_C")
    local onMap = chartTitle and IsValidRef(chartTitle)
    if not onMap and not _storyMapActive then return end

    -- Detect story map via Text_ScenarioTitle_0 (always present, never placeholder)
    local saga = onMap and ReadChartText("Text_ScenarioTitle_0") or nil

    if not saga then
        if _storyMapActive then
            _storyMapActive = false
            _announcedMapEntry = false
            _lastEventTitle = nil
            _lastChapter = nil
            _lastScenario0 = nil
            _lastScenario1 = nil
            _lastBranchConditions = ""
            _lastGuideButtonCount = 0
            _onPathNode = false
            print("[AE] Story map closed")
        end
        return
    end

    -- Story map is visible
    if not _storyMapActive then
        _storyMapActive = true
        -- Start delay countdown (~100ms) to let transition finish
        _mapEntryDelay = 6  -- 6 × 16ms poll cycles
        Speak("Story Map", true)
        print("[AE] Story map detected, waiting for transition")
    end

    -- Read event title. "???" is the game's placeholder for a hidden/locked node
    -- (it PERSISTS while you sit on that node) and also flashes briefly while the map
    -- loads. Keep it RAW here so moving onto — and back off — a locked node still
    -- registers as a change; the entry block below skips it to avoid the load flash.
    local eventTitle = ReadChartText("Text_EventTitle")

    -- Delayed entry announcement (waits for char select to fade)
    if not _announcedMapEntry then
        if _mapEntryDelay > 0 then
            _mapEntryDelay = _mapEntryDelay - 1
            return
        end
        _announcedMapEntry = true

        -- Re-read saga fresh (char select text should be gone by now)
        saga = ReadChartText("Text_ScenarioTitle_0")
        local arc = ReadChartText("Text_ScenarioTitle_1")
        local chapter = ReadChartText("Text_Chapter")

        local parts = {}
        if saga then table.insert(parts, saga) end
        if arc then table.insert(parts, arc) end
        if chapter then table.insert(parts, chapter) end
        if #parts > 0 then
            Speak(table.concat(parts, ", "), true)
            print("[AE] Story map: " .. table.concat(parts, ", "))
        end

        _lastScenario0 = saga
        _lastScenario1 = arc
        _lastChapter = chapter
        _lastEventTitle = eventTitle
        if eventTitle and eventTitle ~= "???" then
            SpeakQueued(eventTitle)
        end

        -- Read Dragon Orb status
        local orb = ReadChartText("TXT_Orb")
        if orb then
            SpeakQueued(orb)
        end

        -- Read guide bar (now the story map's guide bar, not char select's)
        local guideBar = ReadGuideBar()
        if #guideBar > 0 then
            for _, text in ipairs(guideBar) do
                SpeakQueued(text)
            end
            print("[AE] Story map guide: " .. table.concat(guideBar, ", "))
        end

        return
    end

    -- LT/RT cycles the saga/arc/chapter WITHOUT moving the node: catch that here when the
    -- node is UNCHANGED (the node block below handles the node-changed case).
    if eventTitle == _lastEventTitle then
        local ctx = {}
        local s = ReadChartText("Text_ScenarioTitle_0")
        if s and s ~= _lastScenario0 then _lastScenario0 = s; table.insert(ctx, s) end
        local a = ReadChartText("Text_ScenarioTitle_1")
        if a and a ~= _lastScenario1 then _lastScenario1 = a; table.insert(ctx, a) end
        local c = ReadChartText("Text_Chapter")
        if c and c ~= _lastChapter then _lastChapter = c; table.insert(ctx, c) end
        if #ctx > 0 then
            Speak(table.concat(ctx, ", "), true)
            print("[AE] Story map context: " .. table.concat(ctx, ", "))
        end
    end

    -- Poll for node changes. Skip titles that are "Capítulo N" — in the Episode Map that
    -- field holds the AREA (a chapter), read separately below, not a real node.
    if eventTitle and eventTitle ~= _lastEventTitle then
        _lastEventTitle = eventTitle
        if not (eventTitle:match("^Cap") and eventTitle:find("tulo", 1, true)) then
            local ctx = {}
            local saga = ReadChartText("Text_ScenarioTitle_0")
            if saga and saga ~= _lastScenario0 then _lastScenario0 = saga; table.insert(ctx, saga) end
            local arc = ReadChartText("Text_ScenarioTitle_1")
            if arc and arc ~= _lastScenario1 then _lastScenario1 = arc; table.insert(ctx, arc) end
            local chapter = ReadChartText("Text_Chapter")
            if chapter and chapter ~= _lastChapter then _lastChapter = chapter; table.insert(ctx, chapter) end

            local nodeText = (eventTitle == "???") and "Bloqueado" or eventTitle
            if #ctx > 0 then
                Speak(table.concat(ctx, ", "), true)
                SpeakQueued(nodeText)
            else
                Speak(nodeText, true)
            end
            -- Log the spoken context (arc/chapter) too, so switching AREA (Namek<->Saiyan,
            -- which changes arc+chapter along with the node) is visible in the log, not just
            -- the node name. Confirmed live-readable single-copy fields (diag 2026-07-10).
            local ctxLog = (#ctx > 0) and (table.concat(ctx, ", ") .. " | ") or ""
            print("[AE] Story node: " .. ctxLog .. (eventTitle == "???" and "locked (???)" or eventTitle))
        end
    elseif not eventTitle then
        _lastEventTitle = nil  -- connector/branch node: forget so return re-announces
    end

    -- Episode Map SAGA (RT/LT): highlighted saga name in Map_CharacterSelect's
    -- TXT_CharacterName. Gated to "Saga ..." so it never double-reads a place description
    -- (those go through PollEpisodeMapPlace). Area (RB/LB) + place (stick) are handled by
    -- the change-based readers above, not here.
    local epName = ReadTextInContainer("TXT_CharacterName", "WBP_OBJ_AI_Map_CharacterSelect_C")
    if epName and not epName:match("^Saga") then epName = nil end
    if epName and epName ~= _lastEpisodeMapName then
        _lastEpisodeMapName = epName
        Speak(epName, true)
        print("[AE] Episode map: " .. epName)
    elseif not epName then
        _lastEpisodeMapName = nil
    end


    -- Detect path node vs story node via guide button count
    local guideOk, guideButtons = pcall(FindAllOf, "WBP_OBJ_Guide_Btn_0_C")
    if guideOk and guideButtons then
        local visCount = 0
        for _, btn in ipairs(guideButtons) do
            local vok, vis = pcall(function() return btn:IsVisible() end)
            if vok and vis then visCount = visCount + 1 end
        end

        if visCount ~= _lastGuideButtonCount then
            local wasPath = _onPathNode
            _lastGuideButtonCount = visCount
            -- Path nodes have <=3 guide buttons, story nodes have 4+
            _onPathNode = (visCount <= 3)

            if not _onPathNode and wasPath then
                -- Left a path/branch node: clear the branch dedup so re-entering a
                -- branch re-announces its choices (user prefers that over silence).
                _lastBranchConditions = ""
            end

            if _onPathNode and not wasPath then
                -- Just moved to a path node — read branch conditions
                local ok2, branchWidgets = pcall(FindAllOf, "WBP_OBJ_AI_BranchConditons_Set_C")
                if ok2 and branchWidgets then
                    local visibleIds = {}
                    for _, bw in ipairs(branchWidgets) do
                        local visOk, visible = pcall(function() return bw:IsVisible() end)
                        if visOk and visible then
                            local nameOk, fullName = pcall(function() return bw:GetFullName() end)
                            if nameOk then
                                local instId = fullName:match("(WBP_OBJ_AI_BranchConditons_Set_C_%d+)")
                                if instId then visibleIds[instId] = true end
                            end
                        end
                    end

                    local textBlocks2 = FindAllOf("TextBlock")
                    if textBlocks2 then
                        local condByInst = {}
                        local instOrder = {}
                        for _, tb in ipairs(textBlocks2) do
                            if GetWidgetName(tb) == "Text_BranchCondition_0" then
                                local ok3, tbPath = pcall(function() return tb:GetFullName() end)
                                if ok3 and tbPath:find("Transient", 1, true) then
                                    local instId = tbPath:match("(WBP_OBJ_AI_BranchConditons_Set_C_%d+)")
                                    if instId and visibleIds[instId] and not condByInst[instId] then
                                        local ok4, text = pcall(function() return tb:GetText():ToString() end)
                                        if ok4 and text and text ~= "" then
                                            condByInst[instId] = text
                                            table.insert(instOrder, instId)
                                        end
                                    end
                                end
                            end
                        end

                        local parts = {}
                        for _, instId in ipairs(instOrder) do
                            local text = condByInst[instId]
                            -- Skip locked ("???") conditions: they carry no info, and
                            -- announcing "1 locked, 2 locked, 3 locked" every time the
                            -- path heuristic re-fired was pure repetitive noise.
                            if text and text ~= "???" then
                                table.insert(parts, text)
                            end
                        end

                        -- Dedup: the guide-button-count heuristic re-flags path nodes
                        -- as you move around the map, so announce a given path only
                        -- once (reset on map close / FullReset), killing the repeats.
                        local key = "path|" .. table.concat(parts, "|")
                        if key ~= _lastBranchConditions then
                            _lastBranchConditions = key
                            Speak("Path", true)
                            for _, part in ipairs(parts) do
                                SpeakQueued(part)
                            end
                            print("[AE] Path node" .. (#parts > 0
                                and (", conditions: " .. table.concat(parts, ", "))
                                or ", no unlocked conditions"))
                        end
                    end
                end
            end
        end
    end
end

--- Returns true if the story map is currently active.
function EpisodeBattle.IsStoryMapActive()
    return _storyMapActive
end

-- === CUTSCENE SKIP: POLL-BASED ===

--- Poll for WBP_GRP_AI_EventSkip_C visibility.
--- Announces "Hold confirm to skip" once when it first appears.
--- Only polls after episode battle has been entered (avoids FindFirstOf crash during transitions).
function EpisodeBattle.PollCutsceneSkip()
    if not Speak then return end
    -- Only poll when we've been in episode battle context
    -- FindFirstOf on this class crashes during main menu → char select transitions
    if not _announcedEntry and not _storyMapActive then return end

    local ok, skipWidget = pcall(FindFirstOf, "WBP_GRP_AI_EventSkip_C")
    if not ok or not skipWidget or not IsValidRef(skipWidget) then
        if _announcedSkip then _announcedSkip = false end
        return
    end

    local visible = TryCall(skipWidget, "IsVisible")
    if not visible then
        if _announcedSkip then _announcedSkip = false end
        return
    end

    -- A story cutscene is on screen (the skip prompt is up): pause the focus scan.
    -- It has no menu to find here and can HANG iterating UserWidgets while the game
    -- tears the scene down during a hitch (the freeze culprit — crumb "F:pollfocus").
    -- Subtitles/skip run BEFORE the pause guard, so cutscene reading keeps flowing.
    -- NO pausar el foco si estamos en el MENÚ PRINCIPAL (el demo NO es historia). Banderita = GRATIS,
    -- sin llamada nativa aquí (LECCIÓN 2: una nativa en este lector pre-guardia truena, crumb P:cutscenetext).
    local PT = package.loaded["poll_trackers"]
    if not (PT and PT.onMainMenu) then
        if ArmCooldown then ArmCooldown(0.3) end
        -- Robust shared guard the focus loop reads directly (reliable: this detection is a direct
        -- FindFirstOf, unlike the focus loop's cached eventSkip check that can go momentarily nil and
        -- crash mid-cutscene). 2s bridges quiet gaps between subtitles; re-armed every 100ms tick.
        if PT then PT.cutsceneGuardUntil = os.clock() + 2.0 end
    end

    if not _announcedSkip then
        _announcedSkip = true
        -- DEFER the icon scan ~0.4s. The skip prompt appears exactly as the battle scene loads,
        -- and doing FindAllOf("RichTextBlock") + GetFullName per block mid-load walked a widget
        -- in teardown and crashed the game natively (crumb P:cutsceneskip). Waiting lets the
        -- scene settle; and if the churn detector arms meanwhile, the caller skips us entirely.
        _skipIconAt = os.clock() + 0.4
        return
    end

    -- Deferred: scene has settled, now do the (heavy) icon scan and announce once.
    if _skipIconAt and os.clock() >= _skipIconAt then
        _skipIconAt = nil
        local skipIcon = nil
        local ok2, skipPath = pcall(function() return skipWidget:GetFullName() end)
        local skipId = ok2 and skipPath:match("(WBP_GRP_AI_EventSkip_C_%d+)") or nil
        if skipId then
            local richBlocks = FindAllOf("RichTextBlock")
            if richBlocks then
                for _, rb in ipairs(richBlocks) do
                    if GetWidgetName(rb) == "RichText_PadButton_1" then
                        local ok3, rbPath = pcall(function() return rb:GetFullName() end)
                        if ok3 and rbPath:find(skipId, 1, true) then
                            local ok4, text = pcall(function() return rb:GetText():ToString() end)
                            if ok4 and text and text ~= "" then skipIcon = text end
                            break
                        end
                    end
                end
            end
        end
        if skipIcon then
            SpeakQueued("Hold " .. skipIcon .. " to skip")
        else
            SpeakQueued("Hold to skip")
        end
        print("[AE] Cutscene skip available")
    end
end

-- === CUTSCENE TEXT: POLL-BASED ===

--- Poll for narration/dialog text in cutscenes.
--- Reads RichText_MainTalk inside WBP_GRP_Common_EventText_C.
--- Announces character name (if present) + dialog text on change.
function EpisodeBattle.PollCutsceneText()
    if not Speak then return end
    -- NO leer subtítulos durante el ARRANQUE (antes de ver el menú). CRASH P:cutscenetext al arrancar
    -- (07-22, en "Revisando contenido descargable", trans=true): este lector es PRE-GUARDIA (corre antes
    -- del gate de churn/pausa) y hace GetCachedFirstOf (FindFirstOf nativo) de 4 contenedores; durante la
    -- carga de datos esos tocan widgets a medio crear y truenan (LECCIÓN 2). No hay NINGUNA cutscene antes
    -- del menú, así que gatear por startupSeen no pierde nada. Trackers.startupSeen es un STRING/bool
    -- (cero nativa aquí, LECCIÓN 2 a salvo). Una vez visto el menú, lee normal (demo + historia).
    local _PT = package.loaded["poll_trackers"]
    if _PT and not _PT.startupSeen then return end
    -- Gate: the character dialog box appears as WBP_OBJ_Common_TextWindow_C on its
    -- own (tutorial, some events), wrapped inside WBP_GRP_Common_EventText_C (story
    -- cutscenes), OR as the black speech bubble WBP_OBJ_Common_TexWin_Black_C used by
    -- the MAIN MENU chatter (Goku/Trunks/Pilaf/Whis etc.). Accept any of the three —
    -- gating on a subset is why those lines went silent. Cached lookup keeps this
    -- cheap when no dialog box is present.
    local eventBox = GetCachedFirstOf("WBP_OBJ_Common_TextWindow_C")
                  or GetCachedFirstOf("WBP_GRP_Common_EventText_C")
                  or GetCachedFirstOf("WBP_OBJ_Common_TexWin_Black_C")
                  or GetCachedFirstOf("WBP_GRP_Common_CinemaText_C")
    if not eventBox then return end

    local richBlocks = FindAllOf("RichTextBlock")
    if not richBlocks then
        ClearCutsceneDedup("norich")
        return
    end

    -- Find RichText_MainTalk inside either dialog container (TextWindow on its own,
    -- or the EventText wrapper used by story cutscenes). eventTextPath is whichever
    -- container instance holds it, used below to find the matching character name.
    local mainTalkText = nil
    local eventTextPath = nil
    -- The tournament / battle-stage announcer box (BS_Top) takes PRIORITY over every other box.
    -- During the churny tournament load a team-select chatter box ("Goku, ¡Bien, adelante!") is in
    -- the widget list at the same time, and the old first-match `break` let it win and BURY the
    -- announcer's second line ("¡Ya comenzó el Torneo...!"). So we scan the WHOLE list: take the
    -- BS_Top line the moment we see it, otherwise fall back to the first other line (old behaviour).
    local fbText = nil
    local fbPath = nil
    -- On the CHARACTER-SELECT ROSTER the game reuses the BS_Top box for the selected-fighter voice
    -- bark ("¡Bien, adelante!", confirmed in F5 at BS_Top...TexWin_Black.RichText_MainTalk). That bark
    -- repeats as you browse characters and competes with the roster name reading (Iván). Detect the
    -- roster by its grid panel (WBP_GRP_BS_CharaList_DP_C, only present while picking characters — the
    -- announcer intro plays BEFORE it appears, confirmed in the log). Guard NOT-in-battle so a
    -- lingering panel can never be mistaken for the roster. Used below to skip ONLY BS_Top MainTalk.
    local onRoster = false
    if GetCachedFirstOf("WBP_GRP_BS_CharaList_DP_C") then
        local Battle = package.loaded["battle"]
        onRoster = not (Battle and Battle.WasBattleActive and Battle.WasBattleActive())
    end
    for _, rb in ipairs(richBlocks) do
        local wn = GetWidgetName(rb)
        -- WORLD TOURNAMENT / battle-stage box (WBP_GRP_BS_Top_00_TextSub) is WEIRD: the announcer/
        -- fighter line sits in RichText_PadButton, while MainTalk holds icon/JP junk (confirmed in
        -- F5: PadButton = "¡Ya comenzó el Torneo de las Artes Marciales! Hoy descubriremos quién es
        -- el mejor guerrero de todos."). So accept PadButton too — but ONLY inside that box, since
        -- everywhere else PadButton is just a button-prompt icon/label.
        if wn == "RichText_MainTalk" or wn == "RichText_PadButton" then
            local ok, rbPath = pcall(function() return rb:GetFullName() end)
            if ok and rbPath:find("Transient", 1, true) then
                local cpath, isTournament
                -- BS_Top match first (covers its MainTalk AND its PadButton) so it wins priority.
                local bs = rbPath:match("(WBP_GRP_BS_Top_00_TextSub_C_%d+)")
                if bs and not (onRoster and wn == "RichText_MainTalk") then
                    -- On the roster, BS_Top MainTalk is the repeating fighter bark — skip it there so
                    -- it stops burying the roster name reading. Its PadButton (the announcer's second
                    -- line) is still taken, and BS_Top OFF the roster (the announcer intro) is untouched.
                    cpath = bs
                    isTournament = true
                elseif wn == "RichText_MainTalk" then
                    cpath = rbPath:match("(WBP_OBJ_Common_TextWindow_C_%d+)")
                         or rbPath:match("(WBP_GRP_Common_EventText_C_%d+)")
                         or rbPath:match("(WBP_MainMenu_Base_TextSub_C_%d+)")
                         or rbPath:match("(WBP_GRP_Common_CinemaText_C_%d+)")
                end
                -- (RichText_PadButton outside BS_Top stays ignored: it's a button-prompt icon/label.)
                if cpath then
                    local ok2, text = pcall(function() return rb:GetText():ToString() end)
                    -- Require a REAL localized line and KEEP SCANNING past junk (don't break on it):
                    -- skip the あいうえお placeholder, icon markup, and any Japanese lead byte. Essential
                    -- for the tournament box (MainTalk junk comes before the real PadButton line) and
                    -- harmless elsewhere (real story lines are Latin with no icon).
                    if ok2 and text and text ~= ""
                       and not text:find("\227\129\130\227\129\132\227\129\134\227\129\136\227\129\138", 1, true)
                       and text:match("%a") and not text:find("<icon", 1, true)
                       and not text:find("\227", 1, true) then
                        if isTournament then
                            -- Announcer box wins outright — stop here.
                            mainTalkText = text
                            eventTextPath = cpath
                            break
                        elseif not fbText then
                            -- First other line: remember it, but keep scanning for a BS_Top line.
                            fbText = text
                            fbPath = cpath
                        end
                    end
                end
            end
        end
    end

    -- No tournament line this pass: use the first other line found (old first-match behaviour).
    if not mainTalkText and fbText then
        mainTalkText = fbText
        eventTextPath = fbPath
    end

    if not mainTalkText then
        ClearCutsceneDedup("notalk")
        return
    end

    -- Cinema-style NARRATION (WBP_GRP_Common_CinemaText_C) is cutscene-only, so pause
    -- the focus scan while it's up (covers the between-lines gaps the skip prompt might
    -- miss). We do NOT pause for the plain dialog box (WBP_OBJ_Common_TextWindow_C) —
    -- that box is ALSO used for battle chatter mid-fight, and pausing the focus there
    -- made the in-battle pause menu laggy. Skippable cutscene dialogue is still covered
    -- by the EventSkip prompt in PollCutsceneSkip.
    if eventTextPath and ArmCooldown
       and eventTextPath:find("WBP_GRP_Common_CinemaText_C", 1, true) then
        ArmCooldown(0.3)
    end

    -- OUTSIDE battle, a story cutscene (e.g. the long Freezer dialogue) has NO menu to focus,
    -- so pause the focus scan for its WHOLE duration — re-armed each tick a line is on screen,
    -- covering the long gaps BETWEEN lines where the focus loop was reading a cached menu widget
    -- mid-teardown and crashing (crumb F:pollfocus, no skip prompt to catch it). In battle we do
    -- NOT do this: the same dialog box is used for mid-fight chatter, and continuous focus pausing
    -- lagged the pause menu — there, only the on-change pause below applies.
    -- ONLY when a REAL dialogue line is present: when you PAUSE mid-cutscene, the dialogue box
    -- CONTAINERS persist behind the pause menu but MainTalk is cleared to placeholders (icon
    -- markup / Japanese), so arming on mere container presence kept the focus paused and the PAUSE
    -- MENU never read (Iván: "no lee en algunas escenas"). Requiring a real Spanish line (latin
    -- letters, no <icon> tag, no Japanese) fixes that without weakening the crash protection.
    -- NOT for the MAIN-MENU chatter (WBP_MainMenu_Base_TextSub_C): that plays over the NAVIGABLE
    -- main menu, so pausing the focus there made the menu feel slow and re-read "Episode Battle"
    -- (Iván). Only story-cutscene containers (TextWindow/EventText/CinemaText) pause the focus.
    -- The TOURNAMENT menu (setup / post-tournament "crear torneo" / selection) shows announcer
    -- banter in the SAME WBP_OBJ_Common_TextWindow_C container that story cutscenes use, but it plays
    -- over a NAVIGABLE menu — pausing the focus there pinned the menu SILENT (Iván: "al volver al menú
    -- del torneo dejó de leer el menú, sólo el presentador"), the same failure as the main-menu attract
    -- demo. WBP_TBL_Menu_C is present ONLY on those tournament menu/setup screens (confirmed in F5:
    -- entries 30-33 char-select + 286+ post-tournament; ABSENT during the battle and story cutscenes),
    -- so when it's present, DON'T pause the focus — the announcer line is still read above.
    -- PRESENCE ONLY, no IsVisible: an earlier version called TryCall(tm,"IsVisible") here and that
    -- native call CRASHED PollCutsceneText (crumb P:cutscenetext) during the churny tournament setup
    -- transition ("Seleccionar nivel de CPU") — proven: the build WITH the IsVisible crashed there,
    -- the build without it did not. GetCachedFirstOf presence is the same safe gate the rest of the
    -- mod uses (PollCutsceneText already does 4 of them above without crashing), and WBP_TBL_Menu_C is
    -- absent during battles/story cutscenes (F5), so presence alone is correct and safe.
    local onTournamentMenu = GetCachedFirstOf("WBP_TBL_Menu_C") and true or false
    -- NO pausar el foco en el MENÚ PRINCIPAL: su demo usa contenedores de cutscene de historia, y
    -- pausar dejaba el menú MUDO para siempre. Banderita (la pone el bucle de foco) = cero nativa aquí
    -- (LECCIÓN 2). Raíz del arreglo de mudez, pulida (Iván 07-20).
    local PT_mm = package.loaded["poll_trackers"]
    local onMainMenu = PT_mm and PT_mm.onMainMenu or false
    if eventTextPath and ArmCooldown and not onTournamentMenu and not onMainMenu
       and not eventTextPath:find("WBP_MainMenu_Base_TextSub", 1, true)
       -- ...and NOT the tournament/battle-stage box (WBP_GRP_BS_Top_00_TextSub): the MAIN-MENU
       -- attract demo uses this SAME box, and pausing the focus for it pinned the whole menu
       -- silent forever (Iván: "lee subtítulos pero no el menú"). Read its line, don't pause focus.
       and not eventTextPath:find("WBP_GRP_BS_Top_00_TextSub", 1, true)
       and mainTalkText:match("%a") and not mainTalkText:find("<icon", 1, true)
       and not mainTalkText:find("\227", 1, true) then
        local Battle = package.loaded["battle"]
        if not (Battle and Battle.WasBattleActive and Battle.WasBattleActive()) then
            ArmCooldown(0.6)  -- was 0.3: cover the GAP after a line (diag showed focus resumed in
            -- the gap and crashed reading a still-settling menu widget, crumb F:pollfocus at boot)
        end
        -- Also arm the robust shared cutscene guard (story containers only, NOT menu chatter), so
        -- the focus loop stays paused across the quiet gaps between subtitles too, not just while a
        -- line is on screen. Complements the skip-prompt arming in PollCutsceneSkip.
        local PT = package.loaded["poll_trackers"]
        if PT then PT.cutsceneGuardUntil = os.clock() + 2.0 end
    end

    -- Skip placeholder/template filler shown while the dialog box is loading
    -- (no real line yet): the game fills MainTalk with the あいうえお hiragana
    -- placeholder. Bytes below are UTF-8 for "あいうえお".
    if mainTalkText:find("\227\129\130\227\129\132\227\129\134\227\129\136\227\129\138", 1, true) then
        return
    end
    -- Broader placeholder skip: when you PAUSE mid-cutscene the dialogue box persists but MainTalk
    -- is cleared to icon markup ("<icon .../>") or Japanese filler. Those aren't real lines —
    -- processing them re-armed the focus pause / announced junk, so the pause menu stayed silent.
    -- A real Spanish line has latin letters, no <icon> tag, and no Japanese lead bytes.
    if mainTalkText:find("<icon", 1, true) or mainTalkText:find("\227", 1, true)
       or not mainTalkText:match("%a") then
        return
    end

    -- A cutscene line on screen = a scripted CINEMATIC beat where the pawns churn (special move
    -- like Kamehameha/Kaioken, transformation, taunt, OR a pre-battle intro cutscene while the
    -- battle scene loads its pawns). Signal PollHUD to back off — reading a churning pawn here is
    -- the stubborn Freezer P:hud crash, and the widget-count guard is blind to pawn churn. Armed
    -- for ANY cutscene (not just once the battle is "active"): the crash also hits the intro
    -- cutscene BEFORE "Battle started", and outside a battle PollHUD has nothing to read anyway.
    -- Re-armed each tick a line is up (this runs before the dedup return below, so it's continuous).
    do
        local PT = package.loaded["poll_trackers"]
        if PT then PT.battleCutsceneUntil = os.clock() + 0.8 end
    end

    if mainTalkText == _lastCutsceneText then return end
    _lastCutsceneText = mainTalkText

    -- A NEW subtitle just appeared: the dialog box rebuilds its widget tree at that instant, and
    -- the focus loop's fast path (reading a CACHED menu widget) can hit one mid-teardown and
    -- crash natively (crumb F:pollfocus, seen in the Recoome battle cutscene). Pause the focus
    -- scan BRIEFLY — only on the change, NOT while a line sits on screen — so it covers the churny
    -- update without lagging the in-battle pause menu (the reason the plain box isn't paused above).
    -- 1.0s (was 0.4): also covers the window AFTER the last cutscene line where the skip prompt is
    -- gone but the battle scene is still loading (the F:pollfocus episode-entry crash landed there).
    -- NOT for main-menu chatter (navigable menu — would lag it, same as the continuous pause above).
    -- ...and NOT the tournament menu (WBP_TBL_Menu_C visible): its announcer banter is in TextWindow
    -- but plays over a navigable menu, so a per-line pause would stutter/silence it too.
    if ArmCooldown and not onTournamentMenu
       and not (eventTextPath and (eventTextPath:find("WBP_MainMenu_Base_TextSub", 1, true)
                                or eventTextPath:find("WBP_GRP_BS_Top_00_TextSub", 1, true))) then
        ArmCooldown(1.0)
    end

    -- Look for Text_CharaName in the same TextWindow container
    local charaName = nil
    if eventTextPath then
        local textBlocks = FindAllOf("TextBlock")
        if textBlocks then
            for _, tb in ipairs(textBlocks) do
                if GetWidgetName(tb) == "Text_CharaName" then
                    local ok, tbPath = pcall(function() return tb:GetFullName() end)
                    if ok and tbPath:find(eventTextPath, 1, true) then
                        local ok2, name = pcall(function() return tb:GetText():ToString() end)
                        if ok2 and name and name ~= "" then
                            charaName = name
                        end
                        break
                    end
                end
            end
        end
    end

    -- Ignore the placeholder character name (キャラ名はここ = "chara name goes
    -- here"), shown before the real name loads. Bytes are UTF-8 for that string.
    if charaName and charaName:find("\227\130\173\227\131\163\227\131\169\229\144\141\227\129\175\227\129\147\227\129\147", 1, true) then
        charaName = nil
    end
    -- Any Japanese-lead-byte name is a placeholder that hasn't localized yet (e.g. "内容" seen in
    -- the tournament dialog box). Drop it — read the line without a bogus speaker rather than "内容 dice".
    if charaName and charaName:byte(1) and charaName:byte(1) >= 0xE0 then
        charaName = nil
    end

    -- Speak the line. Voiced dialog (has a character name) is read as
    -- "Name dice: text"; narration (no name) is read as plain text. The user
    -- wants voiced dialog read too — the game's audio isn't a screen reader and
    -- is often in another language than the subtitles.
    local collapsed = mainTalkText:gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if collapsed and collapsed ~= "" then
        local line = collapsed
        if charaName and charaName ~= "" then
            line = charaName .. " dice: " .. collapsed
        end
        SpeakQueued(line)
        print("[AE] Cutscene text: " .. line)
    end
end

return EpisodeBattle
