--[[
    helpers.lua — Shared utility functions for SparkingZeroAccess
    Safe wrappers for UE4SS object access.

    IsValidRef() is for UObject references ONLY (widgets, actors, etc.).
    TryCall/TryGetProperty work on any object type (UObject, FText, FString, etc.)
    and use pcall as their safety net — no IsValid pre-check.
]]

local Helpers = {}

--- Check if a UObject reference is still alive.
--- ONLY use on known UObject types (widgets, actors, components).
--- Do NOT use on FText, FString, or other non-UObject types.
function Helpers.IsValidRef(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    if ok then return valid end
    -- Fallback: try GetFullName as a proxy
    ok = pcall(function() return obj:GetFullName() end)
    return ok
end

function Helpers.TryCall(obj, methodName, ...)
    local success, value = pcall(function(...)
        return obj[methodName](obj, ...)
    end, ...)
    if success then return value end
    return nil
end

function Helpers.TryGetProperty(obj, propName)
    local success, value = pcall(function()
        return obj[propName]
    end)
    if success then return value end
    return nil
end

function Helpers.GetWidgetName(obj)
    -- IsValidRef FIRST: GetFullName() on a UObject mid-teardown can HANG natively
    -- (pcall does NOT catch a hang), which wedges the whole single-threaded mod.
    -- GetWidgetName is the typical first per-widget access inside FindAllOf loops,
    -- so guarding here protects most of those loops at once. A dead object reads as
    -- "(invalid)", which callers skip by name mismatch — same as the old pcall-fail.
    if not Helpers.IsValidRef(obj) then return "(invalid)" end
    local ok, fullName = pcall(function() return obj:GetFullName() end)
    if not ok then return "(invalid)" end
    return fullName:match("%.([^%.]+)$") or fullName
end

function Helpers.GetClassName(obj)
    if not Helpers.IsValidRef(obj) then return "(invalid)" end
    local ok, fullName = pcall(function() return obj:GetFullName() end)
    if not ok then return "(invalid)" end
    return fullName:match("^(.-)%s") or fullName
end

-- Cached singleton lookup. With bUseUObjectArrayCache=false every FindFirstOf
-- is a full GUObjectArray walk, so callers that hit the same singleton every
-- tick (PollScreenChanges, PollRoom, etc.) should route through here.
-- Positive results are revalidated with IsValidRef; negative results are
-- throttled to a 500ms retry window.
local _firstOfCache = {}      -- typeName -> live UObject ref
local _firstOfMissUntil = {}  -- typeName -> os.clock() until next retry allowed

function Helpers.GetCachedFirstOf(typeName)
    local cached = _firstOfCache[typeName]
    if cached and Helpers.IsValidRef(cached) then
        return cached
    end
    _firstOfCache[typeName] = nil

    local missUntil = _firstOfMissUntil[typeName]
    if missUntil and os.clock() < missUntil then
        return nil
    end

    local ok, fresh = pcall(FindFirstOf, typeName)
    if ok and fresh and Helpers.IsValidRef(fresh) then
        _firstOfCache[typeName] = fresh
        _firstOfMissUntil[typeName] = nil
        return fresh
    end
    -- REINTENTO DE LOS FALLOS: 0.5s -> 1.5s (07-28). MEDIDO, no estimado.
    -- Con `bUseUObjectArrayCache = false` en la configuración de UE4SS, un `FindFirstOf` que NO
    -- encuentra nada recorre la lista COMPLETA de objetos del juego, y eso cuesta del orden de 0.33s.
    -- La tanda de pause-checks de PollFocus consulta CINCO clases que, fuera de una batalla, no existen
    -- ninguna: cinco recorridos completos seguidos. En el registro del torneo eso se midió en
    -- **164 atascos con una media de 1.43s** (máximo 3.08s) y NUEVE muertes del bucle en una sesión.
    -- Una de esas muertes cayó justo en el segundo en que el presentador anunciaba la final, y por eso
    -- esa línea no se leyó mientras que la de semifinales sí (allí el bucle murió un segundo DESPUÉS).
    -- Reintentar un fallo cada medio segundo es carísimo cuando el fallo cuesta un tercio de segundo.
    -- Con 1.5s el gasto de los gates que no encuentran nada baja a la tercera parte.
    -- LO QUE CUESTA: una pantalla que aparece puede tardar hasta 1.5s en detectarse. Donde más
    -- importaría —el menú de pausa en batalla— NO afecta, porque ahí esos widgets SÍ existen y quedan
    -- cacheados, así que se detectan al instante; el gasto grande es justo cuando no hay nada que hallar.
    -- ARREGLO DE FONDO PENDIENTE: activar `bUseUObjectArrayCache` haría instantáneas estas búsquedas.
    _firstOfMissUntil[typeName] = os.clock() + 1.5
    return nil
end

function Helpers.InvalidateCachedFirstOf(typeName)
    if typeName then
        _firstOfCache[typeName] = nil
        _firstOfMissUntil[typeName] = nil
    else
        _firstOfCache = {}
        _firstOfMissUntil = {}
    end
end

return Helpers
