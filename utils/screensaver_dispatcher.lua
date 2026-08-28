-- Shared Screensaver hook dispatcher for Plugin_enhancements.
--
-- Multiple optional screensaver patches may be enabled at the same time.
-- They register their own screensaver type and menu injector here, while this
-- module owns the single Screensaver.show / require / dofile hook chain.

local logger = require("logger")

local M = {}

local handlers = {}
local handler_order = {}
local screensaver_table
local dispatch_show
local require_wrapper
local original_require
local dofile_wrapper
local original_dofile

local function _isCallable(value)
    if type(value) == "function" then return true end
    local mt = type(value) == "table" and getmetatable(value)
    return mt ~= nil and type(mt.__call) == "function"
end

local function _installShowDispatcher(Screensaver)
    if type(Screensaver) ~= "table" or not _isCallable(Screensaver.show) then
        return false
    end

    if Screensaver == screensaver_table and Screensaver.show == dispatch_show then
        return true
    end

    -- Preserve every wrapper installed before us. If another patch replaces
    -- show later, the setup guard below re-wraps that implementation instead
    -- of restoring a stale function and discarding the other patch.
    local layer_fallback = Screensaver.show
    screensaver_table = Screensaver

    local function call_layer_fallback(self)
        return layer_fallback(self)
    end

    local layer_dispatch
    layer_dispatch = function(self)
        local entry = handlers[self and self.screensaver_type]
        if not entry then
            return call_layer_fallback(self)
        end

        local ok, result = pcall(entry.show, self, call_layer_fallback)
        if ok then return result end

        logger.err("plugin_enhancements: screensaver handler '"
            .. tostring(entry.id) .. "' failed: " .. tostring(result))
        return call_layer_fallback(self)
    end
    dispatch_show = layer_dispatch
    Screensaver.show = dispatch_show

    if not Screensaver._plugin_enhancements_dispatcher_setup_patched
            and type(Screensaver.setup) == "function" then
        Screensaver._plugin_enhancements_dispatcher_setup_patched = true
        local original_setup = Screensaver.setup
        Screensaver.setup = function(self, ...)
            if Screensaver.show ~= dispatch_show then
                _installShowDispatcher(Screensaver)
            end
            return original_setup(self, ...)
        end
    end

    return true
end

local function _restoreRequireWrapper()
    if require_wrapper and _G.require == require_wrapper then
        _G.require = original_require
    end
    require_wrapper = nil
    original_require = nil
end

local function _ensureShowDispatcher()
    local cached = package.loaded["ui/screensaver"]
    if type(cached) == "table" and _installShowDispatcher(cached) then
        _restoreRequireWrapper()
        return true
    end

    if not require_wrapper then
        original_require = _G.require
        require_wrapper = function(modname, ...)
            local result = original_require(modname, ...)
            if modname == "ui/screensaver" and type(result) == "table"
                    and _installShowDispatcher(result) then
                _restoreRequireWrapper()
            end
            return result
        end
        _G.require = require_wrapper
    end
    return false
end

local function _installDofileDispatcher()
    if dofile_wrapper then return end
    original_dofile = _G.dofile
    dofile_wrapper = function(path, ...)
        local result = original_dofile(path, ...)
        if type(path) == "string" and path:find("screensaver_menu%.lua$") then
            for _, id in ipairs(handler_order) do
                local entry = handlers[id]
                if entry and type(entry.inject_menu) == "function" then
                    local ok, err = pcall(entry.inject_menu, result)
                    if not ok then
                        logger.warn("plugin_enhancements: screensaver menu injector '"
                            .. tostring(id) .. "' failed: " .. tostring(err))
                    end
                end
            end
            _ensureShowDispatcher()
        end
        return result
    end
    _G.dofile = dofile_wrapper
end

function M.register(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string"
            or type(spec.screensaver_type) ~= "string"
            or type(spec.show) ~= "function" then
        return false, "invalid screensaver handler"
    end

    if handlers[spec.screensaver_type]
            and handlers[spec.screensaver_type].id ~= spec.id then
        return false, "screensaver type already registered: " .. spec.screensaver_type
    end

    if not handlers[spec.screensaver_type] then
        handler_order[#handler_order + 1] = spec.screensaver_type
    end
    handlers[spec.screensaver_type] = spec

    _installDofileDispatcher()
    _ensureShowDispatcher()
    return true
end

return M
