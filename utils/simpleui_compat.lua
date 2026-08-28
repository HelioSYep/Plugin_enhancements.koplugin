-- SimpleUI 2.1.1 / 2.5.0 / 2.6.x compatibility resolver.
--
-- SimpleUI 2.5.0 moved the implementation into modules/, infra/, screens/,
-- engines/ and features/. 2.6.0 split a few more responsibilities (notably
-- wallpaper and Quick Action rendering) into their own feature/engine files.
-- Keep every version-dependent path in this file so modules and patches can
-- target capabilities instead of hard-coding a SimpleUI release layout.

local M = {}

-- SimpleUI 2.5 exposes user-configurable colours through
-- SUIStyle.getThemeColor(role). SimpleUI 2.6 removed that API. Return nil on
-- 2.6 so each extension keeps the exact legacy fallback colours it used
-- before the compatibility update, while still avoiding a call to the missing
-- function. Do not map to 2.6's SUIStyle.COLOR here: those semantic tokens use
-- visibly different gray levels and would alter the extensions' established
-- appearance.
function M.getThemeColor(style, role)
    if type(style) ~= "table" or type(role) ~= "string" then return nil end

    if type(style.getThemeColor) == "function" then
        local ok, color = pcall(style.getThemeColor, role)
        if ok and color ~= nil then return color end
    end
    return nil
end

local PATHS = {
    registry       = { "modules/moduleregistry", "desktop_modules/moduleregistry" },
    config         = { "infra/sui_config", "sui_config" },
    store          = { "infra/sui_store", "sui_store" },
    core           = { "infra/sui_core", "sui_core" },
    homescreen     = { "screens/sui_homescreen", "sui_homescreen" },
    screen_engine  = { "engines/sui_screen_engine", "screens/sui_homescreen", "sui_homescreen" },
    custom_screens = { "infra/sui_custom_screens" },
    books_shared   = { "modules/module_books_shared", "desktop_modules/module_books_shared" },
    stats_provider = { "modules/module_stats_provider", "desktop_modules/module_stats_provider" },
    coverdeck      = { "modules/module_coverdeck", "desktop_modules/module_coverdeck" },
    tbr            = { "modules/module_tbr", "desktop_modules/module_tbr" },
    clock          = { "modules/module_clock", "desktop_modules/module_clock" },
    recent         = { "modules/module_recent", "desktop_modules/module_recent" },
    book_rows      = { "modules/module_book_rows", "desktop_modules/module_book_rows" },
    quicksettings  = { "screens/sui_quicksettings_bar", "sui_quicksettings_bar" },
    quickactions   = { "features/sui_quickactions", "sui_quickactions" },
    quickactions_renderer = { "engines/sui_quickactions_render" },
    style          = { "features/sui_style", "sui_style" },
    wallpaper      = { "features/sui_wallpaper", "sui_homescreen" },
    book_grid      = { "engines/sui_book_grid", "desktop_modules/sui_book_row" },
    streak         = { "infra/sui_streak", "sui_streak" },
    window         = { "engines/sui_window", "sui_window" },
}

local function candidates(key)
    return PATHS[key] or { key }
end

function M.tryRequire(key)
    local errors = {}
    for _, path in ipairs(candidates(key)) do
        local loaded = package.loaded[path]
        if loaded ~= nil and loaded ~= false then
            return true, loaded, path
        end
        local ok, mod = pcall(require, path)
        if ok and mod ~= nil then
            return true, mod, path
        end
        errors[#errors + 1] = path .. ": " .. tostring(mod)
    end
    return false, table.concat(errors, " | "), nil
end

function M.require(key)
    local ok, mod_or_err = M.tryRequire(key)
    if ok then return mod_or_err end
    error("SimpleUI component unavailable (" .. tostring(key) .. "): "
          .. tostring(mod_or_err), 2)
end

function M.loaded(key)
    for _, path in ipairs(candidates(key)) do
        local mod = package.loaded[path]
        if mod ~= nil and mod ~= false then return mod, path end
    end
    return nil
end

function M.getLayoutFamily()
    if package.loaded["infra/sui_config"]
        or package.loaded["modules/moduleregistry"]
        or package.loaded["screens/sui_homescreen"] then
        return "2.5"
    end
    if package.loaded["sui_config"]
        or package.loaded["desktop_modules/moduleregistry"]
        or package.loaded["sui_homescreen"] then
        return "2.1"
    end
    local ok, _, path = M.tryRequire("config")
    if not ok then return nil end
    return path == "infra/sui_config" and "2.5" or "2.1"
end

-- Read SimpleUI's own _meta.lua without using require("_meta"), which is a
-- process-global module name shared by every KOReader plugin. The registry's
-- source path gives us the correct plugin root for every supported layout.
function M.getVersion()
    local ok, Registry = M.tryRequire("registry")
    if ok and Registry then
        local probe = Registry.register or Registry.list or Registry.get
        if type(probe) == "function" then
            local info = debug.getinfo(probe, "S")
            local source = info and info.source or ""
            source = source:sub(1, 1) == "@" and source:sub(2) or source
            source = source:gsub("\\", "/")
            local root = source:match("^(.*)/modules/moduleregistry%.lua$")
                or source:match("^(.*)/desktop_modules/moduleregistry%.lua$")
            if root then
                local ok_meta, meta = pcall(dofile, root .. "/_meta.lua")
                if ok_meta and type(meta) == "table"
                        and type(meta.version) == "string" then
                    return meta.version
                end
            end
        end
    end
    local family = M.getLayoutFamily()
    return family and (family == "2.5" and "2.5+" or "2.1.x") or nil
end

-- Refresh every live SimpleUI surface on 2.5+/2.6 (built-in Home plus Custom
-- Screens), while retaining the single-Homescreen fallback used by 2.1.1.
function M.refreshAllLiveImmediate(keep_cache)
    local ok, ScreenEngine = M.tryRequire("screen_engine")
    if not ok or not ScreenEngine then return false, ScreenEngine end
    if type(ScreenEngine.refreshAllLiveImmediate) == "function" then
        return pcall(ScreenEngine.refreshAllLiveImmediate, keep_cache)
    end
    if type(ScreenEngine.refreshImmediate) == "function" then
        return pcall(ScreenEngine.refreshImmediate, keep_cache)
    end
    local instance = ScreenEngine._instance
    if instance and type(instance._refreshImmediate) == "function" then
        return pcall(instance._refreshImmediate, instance, keep_cache)
    end
    return false, "SimpleUI refresh API unavailable"
end

-- Layout rebuild counterpart to refreshAllLiveImmediate().
function M.rebuildAllLayouts()
    local ok, ScreenEngine = M.tryRequire("screen_engine")
    if not ok or not ScreenEngine then return false, ScreenEngine end
    if type(ScreenEngine.rebuildAllLayouts) == "function" then
        return pcall(ScreenEngine.rebuildAllLayouts)
    end
    if type(ScreenEngine.rebuildLayout) == "function" then
        return pcall(ScreenEngine.rebuildLayout)
    end
    return false, "SimpleUI layout rebuild API unavailable"
end

-- Resolve the structured-layout settings key belonging to a module-settings
-- prefix. In 2.1.1 only the built-in Home Screen exists. In 2.5.0 every
-- Custom Screen has an independent prefix and layout key.
function M.getLayoutKeyForPrefix(pfx)
    if pfx and pfx ~= "" and pfx ~= "simpleui_hs_" then
        local ok, CustomScreens = M.tryRequire("custom_screens")
        if ok and CustomScreens and type(CustomScreens.list) == "function" then
            local ok_list, screens = pcall(CustomScreens.list)
            if ok_list then
                for _, screen in ipairs(screens or {}) do
                    if screen.pfx == pfx and screen.layout_key then
                        return screen.layout_key
                    end
                end
            end
        end
    end
    return "simpleui_layout"
end

-- Return every known homescreen-like surface. This is useful for cache
-- invalidation and layout-aware patches while remaining harmless on 2.1.1.
function M.listScreens()
    local screens = {
        { id = "hs", pfx = "simpleui_hs_", layout_key = "simpleui_layout" },
    }
    local ok, CustomScreens = M.tryRequire("custom_screens")
    if ok and CustomScreens and type(CustomScreens.list) == "function" then
        local ok_list, custom = pcall(CustomScreens.list)
        if ok_list then
            for _, screen in ipairs(custom or {}) do
                screens[#screens + 1] = screen
            end
        end
    end
    return screens
end

return M
