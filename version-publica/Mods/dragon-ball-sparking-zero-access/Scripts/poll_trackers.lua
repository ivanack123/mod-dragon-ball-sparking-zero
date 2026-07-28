--[[
    poll_trackers.lua — Dialog, help window, and screen change tracking
    Polled at 100ms intervals from the main loop.
    IsValidRef() on FindFirstOf singletons only; FindAllOf iterations trust fresh results.
]]

local H = require("helpers")
local TryCall = H.TryCall
local IsValidRef = H.IsValidRef
local GetWidgetName = H.GetWidgetName
local GetCachedFirstOf = H.GetCachedFirstOf
local Speech = require("speech")  -- for TimeSinceSpeech() (reward gap detection)

local Trackers = {}

local Speak = nil
local SpeakQueued = nil
local PauseFocus = function() end  -- injected by Init; pauses ONLY the focus scan

-- Shared transition cooldown: checked by main loop and poll functions.
-- Set when a dialog dismisses or a map loads.
Trackers.transitionCooldownUntil = 0

-- Shared "the game is (or was <window ago) PAUSED" signal. Armed by main.lua PollFocus
-- whenever pauseMenuOpen is true (any of the 4 frozen pause screens visible). Read by
-- episode_battle.PollCutsceneText to HOLD the subtitle dedup while paused, so the same
-- line isn't re-announced on un-pause. Temporized on purpose (FAIL-SAFE): if the focus
-- loop dies, it expires and behaviour returns to normal — barks are never at risk
-- because barks only happen while the game runs (pauseMenuOpen false). Validated
-- 2026-07-17: of 88 subtitles, 86 fell in active play and 0 barks fell inside a pause.
Trackers.pauseSeenUntil = 0

-- Shared "a story cutscene is on screen" guard. Set (extended) by the POLL-loop cutscene readers
-- (PollCutsceneSkip when the skip-prompt is visible, PollCutsceneText when a story subtitle shows),
-- which detect the cutscene RELIABLY via direct FindFirstOf. The focus loop reads this to pause its
-- scan for the whole cutscene: its own eventSkip check uses cached lookups that can go momentarily
-- nil (miss-cache) and let the scan walk a tearing-down scene -> F:pollfocus (the recurring crash
-- the live log caught during the "Cell/androids" intro narration). A generous timeout bridges the
-- quiet gaps between subtitles so the pause never lapses mid-cutscene.
Trackers.cutsceneGuardUntil = 0
-- Banderita: ¿estamos en el MENÚ PRINCIPAL? La PONE el bucle de foco (que ya detecta ModeMenu de forma
-- segura y gateada). La LEE PollCutsceneText/Skip (lectores pre-guardia) para NO pausar el foco por el
-- DEMO del menú (que el mod tomaba como historia => mudez). Leer una banderita es GRATIS (cero nativa),
-- así se evita la llamada nativa que tronaba el lector (LECCIÓN 2, crumb P:cutscenetext).
Trackers.onMainMenu = false
-- Se activa al ver el menú principal por 1ª vez = el juego YA arrancó. Público para que los lectores
-- pre-guardia (PollCutsceneText/Skip) NO lean durante la carga inicial (crash P:worldtrans/cutscenetext).
Trackers.startupSeen = false

-- Single source of truth for "we're mid-transition, skip UObject access".
-- Used by the focus loop, the poll loop, and individual pollers to avoid
-- iterating/dereferencing UObjects while the game is destroying/creating widgets.
function Trackers.IsInTransition()
    return os.clock() < Trackers.transitionCooldownUntil
end

-- Arm the transition cooldown for the given duration (seconds), extending
-- the existing window if one is already armed (never shortens it).
function Trackers.ArmTransitionCooldown(seconds)
    local until_ = os.clock() + seconds
    if until_ > Trackers.transitionCooldownUntil then
        Trackers.transitionCooldownUntil = until_
    end
end

function Trackers.Init(speakFn, speakQueuedFn, pauseFocusFn)
    Speak = speakFn
    SpeakQueued = speakQueuedFn
    if pauseFocusFn then PauseFocus = pauseFocusFn end
end

-- === DIALOG TRACKING ===

local lastDialogState = {}

local function GetDialogText(dialog)
    local richBlocks = FindAllOf("RichTextBlock")
    if not richBlocks then return nil end

    local dialogFullName = dialog:GetFullName()
    local dialogId = dialogFullName:match("(WBP_Dialog_%d+_C_%d+)")
    if not dialogId then return nil end

    for _, rb in ipairs(richBlocks) do
        local rbPath = rb:GetFullName()
        if rbPath:find(dialogId, 1, true) then
            local rbName = GetWidgetName(rb)
            if rbName:find("Text_Main") then
                local getText = TryCall(rb, "GetText")
                if getText then
                    local str = TryCall(getText, "ToString")
                    if str and str ~= "" then return str end
                end
            end
        end
    end

    return nil
end

function Trackers.MarkDialogSeen(dialogId)
    local dialogTypes = {"WBP_Dialog_000_C", "WBP_Dialog_002_C"}
    for _, dtype in ipairs(dialogTypes) do
        local dialogs = FindAllOf(dtype)
        if dialogs then
            for i, d in ipairs(dialogs) do
                if d:GetFullName():find(dialogId, 1, true) then
                    local text = GetDialogText(d)
                    lastDialogState[dtype .. "_" .. i] = {visible = true, text = text}
                end
            end
        end
    end
end

function Trackers.PollDialogs()
    local dialogTypes = {"WBP_Dialog_000_C", "WBP_Dialog_002_C"}

    for _, dtype in ipairs(dialogTypes) do
        local dialogs = FindAllOf(dtype)
        if dialogs then
            for i, d in ipairs(dialogs) do
                -- Skip dead dialogs: IsVisible()/GetFullName() on a widget mid-teardown
                -- HANGS natively (pcall can't catch it) and wedges the whole mod.
                if not IsValidRef(d) then goto continue end
                local visible = TryCall(d, "IsVisible")
                if not visible then
                    local key = dtype .. "_" .. i
                    if lastDialogState[key] and lastDialogState[key].visible then
                        -- Dialog dismissed — arm transition cooldown.
                        -- UE5 takes visibly longer than 400ms to fully reap widgets after
                        -- dismissal; 800ms gives the game thread room and closes the native
                        -- UObject-freed-between-FindAllOf-and-method race window.
                        -- SUBIDO DE 0.8s A 2.0s (07-28). TRES crashes en el MISMO punto del arranque, todos
                        -- justo al desaparecer el aviso "Revisando contenido descargable": el 07-21
                        -- (documentado), el 07-26 (`P:wcount`) y el 07-28 (`P:dialogs`, con el mod cargado
                        -- limpio y sin un solo error de Lua). En el último, el livelog imprime "Dialog
                        -- dismissed" a las 00:14:56 y el juego muere a las 00:14:57: la ventana de 800ms
                        -- expiró JUSTO mientras el juego seguía montando el menú principal (un rebuild de
                        -- ~1000 widgets), el poll se soltó y `PollDialogs` escaneó en pleno teardown.
                        -- Los 800ms eran una estimación de julio ("400ms no basta"), no una medida. 2.0s
                        -- cubre lo observado con margen.
                        -- QUÉ SE PIERDE: tras cerrar CUALQUIER diálogo el lector espera 2s en vez de 0.8s.
                        -- Aceptable: a un diálogo que se cierra le sigue casi siempre una transición o una
                        -- carga, donde no hay nada que leer todavía. Si Iván notara que algo tras un diálogo
                        -- tarda en leerse, este número es lo primero a bajar.
                        Trackers.ArmTransitionCooldown(2.0)
                        print("[AE] Dialog dismissed, transition cooldown 800ms")
                    end
                    if lastDialogState[key] then
                        lastDialogState[key].visible = false
                    end
                else
                    local text = GetDialogText(d)
                    local key = dtype .. "_" .. i

                    local prev = lastDialogState[key]
                    local isNew = not prev or not prev.visible
                    local textChanged = prev and prev.text ~= text

                    if (isNew or textChanged) and text then
                        local cleaned = text:gsub("\n", " "):gsub("%s+", " ")
                        Speak(cleaned, true)
                        print("[AE] Dialog: " .. cleaned)
                    elseif isNew and not text then
                        Speak("Dialog opened", true)
                    end

                    lastDialogState[key] = {visible = true, text = text}
                end
                ::continue::
            end
        end
    end
end

-- === REWARD NOTIFICATIONS (story mode + gifts) ===
-- Story-mode battle rewards show up as menu notification pop-ups
-- (WBP_GRP_MainMenu_Notification_gift_C), NOT the versus result panel that
-- Battle.PollResult watches, so they went completely unread. The pop-up is a
-- PERSISTENT ghost with NO "new reward" signal of its own: F5 confirmed the same
-- instance, always visible, holding the same text from entry 13 to entry 435 — it
-- never closes, never re-creates, never blanks.
--
-- It used to forget the last reward between battles (on the Battle.Reset lifecycle),
-- which produced a vicious cycle: at the START of the next fight the stale text was
-- read as new (Iván: "iniciando pelea me lee otra vez recompensas dadas antes"), and
-- that re-memorized the same key, so when the fight was actually WON and the game
-- refreshed the pop-up with the SAME amounts, the dedup swallowed it. Net effect,
-- proven in the 2026-07-17 log: the Bills reward read on time (00:58:02), but the
-- Freezer (won 01:07:18) and Zamas (won 01:20:19) rewards were never announced at all
-- — they surfaced ~6 min late at the start of the NEXT fight (01:13:19 / 01:26:23).
--
-- Fix: key the read off the VICTORY EVENT instead of the battle lifecycle. The dedup
-- is released only by Trackers.ArmRewardRefresh(), called by the two panels that DO
-- carry a real per-victory signal (verified in the same F5: the mission/message panel
-- content changes on each win — "…(Goku) 010" at the Bills win, "008" at Freezer,
-- "009" at Zamas — and the rank-up panel has a genuine visibility cycle). The stale
-- text is therefore never re-read at the start of a fight, and a real reward is
-- announced even when its amounts match the previous one.
local _lastRewardKey = nil
local _giftWasVisible = false  -- to pause focus only WHEN the reward popup closes (teardown)
local _pendingRewards = nil    -- captured reward list waiting for a quiet gap to announce
local _pendingRewardKey = nil
local _pendingSince = 0        -- os.clock() when captured (for the max-wait fallback)

Trackers.lastRewards = nil     -- last announced reward list, for the repeat hotkey (F6)

-- Called by the victory-signal panels below (message/mission + rank-up) the moment their
-- content changes, i.e. exactly when the game refreshes the gift pop-up. Only releases the
-- dedup — PollRewards still gates on the battle lifecycle and on real (non-placeholder)
-- content, so this cannot make it speak outside a battle.
function Trackers.ArmRewardRefresh()
    _lastRewardKey = nil
end

-- Announce a captured reward list and remember it so F6 can repeat it later.
local function AnnounceRewards(rewards)
    Speak("Recompensas nuevas", true)
    for _, r in ipairs(rewards) do
        SpeakQueued(r)
    end
    Trackers.lastRewards = rewards
    print("[AE] Rewards: " .. table.concat(rewards, ", "))
end

function Trackers.PollRewards()
    if not Speak then return end

    -- A reward is captured and waiting: announce it once the talking has a ~3s gap
    -- (so the post-battle cutscene subtitles don't bury/interrupt it), or after a
    -- 15s max-wait fallback. The captured list persists even if the gift popup has
    -- already closed, so the reward is never lost.
    if _pendingRewards then
        -- Announce on a ~3s speech gap (so post-battle cutscene lines don't bury it), or an 8s
        -- max-wait fallback. Fallback was 15s but that let a reward from the PREVIOUS story battle
        -- linger and get announced at the START of the NEXT one (Iván: "me leyó la recompensa pasada
        -- al inicio de la batalla del Androide 16"). 8s surfaces it during the post-battle transition,
        -- before the next fight, without being so short it fires over the win cutscene.
        if Speech.TimeSinceSpeech() >= 3.0 or (os.clock() - _pendingSince) >= 8.0 then
            AnnounceRewards(_pendingRewards)
            _lastRewardKey = _pendingRewardKey
            _pendingRewards = nil
            _pendingRewardKey = nil
        end
        return
    end

    local Battle = require("battle")  -- lazy require: avoids module load-order issues
    if not Battle.WasBattleActive() then
        -- NOTE: deliberately does NOT clear _lastRewardKey. Doing that here was the bug:
        -- it made the next fight's start re-read the pop-up's stale text. Only a real
        -- victory signal (ArmRewardRefresh) releases the dedup now.
        return
    end
    local gift = GetCachedFirstOf("WBP_GRP_MainMenu_Notification_gift_C")
    if not gift or not TryCall(gift, "IsVisible") then
        if _giftWasVisible then
            _giftWasVisible = false
            -- The reward popup just CLOSED => the churny return to the story starts now.
            -- Pause ONLY the focus scan briefly to cover the teardown (the focus fast path
            -- was reading a cached, freed menu widget here -> crash F:pollfocus). We do NOT
            -- pause while the screen is UP, so its buttons (retry / continue) stay readable.
            PauseFocus(1.5)
        end
        return
    end
    _giftWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    -- Collect "amount name" per gift item, skipping placeholders (item name
    -- "アイテム名", amount all-9s) shown in empty template slots. `seen` dedups the exact same
    -- "amount name" appearing twice (two gift slots / copies show the same Zeni → the announce
    -- read "15000 Zeni, 15000 Zeni"); distinct rewards (EXP / Zeni / an outfit) are unaffected.
    local rewards, seen = {}, {}
    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "Txt_ItemName" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Notification_gift", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, name = pcall(function() return tb:GetText():ToString() end)
                if ok2 and name and name:match("%S")
                   and not name:find("\227\130\162\227\130\164\227\131\134\227\131\160", 1, true) then
                    local parent = path:match("(.+)%.Txt_ItemName$")
                    local num = nil
                    if parent then
                        for _, tb2 in ipairs(textBlocks) do
                            if GetWidgetName(tb2) == "TXT_Num" then
                                local pok, p2 = pcall(function() return tb2:GetFullName() end)
                                if pok and p2 and p2:find(parent, 1, true) then
                                    local nok, nt = pcall(function() return tb2:GetText():ToString() end)
                                    if nok and nt and nt:match("%S") and not nt:match("^9+$") then
                                        num = nt
                                    end
                                    break
                                end
                            end
                        end
                    end
                    local entry = num and (num .. " " .. name) or name
                    if not seen[entry] then
                        seen[entry] = true
                        table.insert(rewards, entry)
                    end
                end
            end
        end
    end

    if #rewards == 0 then return end

    local key = table.concat(rewards, "|")
    if key == _lastRewardKey then return end

    -- Don't announce right now — post-battle cutscene dialogue would bury it. Capture
    -- it; the pending block at the top speaks it during the next quiet gap.
    _pendingRewards = rewards
    _pendingRewardKey = key
    _pendingSince = os.clock()
end

-- === TOURNAMENT / MISSION MESSAGE NOTIFICATION ===
-- The GRAND PRIZE for winning a tournament (plus mission-complete / unlock notices) lives in a
-- panel SEPARATE from the gift pop-up: WBP_GRP_MainMenu_Notification_Message_C, whose items hold
-- Txt_Header + Txt_Detail (confirmed in F5: "Recompensas nuevas", "Nuevo espacio de equipo
-- desbloqueado", "Nuevo gesto desbloqueado", "La habilidad de Jiren ha aumentado a 1", "Misión
-- completada"). PollRewards only reads the GIFT pop-up (EXP/Zeni/items), so these went unread
-- (Iván: "el premio final del torneo no me lo leyó, sólo los zenis"). This panel shows on the
-- POST-tournament menu AFTER the battle lifecycle has ended, so it can't be gated on WasBattleActive
-- like PollRewards — it is gated on the panel being visible with real content, deduped by content,
-- and re-announced when it reappears (reset on disappear) — the same pattern as PollUnlocks/PollLevelUp.
local _lastMsgNotifKey = nil
local _msgNotifWasVisible = false
function Trackers.PollMessageNotification()
    if not Speak then return end
    local msg = GetCachedFirstOf("WBP_GRP_MainMenu_Notification_Message_C")
    if not msg or not TryCall(msg, "IsVisible") then
        if _msgNotifWasVisible then
            _msgNotifWasVisible = false
            _lastMsgNotifKey = nil               -- reset so the next appearance re-announces
            if PauseFocus then PauseFocus(1.0) end  -- brief focus pause over the panel teardown
        end
        return
    end
    _msgNotifWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    -- Collect each Txt_Header / Txt_Detail line under the Message notification, in order, deduped.
    local items, seen = {}, {}
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb)
        if wn == "Txt_Header" or wn == "Txt_Detail" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Notification_Message", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, txt = pcall(function() return tb:GetText():ToString() end)
                -- Keep only a real localized line: has a latin letter, no Japanese lead byte (skips
                -- the "アイテム名"/placeholder filler shown in empty template slots).
                if ok2 and txt and txt:match("%a") and not txt:find("\227", 1, true) then
                    if not seen[txt] then
                        seen[txt] = true
                        table.insert(items, txt)
                    end
                end
            end
        end
    end

    if #items == 0 then return end
    local key = table.concat(items, "|")
    if key == _lastMsgNotifKey then return end
    _lastMsgNotifKey = key

    -- Content just changed => a win was just registered and the gift pop-up has been
    -- refreshed with this battle's reward. Let PollRewards read it (see ArmRewardRefresh).
    Trackers.ArmRewardRefresh()

    Speak("Recompensas y desbloqueos", true)
    for _, it in ipairs(items) do SpeakQueued(it) end
    print("[AE] Message notification: " .. table.concat(items, ", "))
end

-- === TOURNAMENT BRACKET (between-rounds screen) ===
-- Between rounds the game shows the tournament bracket (semifinals / final) where the announcer
-- narrates the next match. That screen is a DISPLAY (not a navigable menu), so nothing has keyboard
-- focus and the focus reader can't announce it; and the round name lives in WBP_TBL_Advanced_C's
-- TXT_Advanced field (confirmed in F5: "¡Semifinales!", "¡Final!"), which no reader watched — so the
-- screen was silent (Iván: "la pantalla del cuadro con las semifinales y la final no lee"). This
-- runs in the POLL loop (not the focus loop), so the announcer's focus pause doesn't block it.
-- NOTE: the bracket shows the WHOLE structure, so it reads the round labels PRESENT, not just the
-- current one — the highlighted "current round" has no readable marker (same wall as the roster).
local _lastBracketKey = nil
local _bracketWasVisible = false
function Trackers.PollTournamentBracket()
    if not Speak then return end
    local adv = GetCachedFirstOf("WBP_TBL_Advanced_C")
    if not adv or not TryCall(adv, "IsVisible") then
        if _bracketWasVisible then
            _bracketWasVisible = false
            _lastBracketKey = nil            -- reset so the NEXT round's bracket re-announces
        end
        return
    end
    _bracketWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local rounds, seen = {}, {}
    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "TXT_Advanced" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("WBP_TBL_Advanced_C", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, txt = pcall(function() return tb:GetText():ToString() end)
                if ok2 and txt and txt:match("%a") and not txt:find("\227", 1, true) then
                    if not seen[txt] then seen[txt] = true; table.insert(rounds, txt) end
                end
            end
        end
    end

    if #rounds == 0 then return end
    local key = table.concat(rounds, "|")
    if key == _lastBracketKey then return end
    _lastBracketKey = key

    Speak("Cuadro del torneo", true)
    for _, r in ipairs(rounds) do SpeakQueued(r) end
    print("[AE] Tournament bracket: " .. table.concat(rounds, ", "))
end

-- === TOURNAMENT PRIZE (character/item won on the victory screen) ===
-- Winning a tournament can award a CHARACTER (Iván won "Goku (adolescente)"). That prize shows on
-- the victory screen (WBP_TBL_Victory_C) inside a claim dialog WBP_Dialog_TBL_000_C whose fields hold
-- the prize name + category (confirmed in F5: Txt_Header="Goku (adolescente)", TXT_Quantity=
-- "Personajes"). It is NOT in the gift pop-up (EXP/Zeni) nor the message notification (unlocks), so
-- no reader caught it (Iván: "gané un personaje y no me lo leyó"). Gated on the dialog visible, dedup,
-- reset on disappear. Field names are jumbled in this game, so read Txt_Header + TXT_Quantity (the
-- prize name and its category) regardless of which logically-named field holds which.
local _lastPrizeKey = nil
local _prizeWasVisible = false
function Trackers.PollTournamentPrize()
    if not Speak then return end
    local dlg = GetCachedFirstOf("WBP_Dialog_TBL_000_C")
    if not dlg or not TryCall(dlg, "IsVisible") then
        if _prizeWasVisible then
            _prizeWasVisible = false
            _lastPrizeKey = nil               -- reset so the next prize re-announces
        end
        return
    end
    _prizeWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local items, seen = {}, {}
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb)
        if wn == "Txt_Header" or wn == "TXT_Quantity" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("WBP_Dialog_TBL_000_C", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, txt = pcall(function() return tb:GetText():ToString() end)
                if ok2 and txt and txt:match("%a") and not txt:find("\227", 1, true) then
                    if not seen[txt] then seen[txt] = true; table.insert(items, txt) end
                end
            end
        end
    end

    if #items == 0 then return end
    local key = table.concat(items, "|")
    if key == _lastPrizeKey then return end
    _lastPrizeKey = key

    Speak("Recompensa del torneo", true)
    for _, it in ipairs(items) do SpeakQueued(it) end
    print("[AE] Tournament prize: " .. table.concat(items, ", "))
end

-- === PLAYER LEVEL-UP TRACKING ===

local _lastLevelUpKey = nil
local _rankupWasVisible = false  -- to pause focus only WHEN the level-up panel closes

-- Reads the post-battle "player level up" panel (WBP_GRP_BS_PlayerRankUP_C). Its
-- Text_ fields hold the label ("Nivel de jugador") and the new number; one field is a
-- Japanese placeholder ("有効") that has no ASCII letters/digits, so it's skipped.
function Trackers.PollLevelUp()
    if not Speak then return end
    local panel = GetCachedFirstOf("WBP_GRP_BS_PlayerRankUP_C")
    if not panel or not TryCall(panel, "IsVisible") then
        if _rankupWasVisible then
            _rankupWasVisible = false
            -- Panel just CLOSED: pause focus briefly to cover the teardown (same
            -- F:pollfocus window as rewards). NOT paused while up, so the result/retry
            -- menu buttons stay readable.
            PauseFocus(1.5)
        end
        _lastLevelUpKey = nil
        return
    end
    _rankupWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local label, number = nil, nil
    for _, tb in ipairs(textBlocks) do
        if (GetWidgetName(tb) or ""):find("^Text_") then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("PlayerRankUP", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text:match("[%a%d]") then
                    text = (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
                    if text:match("%a") then
                        label = label or text        -- has letters => the label
                    elseif text:match("^%d+$") then
                        number = number or text      -- pure digits => the new level
                    end
                end
            end
        end
    end

    if not label and not number then return end
    local key = (label or "") .. "|" .. (number or "")
    if key == _lastLevelUpKey then return end
    _lastLevelUpKey = key

    -- Second victory signal, for wins that grant a rank/level but no mission-complete
    -- notice (2026-07-17 log, 01:16:31 "Subida de rango" with no "Misión completada").
    Trackers.ArmRewardRefresh()

    local msg = label or "Subida de nivel"
    if number then msg = msg .. ", " .. number end
    Speak(msg, true)
    print("[AE] Level up: " .. msg)
end

-- === SAGA-COMPLETION UNLOCKS TRACKING ===

local _lastUnlockKey = nil
local _unlockWasVisible = false

-- Reads the end-of-saga result screen (WBP_GRP_AI_Result_C): everything just unlocked
-- — characters ("Vegeta (GT)"), forms ("Supersaiyajin 4"), the saga name, custom-battle
-- and photo unlocks, etc. Keeps only fields with ASCII letters, which drops the noise
-- fields ("?", "×9", "+", "100000", Japanese placeholders テキストブロック/シナリオ解放).
function Trackers.PollUnlocks()
    if not Speak then return end
    local panel = GetCachedFirstOf("WBP_GRP_AI_Result_C")
    if not panel or not TryCall(panel, "IsVisible") then
        if _unlockWasVisible then
            _unlockWasVisible = false
            PauseFocus(1.5)  -- cover the churny return to the map (crash F:pollfocus window)
        end
        _lastUnlockKey = nil
        return
    end
    _unlockWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local items, seen = {}, {}
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb) or ""
        -- Content fields only: skip Text_Name ("Aceptar" button) and layout numbers.
        if wn == "caption" or wn == "Text_Title" or wn == "Text_Name_Sub"
           or wn == "Text_Num" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("WBP_GRP_AI_Result", 1, true)
               and path:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text:match("%a") then  -- has ASCII letters => real name/label
                    text = (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
                    if #text > 1 and not seen[text] then
                        seen[text] = true
                        table.insert(items, text)
                    end
                end
            end
        end
    end

    if #items == 0 then return end
    local key = table.concat(items, "|")
    if key == _lastUnlockKey then return end
    _lastUnlockKey = key

    Speak("Desbloqueado", true)
    for _, it in ipairs(items) do SpeakQueued(it) end
    print("[AE] Unlocks: " .. table.concat(items, ", "))
end

-- === DECISION BRANCH (directional story choice) ===
-- A story battle can pause on a DIRECTIONAL choice: WBP_GRP_AI_DecisionBranch_0_C holds four
-- buttons laid out as a cross — Btn_Top / Btn_Left / Btn_Right / Btn_Bottom — each with a
-- `caption` (e.g. "Combatir con Krillin"). You push the stick/D-pad in a direction to pick that
-- option. A blind player can't see the cross, and moving the stick reads nothing (no keyboard
-- focus on these), so on appearance we announce EVERY option WITH its direction ("Arriba,
-- Combatir con Krillin; Izquierda, Combatir con Ten; ..."). No highlight-tracking needed — each
-- direction IS a fixed option. Empty slots hold the Japanese placeholder キャラ名はここ (skipped).
local _lastDecision = nil
local _DIR = { Top = "Arriba", Bottom = "Abajo", Left = "Izquierda", Right = "Derecha" }
local _DIR_ORDER = { "Top", "Left", "Right", "Bottom" }

function Trackers.PollDecisionBranch()
    if not Speak then return end
    local panel = GetCachedFirstOf("WBP_GRP_AI_DecisionBranch_0_C")
    if not panel or not TryCall(panel, "IsVisible") then
        _lastDecision = nil
        return
    end

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    -- First real Spanish caption per direction button.
    local byDir = {}
    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "caption" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("DecisionBranch_Btn_", 1, true)
               and path:find("Transient", 1, true) then
                local dir = path:match("DecisionBranch_Btn_(%a+)")
                if dir and _DIR[dir] and not byDir[dir] then
                    local ok2, text = pcall(function() return tb:GetText():ToString() end)
                    -- real Latin option only (skip empty + Japanese placeholder, lead byte >=0xE0)
                    if ok2 and text and text ~= "" and text:byte(1) < 0xE0 and text:match("%a") then
                        byDir[dir] = (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
                    end
                end
            end
        end
    end

    local parts = {}
    for _, dir in ipairs(_DIR_ORDER) do
        if byDir[dir] then table.insert(parts, _DIR[dir] .. ", " .. byDir[dir]) end
    end
    if #parts == 0 then return end

    local key = table.concat(parts, "|")
    if key == _lastDecision then return end
    _lastDecision = key

    Speak("Decisión", true)
    for _, p in ipairs(parts) do SpeakQueued(p) end
    print("[AE] Decision branch: " .. table.concat(parts, " / "))
end

-- === BATTLE DETAILS (pause menu → "Detalles de batalla") ===
-- The pause menu can open a requirements panel that never read anything. Content lives in
-- WBP_OBJ_Pause_Require_Content_N > {Text_Title, caption} (the game mixes the two field names,
-- so pairing them per row is unreliable). We just read EVERY real value in Content-number order,
-- deduped: Objetivo ("Golpea a Guldo."), Objetivo secundario, Condiciones de derrota ("Tu salud
-- se redujo a 0."), Dificultad actual ("Reducción de dificultad: no"), etc. Gated + deduped so it
-- announces once when the panel opens.
local _lastBattleDetails = nil
function Trackers.PollBattleDetails()
    if not Speak then return end
    -- CLASH SHIELD (mirrors PollHUD): scanning widget refs during a CLASH's pawn churn (invisible to
    -- the widget-count guard) crashed this poller natively at crumb P:battledetails during a Goku-vs-17
    -- clash (2026-07-18). PollHUD backs off on clashActiveUntil and survives clashes; this poller lacked
    -- it. Zero loss: the details screen only opens from the FROZEN pause menu, and clashActiveUntil is
    -- never live there (a clash ends before you can pause; PollHUD proves it doesn't stick). Does NOT
    -- touch the clash-mash prompt (that's PollClash).
    -- NOTE: do NOT also gate on battleCutsceneUntil here — a battle subtitle LINGERS frozen on the pause
    -- screen and PollCutsceneText re-arms that window every tick while paused, which left the details
    -- SILENT (Iván, 2026-07-18). The original cutscene P:battledetails crash is covered by the hard gate
    -- below, not by a churn window.
    if Trackers.clashActiveUntil and os.clock() < Trackers.clashActiveUntil then
        return
    end
    -- HARD GATE: scanning needs proof we're really on a paused details screen, because the panel's
    -- OWN cached IsVisible false-positived during a story cutscene (the Majin-Vegeta scene) and the
    -- FindAllOf(TextBlock) loop below walked the churning scene and crashed natively (crumb
    -- P:battledetails).
    -- The gate USED to require WBP_Pause_C, assuming the details are a submenu drawn ON TOP of the
    -- battle pause menu. The F5 DISPROVED that: the details screen REPLACES the pause menu, so
    -- WBP_Pause_C is NOT visible there (dump entry 86: Pause_Requirement_C + Requirement_List
    -- visible, WBP_Pause_C absent) -> the gate never opened and the details went SILENT (regression
    -- Iván hit: "antes sí leía y ahora no"). WBP_Pause_Requirement_C is the details screen's OWN
    -- root and is visible ONLY there (absent from every battle/cutscene entry, 69-85), so it gates
    -- just as safely against the cutscene false-positive AND opens on the right screen.
    local req = GetCachedFirstOf("WBP_Pause_Requirement_C")
    local pause = GetCachedFirstOf("WBP_Pause_C")
    if not ((req and TryCall(req, "IsVisible")) or (pause and TryCall(pause, "IsVisible"))) then
        _lastBattleDetails = nil
        return
    end
    local panel = GetCachedFirstOf("WBP_OBJ_Pause_Requirement_List_C")
    if not panel or not TryCall(panel, "IsVisible") then
        _lastBattleDetails = nil
        return
    end

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    local byNum = {}  -- Content number -> { text values }
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb)
        if wn == "Text_Title" or wn == "caption" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Pause_Require_Content_", 1, true)
               and path:find("Transient", 1, true) then
                local n = tonumber(path:match("Pause_Require_Content_(%d+)"))
                if n then
                    local ok2, text = pcall(function() return tb:GetText():ToString() end)
                    -- real Latin text only (skip empty, lone numbers, Japanese lead byte >=0xE0)
                    if ok2 and text and text:match("%a") and text:byte(1) < 0xE0 then
                        byNum[n] = byNum[n] or {}
                        table.insert(byNum[n], text)
                    end
                end
            end
        end
    end

    local nums = {}
    for n in pairs(byNum) do table.insert(nums, n) end
    table.sort(nums)

    local items, seen = {}, {}
    for _, n in ipairs(nums) do
        for _, v in ipairs(byNum[n]) do
            v = (v:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
            if #v > 1 and not seen[v] then seen[v] = true; table.insert(items, v) end
        end
    end
    if #items == 0 then return end

    local key = table.concat(items, "|")
    if key == _lastBattleDetails then return end
    _lastBattleDetails = key

    Speak("Detalles de batalla", true)
    for _, it in ipairs(items) do SpeakQueued(it) end
    print("[AE] Battle details: " .. table.concat(items, ", "))
end

-- === CLASH / IMPACT ("choque de golpes" y "choque de poderes") ===
-- Two clash types, both a button-MASH struggle the blind player couldn't see or respond to:
--   • MELEE clash: WBP_GRP_Impact_SP_A_C / _B_C (two attacks collide).
--   • BEAM/power struggle: WBP_GRP_BrastImpact_C ("Blast Impact" — Kamehameha vs blast). Confirmed
--     via diag: its button icon lives under PowerLeftSet / IMP / BoostButton inside it.
-- Both put the button-to-mash in a RichText_PadButton. We gate on either container being visible,
-- then read a REAL Pad_NN icon (skip inert-template placeholders) and announce "¡Choque! Machaca
-- <botón>" once per clash. The raw icon markup is passed to the speech layer (runs IconParser).
local _clashOn = false
function Trackers.PollClash()
    if not Speak then return end
    -- Only during an ACTIVE battle: clashes can't happen before the fight starts, and the heavy
    -- FindAllOf("RichTextBlock") scan below crashed during the pre-battle EPISODE-ENTRY cutscene
    -- (crumb P:clash) when a clash container happened to read visible mid-churn.
    local Battle = package.loaded["battle"]
    if not (Battle and Battle.WasBattleActive and Battle.WasBattleActive()) then _clashOn = false; return end

    local panel = GetCachedFirstOf("WBP_GRP_Impact_SP_A_C")
                  or GetCachedFirstOf("WBP_GRP_Impact_SP_B_C")
                  or GetCachedFirstOf("WBP_GRP_BrastImpact_C")
    if not panel or not TryCall(panel, "IsVisible") then _clashOn = false; return end

    -- Find the real button icon inside a clash container (melee Impact_SP or beam BrastImpact).
    -- The widget carries icons for MULTIPLE controllers (a PS4 one AND an Xbox one). Grabbing the
    -- first read a PS icon ("L3") that didn't match Iván's Xbox pad, so it "didn't say the button".
    -- Prefer the Xbox/XSX icon (the device the guide bars use); fall back to any real icon.
    local iconXbox, iconAny = nil, nil
    local richBlocks = FindAllOf("RichTextBlock")
    if richBlocks then
        for _, rb in ipairs(richBlocks) do
            local ok, path = pcall(function() return rb:GetFullName() end)
            if ok and path and path:find("Transient", 1, true)
               and (path:find("Impact_SP", 1, true) or path:find("BrastImpact", 1, true)) then
                local ok2, raw = pcall(function() return rb:GetText():ToString() end)
                -- real controller icon only (skip AAA / Japanese placeholder templates)
                if ok2 and raw and raw:find("Pad_", 1, true)
                   and not raw:find("AAA", 1, true) and not raw:find("\227", 1, true) then
                    if raw:find("XSX", 1, true) or raw:find("Xbox", 1, true) then
                        iconXbox = raw
                        break
                    elseif not iconAny then
                        iconAny = raw
                    end
                end
            end
        end
    end
    local icon = iconXbox or iconAny

    -- No real button = the clash is not active (or just ended). RESET here, not on panel
    -- visibility: BrastImpact/Impact_SP stay "visible" (SelfHitTestInvisible) between clashes, so
    -- keying the once-per-clash flag on visibility left it stuck true and the SECOND clash (e.g.
    -- Recoome's blast after Goku's Kamehameha) never announced. Keying it on the button presence
    -- lets each clash re-announce.
    if not icon then _clashOn = false; return end

    -- An active clash is a cinematic struggle: the pawns churn (special-move / beam animation),
    -- and PollHUD reading them mid-churn crashes (crumb P:hud, seen during Goku's Kamehameha vs
    -- Freezer). Signal the HUD to back off while the clash button is on screen. Re-armed each tick.
    Trackers.clashActiveUntil = os.clock() + 0.6

    if _clashOn then return end
    _clashOn = true
    Speak("¡Choque! Machaca ", true)
    SpeakQueued(icon)  -- speech layer converts the icon tag to the button name
    print("[AE] Clash: mash " .. icon)
end

-- === STORY-MAP NODE DETAILS (X / Y panel) TRACKING ===

local _lastChartKey = nil
local _chartWasVisible = false
local _chartPendingKey = nil   -- content seen but not yet settled/announced
local _chartSettle = 0         -- ticks left to wait for the panel to finish populating
local _chartWaitNum = 0        -- ticks spent waiting for reward AMOUNTS to load in
local _lastRewardPreview = nil -- dedup for the separate reward-amount announcement
-- The recap story, objective, and reward amounts live spread across SEVERAL overlapping
-- widgets on this screen (ChartDetails, AI_Reward_Set, its children), each populated
-- differently per view — trying to detect "which view" kept dropping the recap story or
-- the amounts. So just read EVERY real value of these fields from any ChartDetails/Reward
-- widget, deduped: the recap, "Anteriormente...", the objective, and EXP/Zeni WITH their
-- numbers all come through; placeholders ("?", "???", all-9s, Japanese, bare "EXP") drop.
-- Narrative first, rewards last.
local _CHART_OBJ = { CategoryTitleText = true, Text_StageName = true }
local _CHART_REWARD = { Text_RewardCount = true, Text_RewardName = true }
local _CHART_RECAP = { TXT_Outline = true, TXT_Question = true }

local function CollectChartItems(textBlocks)
    -- Three buckets so the ORDER is objective -> rewards (with amounts) -> recap. The
    -- recap is long, so putting it LAST means the objective and the EXP/Zeni numbers are
    -- spoken FIRST and aren't lost at the tail (why amounts seemed "not read").
    local obj, rew, recap, seen = {}, {}, {}, {}
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb) or ""
        local isObj, isRew, isRecap = _CHART_OBJ[wn], _CHART_REWARD[wn], _CHART_RECAP[wn]
        if isObj or isRew or isRecap then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Transient", 1, true)
               and (path:find("ChartDetails", 1, true) or path:find("AI_Reward", 1, true)) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text then
                    text = (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
                    local keep = false
                    if #text > 1 and not text:find("\227", 1, true)
                       and text ~= "text" and text ~= "???" and text ~= "EXP" then
                        if text:match("%a") then
                            keep = true
                        elseif isRew and text:match("^%d+$") and not text:match("^9+$") then
                            keep = true  -- real reward number (not the all-9s placeholder)
                        end
                    end
                    if keep and not seen[text] then
                        seen[text] = true
                        table.insert(isObj and obj or (isRew and rew or recap), text)
                    end
                end
            end
        end
    end
    local out = {}
    for _, v in ipairs(obj) do table.insert(out, v) end
    for _, v in ipairs(rew) do table.insert(out, v) end
    for _, v in ipairs(recap) do table.insert(out, v) end
    return out
end

-- Reads the node-details panel the story map opens on X/Y (WBP_GRP_AI_ChartDetails_C):
-- objective, story outline/summary, and reward details. This panel was never read.
function Trackers.PollChartDetails()
    if not Speak then return end
    local panel = GetCachedFirstOf("WBP_GRP_AI_ChartDetails_C")
    if not panel or not TryCall(panel, "IsVisible") then
        if _chartWasVisible then
            _chartWasVisible = false
            PauseFocus(1.0)  -- cover the teardown when the panel closes
        end
        _lastChartKey, _chartPendingKey, _chartSettle, _lastRewardPreview = nil, nil, 0, nil
        return
    end
    _chartWasVisible = true

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end

    -- Reward amounts load LATE (well after the labels), in the reward SLOTS, and never
    -- coincide with the main read above — so announce them SEPARATELY the moment the
    -- numbers turn real, each paired with its item. Group each slot's Text_RewardCount
    -- (label, e.g. "EXP de jugador") with its Text_RewardName (amount, e.g. "1000").
    local slots = {}
    for _, tb in ipairs(textBlocks) do
        local wn = GetWidgetName(tb) or ""
        if wn == "Text_RewardCount" or wn == "Text_RewardName" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Transient", 1, true) and path:find("AI_Reward", 1, true) then
                -- Use the NUMBERED slot (Reward_1/Reward_2), NOT the "Reward_Set"
                -- container — matching Set grouped both amounts into one and clobbered them.
                local slot = path:match("(WBP_OBJ_AI_Reward_%d+)")
                if slot then
                    local ok2, t = pcall(function() return tb:GetText():ToString() end)
                    if ok2 and t and t ~= "" then
                        slots[slot] = slots[slot] or {}
                        if wn == "Text_RewardCount" then slots[slot].label = t
                        else slots[slot].num = t end
                    end
                end
            end
        end
    end
    local previews = {}
    for _, s in pairs(slots) do
        if s.num and s.num:match("^%d+$") and not s.num:match("^9+$") then
            local lbl = (s.label and s.label ~= "EXP") and (s.label .. " ") or ""
            previews[#previews + 1] = lbl .. s.num
        end
    end
    if #previews > 0 then
        table.sort(previews)
        local pk = table.concat(previews, "|")
        if pk ~= _lastRewardPreview then
            _lastRewardPreview = pk
            Speak("Recompensa", true)
            for _, p in ipairs(previews) do SpeakQueued(p) end
            print("[AE] Reward preview: " .. table.concat(previews, ", "))
        end
    end
    local items = CollectChartItems(textBlocks)

    if #items == 0 then
        -- Panel present but empty (closing / between nodes): clear the dedup so the same
        -- node reopened is announced again on demand.
        _lastChartKey, _chartPendingKey, _chartSettle, _chartWaitNum = nil, nil, 0, 0
        return
    end

    local key = table.concat(items, "|")
    if key == _lastChartKey then return end  -- already announced this exact content

    -- SETTLE: the panel populates its fields over a few frames. Reading on the first
    -- tick gave a PARTIAL result (just "EXP" + description on the X press). Wait until
    -- the content stops changing (stable for 3 ticks) before announcing the full panel.
    if key ~= _chartPendingKey then
        _chartPendingKey = key
        _chartSettle = 3
        return
    end
    if _chartSettle > 0 then
        _chartSettle = _chartSettle - 1
        return
    end

    _lastChartKey = key
    _chartPendingKey = nil
    Trackers.lastChartItems = items  -- for the F7 repeat hotkey
    Speak(items[1], true)
    for i = 2, #items do SpeakQueued(items[i]) end
    print("[AE] Chart details: " .. table.concat(items, ", "))
end

-- === MAIN-MENU SYSTEM MESSAGE TRACKING ===

local _lastSysMsg = nil
local _sysMsgDiagKey = nil  -- DIAG: dedup for the Text_ToNext contents log

-- FRENO ANTI-CRASH (07-26): VENTANA DE ARRANQUE para PollSystemMessage.
-- El crash fatal del 07-26 en la Enciclopedia quedó con la migaja `P:sysmsg` — y las migajas YA son
-- fiables (fix del 07-22, LECCIÓN 17), así que esta vez SÍ señala a este lector. Este poller hace el
-- escaneo MÁS PESADO del mod (FindAllOf de TODOS los TextBlock + GetFullName por cada Text_ToNext) y
-- su única puerta es la PRESENCIA de `WBP_Title_C`, que NUNCA verificamos que desaparezca tras el
-- arranque: tiene toda la pinta de PANEL FANTASMA (LECCIÓN 13), y entonces el escaneo estaba
-- corriendo en TODA pantalla, Enciclopedia y batalla incluidas.
-- Lo único que este lector aporta es el mensaje de arranque (bono de inicio de sesión). En la sesión
-- del 07-26 no leyó NADA útil: el bono lo anunció PollMessageNotification ("Message notification:
-- Bonificación de inicio de sesión enviada", 35s tras cargar el mod). Así que limitarlo al arranque
-- no quita ninguna función real.
-- La ventana se sella AL CARGAR el módulo y es FAIL-SAFE (LECCIÓN 11): expira sola, no es un flag de
-- estado que se pueda quedar pegado. 180s da margen de sobra sobre los 35s medidos.
local _sysMsgWindowEnd = os.clock() + 180
local _sysMsgGateDiagDone = false

-- Reads main-menu system messages (e.g. the startup "Bonificación de inicio de sesión
-- enviada" login bonus) shown in WBP_MainMenu_Base_TextSub_C's Text_ToNext field — a
-- different widget from battle rewards and character chatter, so it was never read.
function Trackers.PollSystemMessage()
    if not Speak then return end
    -- VENTANA DE ARRANQUE (07-26, ver arriba): pasados los primeros 180s este lector NO vuelve a
    -- escanear nunca. Con esto el escaneo pesado deja de correr en la Enciclopedia y en batalla.
    if os.clock() > _sysMsgWindowEnd then
        -- DIAG de UNA SOLA VEZ en toda la sesión: ¿la puerta seguía abierta al cerrarse la ventana?
        -- Si dice presente=true, `WBP_Title_C` ES un panel fantasma y por fin lo sabremos (dato que
        -- llevamos meses sin confirmar). Una sola llamada, en un tick ya pasado el gate de churn.
        if not _sysMsgGateDiagDone then
            _sysMsgGateDiagDone = true
            local t = GetCachedFirstOf("WBP_Title_C")
            print("[AE-DIAG] sysmsg ventana cerrada; WBP_Title_C presente=" .. tostring(t ~= nil))
        end
        _lastSysMsg = nil
        return
    end
    -- GATE on the TITLE / login screen (WBP_Title_C): the login bonus shows there (with the
    -- gamertag), and that widget is absent in gameplay — so this reader runs only at startup and
    -- never does its FindAllOf scan mid-cutscene (which crashed, crumb P:sysmsg). The bonus text
    -- ("Bonificación de inicio de sesión enviada") lives in Text_ToNext of WBP_OBJ_Common_TexWin_Black
    -- (F5 confirmed — NOT WBP_MainMenu_Base_TextSub_C as first assumed, which is why it never read).
    -- Extra safety: also bail in any battle/story-map context.
    local title = GetCachedFirstOf("WBP_Title_C")
    if not title or not IsValidRef(title) then _lastSysMsg = nil; return end
    local Battle = package.loaded["battle"]
    if Battle and Battle.WasBattleActive and Battle.WasBattleActive() then _lastSysMsg = nil; return end
    local EB = package.loaded["episode_battle"]
    if EB and EB.IsStoryMapActive and EB.IsStoryMapActive() then _lastSysMsg = nil; return end
    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then return end
    local diag = {}  -- DIAG: every Text_ToNext value seen while the title gate is open + container
    local announce = nil
    for _, tb in ipairs(textBlocks) do
        if GetWidgetName(tb) == "Text_ToNext" then
            local ok, path = pcall(function() return tb:GetFullName() end)
            if ok and path and path:find("Transient", 1, true) then
                local ok2, text = pcall(function() return tb:GetText():ToString() end)
                if ok2 and text and text ~= "" then
                    local cont = path:match("(WBP_[%w]+)") or "?"
                    diag[cont .. "=" .. text] = true
                    -- Real multi-word Latin message (skip Japanese \227 and single words like "Goku")
                    if not announce and text:match("%a") and text:find(" ", 1, true)
                       and not text:find("\227", 1, true) then
                        announce = text
                    end
                end
            end
        end
    end
    -- DIAG (temporary): log what Text_ToNext holds at the title/login screen, once per change.
    local keys = {}
    for k in pairs(diag) do keys[#keys + 1] = k end
    table.sort(keys)
    local dk = table.concat(keys, " | ")
    if dk ~= "" and dk ~= _sysMsgDiagKey then
        _sysMsgDiagKey = dk
        print("[AE-DIAG] sysmsg ToNext: " .. dk)
    end
    if announce then
        if announce ~= _lastSysMsg then
            _lastSysMsg = announce
            Speak(announce, true)
            print("[AE] System message: " .. announce)
        end
        return
    end
    _lastSysMsg = nil  -- gone: reset so the same message re-announces if it reappears
end

-- === HELP WINDOW TRACKING ===

local lastHelpWindowState = {}

function Trackers.PollHelpWindows()
    if os.clock() < Trackers.transitionCooldownUntil then return end
    local helpWindows = FindAllOf("WBP_GRP_DB_HelpWindow_C")
    if not helpWindows then return end

    for i, hw in ipairs(helpWindows) do
        local visible = TryCall(hw, "IsVisible")
        local key = "help_" .. i

        if not visible then
            if lastHelpWindowState[key] then
                lastHelpWindowState[key].visible = false
            end
        else
            local bodyText = nil
            local richBlocks = FindAllOf("RichTextBlock")
            if richBlocks then
                local hwId = hw:GetFullName():match("(WBP_GRP_DB_HelpWindow_C_%d+)")
                if hwId then
                    for _, rb in ipairs(richBlocks) do
                        if GetWidgetName(rb) == "TXT_main" then
                            local rbPath = rb:GetFullName()
                            if rbPath:find(hwId, 1, true) then
                                local ok, text = pcall(function() return rb:GetText():ToString() end)
                                if ok and text and text ~= "" then
                                    bodyText = text
                                    break
                                end
                            end
                        end
                    end
                end
            end

            local pageInfo = nil
            local textBlocks = FindAllOf("TextBlock")
            if textBlocks then
                local hwId = hw:GetFullName():match("(WBP_GRP_DB_HelpWindow_C_%d+)")
                if hwId then
                    local page0, page1 = nil, nil
                    for _, tb in ipairs(textBlocks) do
                        local tbPath = tb:GetFullName()
                        if tbPath:find(hwId, 1, true) then
                            local tbName = GetWidgetName(tb)
                            if tbName == "TXT_Page_0" then
                                local ok, t = pcall(function() return tb:GetText():ToString() end)
                                if ok then page0 = t end
                            elseif tbName == "TXT_Page_1" then
                                local ok, t = pcall(function() return tb:GetText():ToString() end)
                                if ok then page1 = t end
                            end
                        end
                    end
                    if page0 and page1 then
                        pageInfo = "Page " .. page0 .. " of " .. page1
                    end
                end
            end

            local prev = lastHelpWindowState[key]
            local isNew = not prev or not prev.visible
            local textChanged = prev and prev.text ~= bodyText

            if (isNew or textChanged) and bodyText then
                local cleaned = bodyText:gsub("\n", " "):gsub("%s+", " ")
                if pageInfo then
                    SpeakQueued(pageInfo)
                    SpeakQueued(cleaned)
                else
                    SpeakQueued(cleaned)
                end
                SpeakQueued("Press Back to close")
                print("[AE] Help: " .. (pageInfo or "") .. " " .. cleaned)
            end

            lastHelpWindowState[key] = {visible = true, text = bodyText}
        end
    end
end

-- === SCREEN TRACKING ===

local lastScreenState = {}
local _screenInvisibleStreak = {}  -- ticks consecutivos invisible por pantalla (debounce anti-parpadeo)
-- Una vez visto el menú principal, el juego YA arrancó y las pantallas SOLO-ARRANQUE (Title/Loading)
-- no reaparecen. Trackers.startupSeen (declarado arriba, público) se activa para dejar de hacer IsVisible
-- sobre sus refs cacheadas (ver PollScreenChanges) y para gatear los lectores pre-guardia en el arranque.

function Trackers.PollScreenChanges()
    if os.clock() < Trackers.transitionCooldownUntil then return end

    -- Skip during a story/battle cutscene (skip prompt up): the title/loading widgets checked
    -- below are being torn down as the scene loads, and IsVisible on one mid-teardown crashes
    -- the game natively (crumb P:screen, seen as the training-partner decision appeared). None
    -- of these startup screens matter mid-cutscene. The real title/startup loading has NO skip
    -- prompt, so the legit "Loading" announcement there is unaffected.
    local skip = GetCachedFirstOf("WBP_GRP_AI_EventSkip_C")
    if skip and TryCall(skip, "IsVisible") then return end

    -- Tras ver el menú principal, el juego YA arrancó (07-21). CAUSA del crash P:screen al navegar la
    -- ENCICLOPEDIA: WBP_Title_C y WBP_GRP_Title_CI_Logo_C (pantallas SOLO-ARRANQUE) PERSISTEN en memoria
    -- (verificado en el volcado: 49 y 8 apariciones durante la galería, aunque INVISIBLES), y su
    -- IsVisible sobre la ref cacheada del arranque TRUENA en teardown. Una vez arrancado no reaparecen
    -- (volver al título recargaría el mod y resetearía _startupSeen), así que se dejan de chequear.
    -- Options SÍ se sigue chequeando (Ajustes reaparece). Fail-safe: si nunca se ve el menú, comportamiento viejo.
    if Trackers.onMainMenu then Trackers.startupSeen = true end

    local screens = {
        {"WBP_Option_C", "Options Menu"},
        {"WBP_GRP_Title_CI_Logo_C", "Loading"},
        {"WBP_Title_C", "Press confirm to start", 1000},
    }

    for _, screen in ipairs(screens) do
        local typeName, label = screen[1], screen[2]
        -- Saltar Title/Loading tras el arranque (persisten en memoria y su IsVisible truena; ver arriba).
        local skipStartupScreen = Trackers.startupSeen
            and (typeName == "WBP_Title_C" or typeName == "WBP_GRP_Title_CI_Logo_C")
        if not skipStartupScreen then
            local w = GetCachedFirstOf(typeName)
            local isVisible = false

            -- Re-validate immediately before IsVisible: these are title/loading screens
            -- that get torn down entering the menu, and IsVisible on one mid-teardown
            -- crashes the game natively (crumb P:screen). Cuts the race window to adjacent
            -- statements.
            if w and IsValidRef(w) and TryCall(w, "IsVisible") then
                isVisible = true
            end

            if isVisible then
                if not lastScreenState[typeName] then
                    -- Flanco de subida REAL (primera entrada / re-entrada tras salir de verdad): anunciar.
                    if screen[3] then
                        ExecuteWithDelay(screen[3], function()
                            Speak(label, true)
                            print("[AE] Screen: " .. label .. " (delayed " .. screen[3] .. "ms)")
                        end)
                    else
                        Speak(label, true)
                        print("[AE] Screen: " .. label)
                    end
                end
                lastScreenState[typeName] = true
                _screenInvisibleStreak[typeName] = 0
            else
                -- DEBOUNCE anti-parpadeo (07-22): WBP_Option_C parpadea (invisible ~1 tick) cada ~14s por el
                -- ciclo del DEMO del menú detrás de Ajustes. Sin debounce, cada parpadeo re-anunciaba "Options
                -- Menu" CON INTERRUPCIÓN, pisando la lectura de la opción en TODOS los sub-menús de Ajustes
                -- (Iván: sonido, idioma, otros). Solo marcar "salió" tras 5 ticks (~0.5s del poll de 100ms)
                -- invisible CONSECUTIVOS: un parpadeo corto se ignora; una salida REAL de Ajustes (Option
                -- invisible sostenido) sí resetea y permite re-anunciar al volver. Aplica a las 3 pantallas
                -- (inofensivo para Title/Loading, que además se saltan tras el arranque).
                _screenInvisibleStreak[typeName] = (_screenInvisibleStreak[typeName] or 0) + 1
                if _screenInvisibleStreak[typeName] >= 5 then
                    lastScreenState[typeName] = false
                end
            end
        end
    end
end

-- === PLAYER MATCH ROOM POLLING ===

local lastRoomIdText = nil
local lastPlayerStatus = {}  -- panel suffix -> {status, username}

function Trackers.PollRoom()
    -- Guard: skip expensive TextBlock scan if not on room screen.
    -- GetCachedFirstOf retains the room ref across ticks and throttles
    -- negative-result GUObjectArray walks to one per 500ms.
    local roomWindow = GetCachedFirstOf("WBP_MenuOLB_PLMatch_Room_LWindow_C")
    if not roomWindow or not TryCall(roomWindow, "IsVisible") then
        if lastRoomIdText then
            lastRoomIdText = nil
            lastPlayerStatus = {}
        end
        return
    end

    local textBlocks = FindAllOf("TextBlock")
    if not textBlocks then
        lastRoomIdText = nil
        lastPlayerStatus = {}
        return
    end

    -- Collect all room-related TextBlocks in one pass
    local roomId = nil
    local panels = {}  -- suffix -> {field -> value}
    local onRoomScreen = false

    for _, tb in ipairs(textBlocks) do
        local ok, tbPath = pcall(function() return tb:GetFullName() end)
        if not ok then goto continue end

        -- Room ID
        if tbPath:find("PLMatch_Room_LWindow", 1, true)
           and tbPath:find("Transient", 1, true)
           and GetWidgetName(tb) == "TXT_ID" then
            onRoomScreen = true
            local ok2, text = pcall(function() return tb:GetText():ToString() end)
            if ok2 and text then roomId = text end
        end

        -- Player panel fields
        local panelSuffix = tbPath:match("PLMatch_PlayerPanel_(%d+)")
        if panelSuffix and tbPath:find("Transient", 1, true) then
            onRoomScreen = true
            if not panels[panelSuffix] then panels[panelSuffix] = {} end
            local tbName = GetWidgetName(tb)
            local ok2, text = pcall(function() return tb:GetText():ToString() end)
            if ok2 and text and text ~= "" then
                panels[panelSuffix][tbName] = text
            end
        end

        ::continue::
    end

    if not onRoomScreen then
        lastRoomIdText = nil
        lastPlayerStatus = {}
        return
    end

    -- Room ID toggle
    if roomId and roomId ~= lastRoomIdText then
        lastRoomIdText = roomId
        if not roomId:find("XXX", 1, true) and not roomId:find("000-000-000", 1, true) then
            Speak("Room ID, " .. roomId, true)
        end
    end

    -- Player status changes
    for suffix, fields in pairs(panels) do
        local status = fields.TXT_Status_00
        if status == "Text Block" then status = nil end
        local username = fields.TXT_Username_Own
        if not username or username == "Username" then
            username = fields.TXT_UserName
        end
        if username == "Username" then username = nil end
        local enter = fields.TXT_Enter

        -- Build a key for tracking: "username|status" or "Available"
        local current
        if username and status then
            current = username .. "|" .. status
        elseif enter == "Available" then
            current = "Available"
        else
            current = nil
        end

        local prev = lastPlayerStatus[suffix]
        if current and current ~= prev then
            lastPlayerStatus[suffix] = current
            -- Don't announce on first detection (initial load)
            if prev ~= nil then
                local slotNum = tonumber(suffix) + 1
                if current == "Available" then
                    SpeakQueued("Slot " .. slotNum .. ", Available")
                elseif username and status then
                    SpeakQueued("Slot " .. slotNum .. ", " .. username .. ", " .. status)
                end
            end
        elseif current == nil and prev ~= nil then
            lastPlayerStatus[suffix] = nil
        end
    end
end

-- === TUTORIAL HUD TRACKING ===
-- The tutorial's control instructions live in WBP_GRP_TTR_HUD_TutorialAll_C,
-- one "tip" per WBP_TTR_Tip_N with a TextBlock named "caption" (e.g. "Moverse",
-- "Saltar (En el suelo)", "Volar (En el aire)"). None of this takes keyboard
-- focus, so it's poll-based. We announce the set of tips whenever it changes.
local _lastTutorialTips = nil

function Trackers.PollTutorial()
    if os.clock() < Trackers.transitionCooldownUntil then return end
    -- Cheap gate: only scan while the tutorial HUD is present (cached singleton).
    local hud = GetCachedFirstOf("WBP_GRP_TTR_HUD_TutorialAll_C")
    if not hud or not TryCall(hud, "IsVisible") then
        if _lastTutorialTips then _lastTutorialTips = nil end
        return
    end

    -- Each instruction is a WBP_TTR_Tip_N with a "caption" TextBlock (what to do)
    -- and a "RichText_PadButton_0" RichTextBlock (the key/button icon). Collect
    -- both, keyed by tip index so we read them in order (Tip_0, Tip_1, ...).
    local tips = {}
    local textBlocks = FindAllOf("TextBlock")
    if textBlocks then
        for _, tb in ipairs(textBlocks) do
            if GetWidgetName(tb) == "caption" then
                local ok, tbPath = pcall(function() return tb:GetFullName() end)
                if ok and tbPath:find("WBP_GRP_TTR_HUD_TutorialAll_C", 1, true)
                   and tbPath:find("Transient", 1, true) then
                    local idx = tbPath:match("WBP_TTR_Tip_(%d+)")
                    if idx then
                        local ok2, text = pcall(function() return tb:GetText():ToString() end)
                        if ok2 and text and text ~= "" then
                            tips[tonumber(idx)] = text:gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
                        end
                    end
                end
            end
        end
    end

    if next(tips) == nil then
        if _lastTutorialTips then _lastTutorialTips = nil end
        return
    end

    -- Key/button icon per tip. Raw icon markup — the speech layer runs it through
    -- IconParser, so "text=W" reads as "W", Key_16 as "Space", and controller
    -- glyphs as their Xbox/PS labels, matching whatever device is in use.
    local icons = {}
    local richBlocks = FindAllOf("RichTextBlock")
    if richBlocks then
        for _, rb in ipairs(richBlocks) do
            if GetWidgetName(rb) == "RichText_PadButton_0" then
                local ok, rbPath = pcall(function() return rb:GetFullName() end)
                if ok and rbPath:find("WBP_GRP_TTR_HUD_TutorialAll_C", 1, true)
                   and rbPath:find("Transient", 1, true) then
                    local idx = rbPath:match("WBP_TTR_Tip_(%d+)")
                    if idx then
                        local ok2, raw = pcall(function() return rb:GetText():ToString() end)
                        if ok2 and raw and raw:match("%S") then
                            icons[tonumber(idx)] = raw
                        end
                    end
                end
            end
        end
    end

    -- Build the ordered announcement: "what to do, key" per instruction.
    local parts = {}
    for i = 0, 15 do
        if tips[i] and tips[i] ~= "" then
            local piece = tips[i]
            if icons[i] then piece = piece .. ", " .. icons[i] end
            table.insert(parts, piece)
        end
    end
    if #parts == 0 then
        if _lastTutorialTips then _lastTutorialTips = nil end
        return
    end

    local announcement = table.concat(parts, ". ")
    if announcement ~= _lastTutorialTips then
        _lastTutorialTips = announcement
        SpeakQueued(announcement)
        print("[AE] Tutorial tips: " .. announcement)
    end
end

return Trackers
