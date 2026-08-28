-- Plugin_enhancements
--
-- Unified KOReader entry point for optional patches and SimpleUI modules.
-- Component files are loaded at startup so their metadata and menus are
-- available, but newly discovered modules and patches are disabled until the
-- user explicitly enables them.

local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _               = require("gettext")
local SimpleUICompat  = require("utils/simpleui_compat")

local PLUGIN_ID      = "Plugin_enhancements"
local PLUGIN_VERSION = "1.1.4"

-- PluginLoader normally provides self.path, but keeping a source-derived
-- fallback makes discovery reliable during early menu construction and in
-- test launchers that load main.lua directly.
local MAIN_SOURCE = debug.getinfo(1, "S").source or ""
local MAIN_FILE = MAIN_SOURCE:sub(1, 1) == "@" and MAIN_SOURCE:sub(2) or MAIN_SOURCE
MAIN_FILE = MAIN_FILE:gsub("\\", "/")
local FALLBACK_PLUGIN_PATH = MAIN_FILE:match("^(.*)/main%.lua$")

-- Fallback labels are used only when a component cannot be loaded. Normally
-- the metadata returned by the component itself is shown in the menu.
local MODULE_CATALOG = {
    currently_with_pace = { name = "当前阅读 (With Pace)" },
    currently_yanllsama_v1 = { name = "当前阅读 (Yanllsama Legacy)" },
    hero_currently = { name = "当前阅读 (Hero)" },
    reading_insights = { name = "阅读统计" },
    reading_streaks = { name = "阅读连胜" },
    recent_book_stats = { name = "最近阅读统计" },
}

local PATCH_CATALOG = {
    clock_date_cn = { name = "时钟模块：中文日期格式支持", plugin_name = "SimpleUI", plugin_order = 10 },
    coverdeck_description = { name = "封面轮播模块：增加书籍简介显示", plugin_name = "SimpleUI", plugin_order = 10 },
    coverdeck_exclude = { name = "封面轮播模块：增加排除路径功能", plugin_name = "SimpleUI", plugin_order = 10 },
    module_copies = { name = "模块副本功能", plugin_name = "SimpleUI", plugin_order = 10 },
    qs_slider_style = { name = "前光灯：滑块样式", plugin_name = "SimpleUI", plugin_order = 10 },
    qa_dual_state_icons = { name = "快捷设置栏：双状态图标（长按进入设置）", plugin_name = "SimpleUI", plugin_order = 10 },
    recent_extra = { name = "最近书籍模块：增加行数和排除路径功能", plugin_name = "SimpleUI", plugin_order = 10 },
    screensaver_homescreen = { name = "新增屏保：主页屏保", plugin_name = "SimpleUI", plugin_order = 10 },
    screensaver_insights = { name = "新增屏保：阅读分析屏保", plugin_name = "SimpleUI", plugin_order = 10 },
    filebrowserplus_qr = { name = "二维码增强", plugin_name = "FileBrowserPlus", plugin_order = 20 },
    swipe_animation = { name = "擦除渐显翻页动画", plugin_name = "KOReader", plugin_order = 30 },
}

local function settingsPath()
    return DataStorage:getSettingsDir() .. "/" .. PLUGIN_ID .. ".lua"
end

local function displayNameFromId(id)
    local words = tostring(id or "component"):gsub("_", " ")
    return (words:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end))
end

local function discoverFiles(plugin_path, directory, prefix)
    local found = {}
    if not plugin_path then return found, "插件目录不可用" end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.warn(PLUGIN_ID .. ": cannot load lfs; " .. directory .. " discovery skipped")
        return found, "无法加载文件扫描组件"
    end

    local dir_path = plugin_path .. "/" .. directory
    local pattern = "^(" .. prefix .. "_%a[%w_]*)%.lua$"
    local ok_scan, scan_error = pcall(function()
        for entry in lfs.dir(dir_path) do
            local stem = entry:match(pattern)
            if stem then
                found[#found + 1] = {
                    id = stem:match("^" .. prefix .. "_([%w_]+)$"),
                    path = dir_path .. "/" .. entry,
                }
            end
        end
    end)
    if not ok_scan then
        return found, string.format("无法扫描 %s：%s", dir_path, tostring(scan_error))
    end
    table.sort(found, function(left, right) return left.id < right.id end)
    return found
end

local function fallbackMetadata(id, catalog, description)
    local known = catalog[id] or {}
    return {
        id = id,
        name = known.name or displayNameFromId(id),
        description = description,
        default_enabled = false,
        plugin_name = known.plugin_name,
        plugin_order = known.plugin_order,
    }
end

local PluginEnhancements = WidgetContainer:new{
    name = PLUGIN_ID,
    is_doc_only = false,
    _settings = nil,
    _registry = nil,
    _mod_ids = {},
    _mods = {},
    _modules_meta = {},
    _patches_meta = {},
    _plugin_path = FALLBACK_PLUGIN_PATH,
    _components_ready = false,
    _components_loading = false,
    _component_error = nil,
}

function PluginEnhancements:_getSettings()
    if not self._settings then
        self._settings = LuaSettings:open(settingsPath())
    end
    return self._settings
end

function PluginEnhancements:_getStates(key)
    return self:_getSettings():readSetting(key) or {}
end

function PluginEnhancements:_isModuleEnabled(module_id)
    return self:_getStates("module_states")[module_id] == true
end

function PluginEnhancements:_isPatchEnabled(patch_id)
    return self:_getStates("patch_states")[patch_id] == true
end

function PluginEnhancements:_setComponentEnabled(key, component_id, enabled)
    local states = self:_getStates(key)
    states[component_id] = enabled == true
    local settings = self:_getSettings()
    settings:saveSetting(key, states)
    settings:flush()
end

function PluginEnhancements:_setModuleEnabled(module_id, enabled)
    self:_setComponentEnabled("module_states", module_id, enabled)
end

function PluginEnhancements:_setPatchEnabled(patch_id, enabled)
    self:_setComponentEnabled("patch_states", patch_id, enabled)
end

function PluginEnhancements:init()
    self.ui.menu:registerToMainMenu(self)

    -- Wait one UI tick so target plugins, especially SimpleUI, finish init().
    UIManager:scheduleIn(0, function()
        local ok, err = self:_ensureComponents()
        if not ok then
            logger.warn(PLUGIN_ID .. ": deferred registration failed: " .. tostring(err))
        end
    end)
end

-- The scheduled startup pass is normally enough. Calling this from every menu
-- builder also covers devices that open the menu before that pass completes,
-- and makes a failed discovery retryable instead of leaving an empty submenu.
function PluginEnhancements:_ensureComponents()
    if self._components_ready then return true end
    if self._components_loading then
        return false, "组件仍在初始化，请稍后重试"
    end

    self._components_loading = true
    local ok, err = pcall(function() self:_registerComponents() end)
    self._components_loading = false
    if ok then
        self._components_ready = true
        self._component_error = nil
        return true
    end

    self._components_ready = false
    self._component_error = tostring(err)
    logger.warn(PLUGIN_ID .. ": component initialization failed: " .. self._component_error)
    return false, self._component_error
end

function PluginEnhancements:_registerComponents()
    self._plugin_path = self.path or self._plugin_path or FALLBACK_PLUGIN_PATH
    if not self._plugin_path or self._plugin_path == "" then
        error("无法确定插件目录")
    end

    self._mod_ids = {}
    self._mods = {}
    self._modules_meta = {}
    self._patches_meta = {}

    local ok_registry, Registry, registry_path = SimpleUICompat.tryRequire("registry")
    if ok_registry and Registry then
        self._registry = Registry
        self._simpleui_family = type(SimpleUICompat.getVersion) == "function"
            and SimpleUICompat.getVersion()
            or (registry_path == "modules/moduleregistry" and "2.5+" or "2.1.x")
    else
        self._registry = nil
        self._simpleui_family = "未检测到"
        logger.warn(PLUGIN_ID .. ": SimpleUI moduleregistry not found; enabled modules cannot register")
    end

    self:_loadModules()
    self:_loadPatches()
    if #self._modules_meta == 0 and #self._patches_meta == 0 then
        error("没有发现组件文件，当前目录：" .. self._plugin_path)
    end
    self:_prewarmBookModuleCaches()

    -- Registry.register() invalidates SimpleUI's registry cache, but a Home
    -- Screen that was already constructed can still retain its own enabled
    -- module cache. Rebuild live layouts once after external registration so
    -- enabled modules appear immediately regardless of plugin load order.
    if #self._mod_ids > 0 then
        local ok_rebuild, rebuild_error = SimpleUICompat.rebuildAllLayouts()
        if not ok_rebuild then
            logger.dbg(PLUGIN_ID .. ": no live SimpleUI layout to rebuild: "
                .. tostring(rebuild_error))
        end
    end
end

-- Load every module file for metadata, but register only explicitly enabled
-- modules with SimpleUI.
function PluginEnhancements:_loadModules()
    local states = self:_getStates("module_states")
    local existing = {}
    local changed = false

    local module_files, discovery_error = discoverFiles(self._plugin_path, "modules", "module")
    if discovery_error then
        self._component_error = discovery_error
        logger.warn(PLUGIN_ID .. ": " .. discovery_error)
    end
    for module_index, module_file in ipairs(module_files) do
        local id = module_file.id
        existing[id] = true
        if states[id] == nil then
            states[id] = false
            changed = true
        end

        local meta = fallbackMetadata(id, MODULE_CATALOG, _("Optional SimpleUI desktop module"))
        local ok_load, mod = pcall(dofile, module_file.path)
        if not ok_load or type(mod) ~= "table" then
            meta.runtime_error = tostring(mod)
            logger.warn(PLUGIN_ID .. ": failed to load module " .. id .. ": " .. tostring(mod))
        elseif mod.id ~= id then
            meta.runtime_error = "module id must match filename"
            logger.warn(PLUGIN_ID .. ": module id mismatch in " .. module_file.path)
        else
            mod.default_enabled = false
            mod.name = mod.name or meta.name
            mod.description = mod.description or meta.description
            meta = mod

            if states[id] == true then
                if not self._registry then
                    meta.runtime_error = _("SimpleUI module registry is unavailable")
                else
                    local ok_register, register_error = pcall(function()
                        self._registry.register(mod)
                    end)
                    if ok_register then
                        self._mod_ids[#self._mod_ids + 1] = mod.id
                        self._mods[#self._mods + 1] = mod
                    else
                        meta.runtime_error = tostring(register_error)
                        logger.warn(PLUGIN_ID .. ": failed to register module " .. id .. ": " .. tostring(register_error))
                    end
                end
            end
        end
        self._modules_meta[#self._modules_meta + 1] = meta
    end

    for id in pairs(states) do
        if not existing[id] then
            states[id] = nil
            changed = true
        end
    end
    if changed then
        local settings = self:_getSettings()
        settings:saveSetting("module_states", states)
        settings:flush()
    end
end

-- Load every patch file for metadata and custom menus, but call apply() only
-- for explicitly enabled patches.
function PluginEnhancements:_loadPatches()
    local states = self:_getStates("patch_states")
    local existing = {}
    local changed = false

    local patch_files, discovery_error = discoverFiles(self._plugin_path, "patches", "patch")
    if discovery_error then
        self._component_error = discovery_error
        logger.warn(PLUGIN_ID .. ": " .. discovery_error)
    end
    for patch_index, patch_file in ipairs(patch_files) do
        local id = patch_file.id
        existing[id] = true
        if states[id] == nil then
            states[id] = false
            changed = true
        end

        local meta = fallbackMetadata(id, PATCH_CATALOG, _("Optional KOReader plugin enhancement patch"))
        local ok_load, patch = pcall(dofile, patch_file.path)
        if not ok_load or type(patch) ~= "table" then
            meta.runtime_error = tostring(patch)
            logger.warn(PLUGIN_ID .. ": failed to load patch " .. id .. ": " .. tostring(patch))
        elseif patch.id ~= id then
            meta.runtime_error = "patch id must match filename"
            logger.warn(PLUGIN_ID .. ": patch id mismatch in " .. patch_file.path)
        elseif type(patch.apply) ~= "function" then
            meta.runtime_error = "patch has no apply() function"
            logger.warn(PLUGIN_ID .. ": patch has no apply() function: " .. id)
        else
            local known = PATCH_CATALOG[id] or {}
            patch.default_enabled = false
            patch.name = patch.name or meta.name
            patch.description = patch.description or meta.description
            patch.plugin_name = patch.plugin_name or known.plugin_name or "其他"
            patch.plugin_order = patch.plugin_order or known.plugin_order or 1000
            meta = patch

            if states[id] == true then
                local ok_apply, applied, reason = pcall(patch.apply)
                if not ok_apply then
                    patch.runtime_error = tostring(applied)
                    logger.warn(PLUGIN_ID .. ": patch " .. id .. " failed: " .. patch.runtime_error)
                elseif applied == false then
                    patch.runtime_error = tostring(reason or "not applied")
                    logger.warn(PLUGIN_ID .. ": patch " .. id .. ": " .. patch.runtime_error)
                end
            end
        end
        self._patches_meta[#self._patches_meta + 1] = meta
    end

    for id in pairs(states) do
        if not existing[id] then
            states[id] = nil
            changed = true
        end
    end
    if changed then
        local settings = self:_getSettings()
        settings:saveSetting("patch_states", states)
        settings:flush()
    end
end

function PluginEnhancements:_prewarmBookModuleCaches()
    local has_prewarm = false
    for _, mod in ipairs(self._mods) do
        if type(mod.prewarm) == "function" then
            has_prewarm = true
            break
        end
    end
    if not has_prewarm then return end

    pcall(function()
        local ok_config, Config = SimpleUICompat.tryRequire("config")
        if not ok_config or not Config or type(Config.openStatsDB) ~= "function" then return end
        local db_conn = Config.openStatsDB()
        if not db_conn then return end

        local ok_shared, Shared = SimpleUICompat.tryRequire("books_shared")
        if not ok_shared or not Shared or type(Shared.prefetchBooks) ~= "function" then
            pcall(function() db_conn:close() end)
            return
        end

        local books_state
        pcall(function() books_state = Shared.prefetchBooks(true, true, 5) end)
        if books_state then
            for _, mod in ipairs(self._mods) do
                if type(mod.prewarm) == "function" then
                    pcall(function() mod.prewarm(books_state, db_conn) end)
                end
            end
        end
        pcall(function() db_conn:close() end)
    end)
end

function PluginEnhancements:onCloseDocument()
    for _, mod in ipairs(self._mods) do
        if type(mod.invalidateCache) == "function" then
            pcall(mod.invalidateCache)
        end
    end

    UIManager:scheduleIn(2, function()
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        if not ok_reader or (ReaderUI and ReaderUI.instance) then return end
        self:_runDeferredStatsRefresh()
    end)
end

function PluginEnhancements:_runDeferredStatsRefresh()
    local ok_config, Config = SimpleUICompat.tryRequire("config")
    if not ok_config or not Config or type(Config.openStatsDB) ~= "function" then return end
    local db_conn = Config.openStatsDB()
    if not db_conn then return end

    for _, mod in ipairs(self._mods) do
        if type(mod.refreshStats) == "function" then
            pcall(function() mod.refreshStats(nil, db_conn) end)
        end
    end
    pcall(function() db_conn:close() end)

    -- 2.5+/2.6 may have a Custom Screen live instead of the built-in Home
    -- Screen. The compatibility helper refreshes every live surface there and
    -- falls back to the sole 2.1.1 Homescreen instance on the legacy layout.
    SimpleUICompat.refreshAllLiveImmediate(false)
end

function PluginEnhancements:onClosePlugin()
    if self._registry then
        for _, id in ipairs(self._mod_ids) do
            pcall(function() self._registry.unregister(id) end)
        end
    end
    self._registry = nil
    self._mod_ids = {}
    self._mods = {}
    self._modules_meta = {}
    self._patches_meta = {}
    self._components_ready = false
end

function PluginEnhancements:_componentStatusItem(kind)
    local label = kind == "module" and "扩展模块" or "功能补丁"
    local message = self._component_error
        or ("没有发现" .. label .. "文件")
    local plugin_path = self._plugin_path or self.path or "未知"
    return {
        text = label .. "加载异常（点击查看）",
        help_text = message,
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = string.format(
                    "%s未能正常显示。\n\n原因：%s\n\n插件目录：%s\n\n请确认整个 .koplugin 目录已完整复制，然后重启 KOReader。",
                    label,
                    message,
                    plugin_path
                ),
            })
        end,
    }
end

function PluginEnhancements:_componentToggleItem(kind, component)
    local item = component
    local is_module = kind == "module"
    local is_enabled
    if is_module then
        is_enabled = function() return self:_isModuleEnabled(item.id) end
    else
        is_enabled = function() return self:_isPatchEnabled(item.id) end
    end

    local menu_item = {
        text = item.name or item.id,
        help_text = item.runtime_error
            and ((item.description or "") .. "\n\n当前加载错误：" .. item.runtime_error)
            or item.description,
        checked_func = is_enabled,
        callback = function()
            local enabled = is_enabled()
            if is_module then
                self:_setModuleEnabled(item.id, not enabled)
            else
                self:_setPatchEnabled(item.id, not enabled)
            end
            UIManager:show(InfoMessage:new{
                text = string.format(
                    "%s已%s。\n\n请重启 KOReader 使更改生效。",
                    item.name or item.id,
                    enabled and "关闭" or "开启"
                ),
                timeout = 3,
            })
        end,
    }
    if not is_module and type(item.hold_callback) == "function" then
        menu_item.hold_keep_menu_open = true
        menu_item.hold_callback = function(touchmenu_instance, source_item)
            if not is_enabled() then
                UIManager:show(InfoMessage:new{
                    text = "请先启用“" .. (item.name or item.id) .. "”，然后重启 KOReader。",
                    timeout = 3,
                })
                return
            end
            return item.hold_callback(touchmenu_instance, source_item)
        end
    end
    return menu_item
end

function PluginEnhancements:_buildModuleMenu()
    self:_ensureComponents()
    local menu = {}
    for _, mod in ipairs(self._modules_meta) do
        menu[#menu + 1] = self:_componentToggleItem("module", mod)
    end
    if #menu == 0 then
        menu[1] = self:_componentStatusItem("module")
    end
    return menu
end

function PluginEnhancements:_buildPatchMenu(plugin_name)
    self:_ensureComponents()
    local menu = {}
    for _, patch in ipairs(self._patches_meta) do
        if (patch.plugin_name or "其他") == plugin_name then
            local item_patch = patch
            menu[#menu + 1] = self:_componentToggleItem("patch", item_patch)

            -- Runtime settings are shown only after an enabled patch applied
            -- successfully during the current KOReader session.
            if self:_isPatchEnabled(item_patch.id)
                    and not item_patch.runtime_error
                    and type(item_patch.menu_items_func) == "function" then
                local ok_items, custom_items = pcall(item_patch.menu_items_func)
                if ok_items and type(custom_items) == "table" then
                    for _, custom_item in ipairs(custom_items) do
                        menu[#menu + 1] = custom_item
                    end
                else
                    menu[#menu + 1] = {
                        text = "设置菜单加载失败",
                        enabled = false,
                        help_text = tostring(custom_items),
                    }
                end
            end
        end
    end
    if #menu == 0 then
        menu[1] = self:_componentStatusItem("patch")
    end
    return menu
end

function PluginEnhancements:_buildPluginMenu()
    self:_ensureComponents()
    local items = {
        {
            text = "SimpleUI",
            sub_item_table = {
                {
                    text = "扩展模块",
                    sub_item_table_func = function() return self:_buildModuleMenu() end,
                },
                {
                    text = "功能补丁",
                    sub_item_table_func = function() return self:_buildPatchMenu("SimpleUI") end,
                },
            },
        },
    }

    local groups_by_name = {}
    local groups = {}
    for _, patch in ipairs(self._patches_meta) do
        local group_name = patch.plugin_name or "其他"
        if group_name ~= "SimpleUI" and not groups_by_name[group_name] then
            local group = { name = group_name, order = patch.plugin_order or 1000 }
            groups_by_name[group_name] = group
            groups[#groups + 1] = group
        end
    end
    table.sort(groups, function(left, right)
        if left.order == right.order then return left.name < right.name end
        return left.order < right.order
    end)

    for _, group in ipairs(groups) do
        local group_name = group.name
        items[#items + 1] = {
            text = group_name,
            sub_item_table = {
                {
                    text = "功能补丁",
                    sub_item_table_func = function() return self:_buildPatchMenu(group_name) end,
                },
            },
        }
    end

    items[#items + 1] = {
        text = "关于与帮助",
        sub_item_table = {
            {
                text = "扩展模块说明",
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = [[扩展模块说明

• With Pace：显示阅读速度和预计进度
• Yanllsama Legacy：可深度定制的阅读统计面板
• Hero：以大型卡片展示当前阅读信息
• 阅读统计：查看年度数据和月度图表
• 阅读连胜：统计连续阅读天数和周数
• 最近阅读统计：展示最近书籍的进度和时间]],
                    })
                end,
            },
            {
                text = "功能补丁说明",
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = [[功能补丁说明

【SimpleUI】
• 时钟中文日期：使用中文日期和星期格式
• 封面轮播简介：显示当前书籍简介
• 封面轮播排除：隐藏指定路径中的书籍
• 模块副本：在不同页面放置相同模块
• 双状态图标：分别显示开启和关闭图标
• 前光灯滑块：增加三种滑块样式
• 最近书籍增强：增加多行布局和路径排除
• 主页屏保：将 SimpleUI 首页用作屏保
• 阅读分析屏保：将阅读统计页面用作屏保

【FileBrowserPlus】
• 二维码增强：显示二维码并支持自动打开

【KOReader】
• 擦除渐显动画：增加擦除渐显翻页效果]],
                    })
                end,
            },
            {
                text = "插件信息",
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            "插件增强 v%s\n\n集中管理 KOReader 功能补丁与\nSimpleUI 扩展模块。\n\n兼容 SimpleUI 2.1.1 / 2.5.0 / 2.6.x\n当前识别：%s\n\n提示：\n更改组件状态后，请完整重启 KOReader。\n\n许可：GNU AGPL v3",
                            PLUGIN_VERSION,
                            self._simpleui_family or "等待初始化"
                        ),
                    })
                end,
            },
        },
    }
    return items
end

function PluginEnhancements:addToMainMenu(menu_items)
    menu_items[PLUGIN_ID] = {
        text = "插件增强",
        sorting_hint = "tools",
        sub_item_table_func = function() return self:_buildPluginMenu() end,
    }
end

return PluginEnhancements
