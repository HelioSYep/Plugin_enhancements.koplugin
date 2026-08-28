local logger = require("logger")
local _ = require("plugin_enhancements_i18n").translate
local SimpleUICompat = require("utils/simpleui_compat")

local patch = {
    id = "module_copies",
    name = "模块副本功能",
    description = _("Adds 'Number of Copies' to singleton SimpleUI modules. Native dynamic rows keep using SimpleUI's independent-instance system."),
    default_enabled = false  -- Opt-in: patches default to disabled
}

function patch.apply()
    local ok_reg, Registry = SimpleUICompat.tryRequire("registry")
    if not ok_reg or not Registry then
        logger.warn("simpleui_ext: patch_module_copies: moduleregistry not available")
        return
    end

    local ok_sui, SUISettings = SimpleUICompat.tryRequire("store")
    if not ok_sui or not SUISettings then
        logger.warn("simpleui_ext: patch_module_copies: sui_store not available")
        return
    end

    logger.info("simpleui_ext: patch_module_copies: applying module copies patch")

    local original_get = Registry.get
    local wrapped_cache = {}

    -- SimpleUI 2.5+ materialises instanciable bases (Quick Actions Row,
    -- Spacer, Featured Collection, and future rows) as ids in the form
    -- "<base_id>_<instance_suffix>". Copying one of those descriptors again
    -- would create "<instance_id>#2", which shares the original settings and
    -- is invisible to Registry's orphan-instance tracker. If the original is
    -- removed while #2 remains, SimpleUI prunes the real instance on restart
    -- and the synthetic copy disappears. Discover the base through the public
    -- Registry.getBase API instead of hard-coding today's three module ids.
    local native_instance_cache = {}
    local function _isNativeInstanceId(id)
        if type(id) ~= "string" or type(Registry.getBase) ~= "function" then
            return false
        end
        if native_instance_cache[id] ~= nil then
            return native_instance_cache[id]
        end

        local from = 1
        while true do
            local separator = id:find("_", from, true)
            if not separator then break end
            local candidate = id:sub(1, separator - 1)
            local ok_base, base = pcall(Registry.getBase, candidate)
            if ok_base and type(base) == "table" and base.instanciable == true then
                native_instance_cache[id] = true
                return true
            end
            from = separator + 1
        end

        native_instance_cache[id] = false
        return false
    end

    Registry.get = function(id)
        if type(id) ~= "string" then
            return original_get(id)
        end
        if wrapped_cache[id] then
            return wrapped_cache[id]
        end

        local copy_index = id:match("#(%d+)$")
        if not copy_index then
            return original_get(id)
        end

        local base_id = id:match("^(.+)#%d+$")
        local mod = original_get(base_id)

        -- Reject legacy synthetic copies of native instances. Leaving them
        -- resolvable would recreate the orphan-pruning failure fixed above.
        if mod and _isNativeInstanceId(base_id) then
            return nil
        end

        if mod then
            local wrapped_mod = {}
            for k, v in pairs(mod) do
                wrapped_mod[k] = v
            end
            -- Use the copy ID (e.g. "clock#2") so buildModulePicker's
            -- active_set lookup matches the raw ID stored in layout pages.
            wrapped_mod.id           = id
            wrapped_mod._original_id = mod.id
            wrapped_mod._original_name = mod.name
            wrapped_mod._copy_index  = copy_index
            wrapped_mod.name = mod.name .. string.format(_(" (Copy %d)"), copy_index)

            -- LayoutService.save() iterates Registry.list() and calls
            -- setEnabled(pfx, false) for every module not in the layout.
            -- For copies, this would accidentally disable the base module's
            -- settings. Clear setEnabled and enabled_key so LayoutService
            -- skips the copy entirely. Preserve isEnabled so the copy still
            -- mirrors the base module's enabled state.
            if type(wrapped_mod.isEnabled) ~= "function" and wrapped_mod.enabled_key then
                local ek         = mod.enabled_key
                local default_on = mod.default_on
                wrapped_mod.isEnabled = function(pfx)
                    local v = SUISettings:readSetting(pfx .. ek)
                    if v == nil then return default_on ~= false end
                    return v == true
                end
            end
            wrapped_mod.setEnabled  = nil
            wrapped_mod.enabled_key = nil

            wrapped_cache[id]        = wrapped_mod
            return wrapped_mod
        end

        return mod
    end

    local UIManager = require("ui/uimanager")
    local SpinWidget = require("ui/widget/spinwidget")

    -- Returns true when order_id is a copy of base_id (e.g. "clock#2").
    -- Uses plain string comparison to avoid Lua pattern-character issues.
    local function _isCopyOf(order_id, base_id)
        local prefix = base_id .. "#"
        return #order_id > #prefix and order_id:sub(1, #prefix) == prefix
    end
    local function _copyNum(order_id, base_id)
        local prefix = base_id .. "#"
        return tonumber(order_id:sub(#prefix + 1))
    end

    -- Copy descriptors live in the global Registry, so the configured count
    -- must also be global. A copy can then be selected independently on the
    -- built-in Home Screen and on every SimpleUI 2.5 Custom Screen.
    local COPY_COUNT_PREFIX = "plugin_enhancements_module_copies_"
    local function _getCopyCount(mod_id, pfx)
        local count = tonumber(SUISettings:readSetting(COPY_COUNT_PREFIX .. mod_id))
        if not count and pfx then
            -- Preserve settings written by earlier builds of this patch.
            count = tonumber(SUISettings:readSetting(pfx .. "module_" .. mod_id .. "_copies"))
        end
        count = math.floor(count or 1)
        if count < 1 then return 1 end
        if count > 10 then return 10 end
        return count
    end

    local function _setCopyCount(mod_id, count)
        SUISettings:saveSetting(COPY_COUNT_PREFIX .. mod_id, count)
    end

    local original_list = Registry.list
    Registry.list = function()
        local mods = original_list()

        for _mi, mod in ipairs(mods or {}) do
            if not _isNativeInstanceId(mod.id) and not mod._module_copies_enhanced then
                local original_getMenuItems = mod.getMenuItems

                local function enhanceModuleMenuItems(ctx_menu)
                    local original_items = original_getMenuItems and original_getMenuItems(ctx_menu) or {}

                    local enhanced_items = {}
                    for _i, item in ipairs(original_items) do
                        enhanced_items[#enhanced_items + 1] = item
                    end

                    enhanced_items[#enhanced_items + 1] = {
                        text = _("Number of Copies"),
                        keep_menu_open = true,
                        callback = function()
                            local pfx = ctx_menu and ctx_menu.pfx or "simpleui_"
                            local current_copies = _getCopyCount(mod.id, pfx)

                            UIManager:show(SpinWidget:new{
                                title_text   = _("Number of Copies"),
                                info_text    = _("Set how many copies of this module to show.\nEach copy can be placed on different pages."),
                                value        = current_copies,
                                value_min    = 1,
                                value_max    = 10,
                                value_step   = 1,
                                ok_text      = _("OK"),
                                cancel_text  = _("Cancel"),
                                default_value = 1,
                                callback = function(spin)
                                    local new_copies = spin.value
                                    _setCopyCount(mod.id, new_copies)

                                    -- Build a "needed" set for copies 2..new_copies.
                                    local needed = {}
                                    for i = 2, new_copies do needed[i] = true end

                                    local layout_key = SimpleUICompat.getLayoutKeyForPrefix(pfx)
                                    local layout = SUISettings:readSetting(layout_key)
                                    if layout and type(layout.pages) == "table" then
                                        -- ── New simpleui_layout path ────────────────────────
                                        local new_pages    = {}
                                        local found_original = false

                                        for _i, page in ipairs(layout.pages) do
                                            local new_modules = {}
                                            for _i, order_id in ipairs(page.modules or {}) do
                                                if order_id == mod.id then
                                                    found_original = true
                                                    new_modules[#new_modules + 1] = order_id
                                                elseif _isCopyOf(order_id, mod.id) then
                                                    local cn = _copyNum(order_id, mod.id)
                                                    if cn and cn <= new_copies then
                                                        new_modules[#new_modules + 1] = order_id
                                                        needed[cn] = nil
                                                    end
                                                    -- else: remove — exceeds new_copies
                                                else
                                                    new_modules[#new_modules + 1] = order_id
                                                end
                                            end
                                            -- Shallow-copy the page table, replacing modules.
                                            local new_page = {}
                                            for k, v in pairs(page) do new_page[k] = v end
                                            new_page.modules = new_modules
                                            new_pages[#new_pages + 1] = new_page
                                        end

                                        -- Append any still-needed copies to the last page.
                                        if #new_pages > 0 then
                                            local lp = new_pages[#new_pages]
                                            for i = 2, new_copies do
                                                if needed[i] then
                                                    lp.modules[#lp.modules + 1] = mod.id .. "#" .. i
                                                end
                                            end
                                        end

                                        -- If the original module was absent, add it + copies.
                                        if not found_original and #new_pages > 0 then
                                            local lp = new_pages[#new_pages]
                                            lp.modules[#lp.modules + 1] = mod.id
                                            for i = 2, new_copies do
                                                lp.modules[#lp.modules + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        local new_layout = {}
                                        for k, v in pairs(layout) do new_layout[k] = v end
                                        new_layout.pages = new_pages
                                        SUISettings:saveSetting(layout_key, new_layout)
                                    else
                                        -- ── Legacy module_order path ────────────────────────
                                        local PAGE_BREAK  = SimpleUICompat.require("homescreen").PAGE_BREAK_ID
                                        local saved_order = SUISettings:readSetting(pfx .. "module_order") or {}
                                        local new_order   = {}
                                        local found_original = false

                                        for _i, order_id in ipairs(saved_order) do
                                            if order_id == PAGE_BREAK then
                                                new_order[#new_order + 1] = order_id
                                            elseif order_id == mod.id then
                                                found_original = true
                                                new_order[#new_order + 1] = order_id
                                            elseif _isCopyOf(order_id, mod.id) then
                                                local cn = _copyNum(order_id, mod.id)
                                                if cn and cn <= new_copies then
                                                    new_order[#new_order + 1] = order_id
                                                    needed[cn] = nil
                                                end
                                            else
                                                new_order[#new_order + 1] = order_id
                                            end
                                        end

                                        for i = 2, new_copies do
                                            if needed[i] then
                                                new_order[#new_order + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        if not found_original then
                                            new_order[#new_order + 1] = mod.id
                                            for i = 2, new_copies do
                                                new_order[#new_order + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        SUISettings:saveSetting(pfx .. "module_order", new_order)
                                    end

                                    -- Invalidate the copy wrapper cache for this module.
                                    local copy_prefix = mod.id .. "#"
                                    for k in pairs(wrapped_cache) do
                                        if k:sub(1, #copy_prefix) == copy_prefix then
                                            wrapped_cache[k] = nil
                                        end
                                    end

                                    -- Rebuild every live Custom Screen on
                                    -- 2.5+/2.6, or the single Homescreen on
                                    -- 2.1.1. This also clears the engine's
                                    -- per-screen enabled-module caches.
                                    SimpleUICompat.rebuildAllLayouts()

                                    if ctx_menu and ctx_menu.refresh then
                                        ctx_menu.refresh()
                                    end
                                end,
                            })
                        end,
                    }

                    return enhanced_items
                end

                mod.getMenuItems = enhanceModuleMenuItems

                -- Wrap the base module's setEnabled so that deactivating it
                -- when copies are still in the layout keeps settings enabled.
                -- Without this, LayoutService.save() calls setEnabled(pfx,false)
                -- for the base module when it is not on a page, which clears
                -- SETTING_ON and prevents any active copies from rendering.
                local _base_id = mod.id
                if type(mod.setEnabled) == "function" then
                    local _orig_se = mod.setEnabled
                    mod.setEnabled = function(pfx, on)
                        if not on then
                            local layout = SUISettings:readSetting(
                                SimpleUICompat.getLayoutKeyForPrefix(pfx))
                            if layout and type(layout.pages) == "table" then
                                for _i, pg in ipairs(layout.pages) do
                                    for _i, pid in ipairs(pg.modules or {}) do
                                        if _isCopyOf(pid, _base_id) then
                                            _orig_se(pfx, true)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                        _orig_se(pfx, on)
                    end
                elseif mod.enabled_key then
                    local _ek = mod.enabled_key
                    mod.setEnabled = function(pfx, on)
                        if not on then
                            local layout = SUISettings:readSetting(
                                SimpleUICompat.getLayoutKeyForPrefix(pfx))
                            if layout and type(layout.pages) == "table" then
                                for _i, pg in ipairs(layout.pages) do
                                    for _i, pid in ipairs(pg.modules or {}) do
                                        if _isCopyOf(pid, _base_id) then
                                            SUISettings:saveSetting(pfx .. _ek, true)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                        SUISettings:saveSetting(pfx .. _ek, on)
                    end
                end

                mod._module_copies_enhanced = true
            end
        end

        -- Append copy modules so buildModulePicker can offer them.
        -- For each base module that has N copies configured, add entries for
        -- copies 2..N.  The picker's active_set is keyed on raw layout IDs
        -- (e.g. "clock#2"), so giving copies their own id lets the filter work.
        local result = {}
        for _i, m in ipairs(mods or {}) do
            result[#result + 1] = m
        end
        for _i, m in ipairs(mods or {}) do
            if not m.id:find("#", 1, true) and not _isNativeInstanceId(m.id) then
                local copies = _getCopyCount(m.id, "simpleui_hs_")
                for ci = 2, copies do
                    local copy_mod = Registry.get(m.id .. "#" .. ci)
                    if copy_mod then
                        result[#result + 1] = copy_mod
                    end
                end
            end
        end
        return result
    end

    logger.info("simpleui_ext: patch_module_copies: patch applied successfully")
end

return patch
