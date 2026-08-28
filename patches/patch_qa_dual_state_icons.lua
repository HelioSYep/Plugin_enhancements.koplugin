-- Configurable dual-state icons for SimpleUI 2.5 custom Quick Actions.
--
-- Configuration deliberately stays separate from each Quick Action's normal
-- `icon` field. SimpleUI continues to own and display that single icon; this
-- patch only overrides the icon returned at render time when both state icons
-- are configured and the bound action exposes a reliable boolean state.

local Device         = require("device")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")
local SimpleUICompat = require("utils/simpleui_compat")

local P = {
    id              = "qa_dual_state_icons",
    name            = "快捷设置栏：双状态图标（长按进入设置）",
    plugin_name     = "SimpleUI",
    plugin_order    = 10,
    description     = "为已经绑定到 SimpleUI 的插件或系统快捷动作设置开启、关闭两张图标。插件动作可保持快捷设置栏开启并实时刷新图标；系统操作保留 SimpleUI 原有的执行和关闭行为。只有能可靠读取状态的动作才支持双状态图标。",
    default_enabled = false,
}

local SETTINGS_KEY = "plugin_enhancements_qa_dual_icons_v2"
local unpackValues = table.unpack or unpack
local QA
local SUISettings

local function storeGet(key)
    if not SUISettings then return nil end
    if type(SUISettings.get) == "function" then return SUISettings:get(key) end
    if type(SUISettings.readSetting) == "function" then return SUISettings:readSetting(key) end
end

local function storeSet(key, value)
    if not SUISettings then return end
    if type(SUISettings.set) == "function" then
        SUISettings:set(key, value)
    elseif type(SUISettings.saveSetting) == "function" then
        SUISettings:saveSetting(key, value)
        if type(SUISettings.flush) == "function" then SUISettings:flush() end
    end
end

local function loadIconSettings()
    local settings = storeGet(SETTINGS_KEY)
    return type(settings) == "table" and settings or {}
end

local function saveIconSettings(settings)
    storeSet(SETTINGS_KEY, settings)
end

local function liveFileManager()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

local function simpleUIPlugin()
    local fm = liveFileManager()
    if fm and fm._simpleui_plugin then return fm._simpleui_plugin end
    local RUI = package.loaded["apps/reader/readerui"]
    return RUI and RUI.instance and RUI.instance.simpleui
end

local function pluginInstance(plugin_key)
    local fm = liveFileManager()
    if fm and plugin_key and fm[plugin_key] then return fm[plugin_key] end

    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if ok_loader and PluginLoader and type(PluginLoader.getPluginInstance) == "function" then
        local ok_instance, instance = pcall(PluginLoader.getPluginInstance, PluginLoader, plugin_key)
        if ok_instance and instance then return instance end
    end
end

local function booleanMethodState(instance)
    for _, method_name in ipairs({ "isRunning", "isEnabled", "isActive", "isOpen" }) do
        local method = instance and instance[method_name]
        if type(method) == "function" then
            local ok, value = pcall(method, instance)
            if ok and type(value) == "boolean" then return value, method_name end
        end
    end
end

local function menuCheckedState(instance, plugin_key)
    if not instance or type(instance.addToMainMenu) ~= "function" then return nil end
    local menu_items = {}
    local ok = pcall(instance.addToMainMenu, instance, menu_items)
    if not ok then return nil end

    local item = menu_items[plugin_key] or menu_items[instance.name]
    if not item and plugin_key then
        local wanted = tostring(plugin_key):lower()
        for key, candidate in pairs(menu_items) do
            if tostring(key):lower() == wanted then
                item = candidate
                break
            end
        end
    end
    if item and type(item.checked_func) == "function" then
        local ok_checked, checked = pcall(item.checked_func)
        if ok_checked and type(checked) == "boolean" then
            return checked, "checked_func"
        end
    end
end

local function pluginState(plugin_key)
    local instance = pluginInstance(plugin_key)
    if not instance then return nil, "插件当前不可用" end
    local state, source = booleanMethodState(instance)
    if state ~= nil then return state, source end
    state, source = menuCheckedState(instance, plugin_key)
    if state ~= nil then return state, source end
    return nil, "只有 launch，没有状态接口"
end

local function wifiState()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_nm or not NetworkMgr or type(NetworkMgr.isWifiOn) ~= "function" then
        return nil, "网络状态接口不可用"
    end
    local ok, enabled = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    if ok and type(enabled) == "boolean" then return enabled, "NetworkMgr:isWifiOn" end
    return nil, "网络状态接口不可用"
end

local function frontlightState()
    local ok_power, powerd = pcall(Device.getPowerDevice, Device)
    if not ok_power or not powerd then
        return nil, "前光灯状态接口不可用"
    end

    if type(powerd.isFrontlightOn) == "function" then
        local ok, enabled = pcall(powerd.isFrontlightOn, powerd)
        if ok and type(enabled) == "boolean" then
            return enabled, "PowerD:isFrontlightOn"
        end
    end
    if type(powerd.isFrontlightOff) == "function" then
        local ok, disabled = pcall(powerd.isFrontlightOff, powerd)
        if ok and type(disabled) == "boolean" then
            return not disabled, "PowerD:isFrontlightOff"
        end
    end

    -- Compatibility fallback for older PowerD implementations. Prefer the
    -- explicit on/off API above because some devices preserve the last
    -- non-zero intensity while the frontlight is switched off.
    if type(powerd.frontlightIntensity) == "function" then
        local ok, intensity = pcall(powerd.frontlightIntensity, powerd)
        if ok and type(intensity) == "number" then
            return intensity > 0, "PowerD:frontlightIntensity"
        end
    end
    return nil, "前光灯状态接口不可用"
end

local function callBooleanMethod(object, method_name)
    local method = object and object[method_name]
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method, object)
    if ok and type(value) == "boolean" then return value end
end

local function deviceSupports(method_names)
    if type(method_names) == "string" then method_names = { method_names } end
    for _, method_name in ipairs(method_names or {}) do
        if callBooleanMethod(Device, method_name) ~= true then
            return false, "当前设备不支持此系统操作"
        end
    end
    return true
end

local function onSupportedDevice(method_names, resolver)
    return function()
        local supported, reason = deviceSupports(method_names)
        if not supported then return nil, reason end
        return resolver()
    end
end

local function readerSettingState(method_name, key, source)
    local settings = G_reader_settings
    local method = settings and settings[method_name]
    if type(method) ~= "function" then
        return nil, "系统设置状态接口不可用"
    end
    local ok, value = pcall(method, settings, key)
    if ok and type(value) == "boolean" then
        return value, source or key
    end
    return nil, "系统设置状态接口不可用"
end

local function touchInputState()
    if type(UIManager._input_gestures_disabled) ~= "boolean" then
        return nil, "触摸输入状态接口不可用"
    end
    return not UIManager._input_gestures_disabled, "UIManager 触摸输入状态"
end

local function rotationState()
    local screen = Device and Device.screen
    if not screen or type(screen.getRotationMode) ~= "function" then
        return nil, "屏幕方向状态接口不可用"
    end
    local ok, mode = pcall(screen.getRotationMode, screen)
    if ok and type(mode) == "number" then
        -- KOReader uses even values for portrait and odd values for landscape.
        -- The configured on icon therefore represents landscape, while the off
        -- icon represents portrait.
        return mode % 2 == 1, "屏幕方向（横屏/竖屏）"
    end
    return nil, "屏幕方向状态接口不可用"
end

local SYSTEM_STATE = {
    toggle_filebrowserplus_server = function() return pluginState("filebrowserplus") end,
    toggle_wifi                   = onSupportedDevice("hasWifiToggle", wifiState),
    toggle_frontlight             = onSupportedDevice("hasFrontlight", frontlightState),
    night_mode                    = function()
        return readerSettingState("isTrue", "night_mode", "夜间模式")
    end,
    toggle_gsensor = onSupportedDevice("hasGSensor", function()
        return readerSettingState("nilOrFalse", "input_ignore_gsensor", "重力感应")
    end),
    lock_gsensor = onSupportedDevice("hasGSensor", function()
        return readerSettingState("isTrue", "input_lock_gsensor", "自动旋转锁定")
    end),
    toggle_hold_corners = onSupportedDevice("isTouchDevice", function()
        return readerSettingState("nilOrFalse", "ignore_hold_corners", "角落长按")
    end),
    toggle_touch_input = onSupportedDevice("isTouchDevice", touchInputState),
    swap_left_page_turn_buttons = onSupportedDevice({ "hasDPad", "useDPadAsActionKeys" }, function()
        return readerSettingState("isTrue", "input_invert_left_page_turn_keys", "左侧翻页键反转")
    end),
    swap_right_page_turn_buttons = onSupportedDevice({ "hasDPad", "useDPadAsActionKeys" }, function()
        return readerSettingState("isTrue", "input_invert_right_page_turn_keys", "右侧翻页键反转")
    end),
    swap_page_turn_buttons = onSupportedDevice("hasKeys", function()
        return readerSettingState("isTrue", "input_invert_page_turn_keys", "翻页键反转")
    end),
    toggle_key_repeat = onSupportedDevice({ "hasKeys", "canKeyRepeat" }, function()
        return readerSettingState("nilOrFalse", "input_no_key_repeat", "按键重复")
    end),
    toggle_flash_on_chapter_boundaries = onSupportedDevice("hasEinkScreen", function()
        return readerSettingState("isTrue", "refresh_on_chapter_boundaries", "章节边界闪屏")
    end),
    toggle_no_flash_on_second_chapter_page = onSupportedDevice("hasEinkScreen", function()
        return readerSettingState("nilOrFalse", "no_refresh_on_second_chapter_page", "章节第二页闪屏")
    end),
    toggle_flash_on_pages_with_images = onSupportedDevice("hasEinkScreen", function()
        return readerSettingState("nilOrTrue", "refresh_on_pages_with_images", "图片页面闪屏")
    end),
    toggle_tap_links = onSupportedDevice("isTouchDevice", function()
        return readerSettingState("nilOrTrue", "tap_to_follow_links", "点击链接")
    end),
    toggle_page_change_animation = onSupportedDevice("canDoSwipeAnimation", function()
        return readerSettingState("isTrue", "swipe_animations", "翻页动画")
    end),
    toggle_rotation = rotationState,
}

local function stateForConfig(cfg)
    if type(cfg) ~= "table" then return nil, "动作配置不可用" end
    if cfg.plugin_key and cfg.plugin_key ~= "" then
        return pluginState(cfg.plugin_key)
    end
    if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
        local resolver = SYSTEM_STATE[cfg.dispatcher_action]
        if resolver then return resolver() end
        return nil, "该系统操作没有可靠的开关状态"
    end
    return nil, "不是插件或系统快捷动作"
end

local function isBoundPluginOrSystem(cfg)
    return type(cfg) == "table" and (
        (cfg.plugin_key and cfg.plugin_key ~= "")
        or (cfg.dispatcher_action and cfg.dispatcher_action ~= "")
    )
end

local function usableIcon(icon)
    if type(icon) ~= "string" or icon == "" then return false end
    local ok_config, Config = SimpleUICompat.tryRequire("config")
    if ok_config and Config and type(Config.isNerdIcon) == "function"
            and Config.isNerdIcon(icon) then
        return true
    end
    local ok_style, SUIStyle = SimpleUICompat.tryRequire("style")
    if ok_style and SUIStyle and type(SUIStyle.safeIconPath) == "function" then
        local ok, safe = pcall(SUIStyle.safeIconPath, icon, nil)
        return ok and safe ~= nil
    end
    return true
end

local function configuredPair(action_id)
    local item = loadIconSettings()[action_id]
    if type(item) ~= "table" then return nil end
    if usableIcon(item.icon_on) and usableIcon(item.icon_off) then return item end
end

local function refreshSimpleUISurfaces()
    local plugin = simpleUIPlugin()
    if plugin and type(plugin._rebuildAllNavbars) == "function" then
        pcall(plugin._rebuildAllNavbars, plugin)
    end

    local ok_hs, Homescreen = SimpleUICompat.tryRequire("homescreen")
    if ok_hs and Homescreen then
        if type(Homescreen.refreshAllLiveImmediate) == "function" then
            pcall(Homescreen.refreshAllLiveImmediate, true)
        elseif type(Homescreen.refreshImmediate) == "function" then
            pcall(Homescreen.refreshImmediate, true)
        elseif Homescreen._instance and type(Homescreen._instance._refreshImmediate) == "function" then
            pcall(Homescreen._instance._refreshImmediate, Homescreen._instance, true)
        end
    end

    local function refreshQuickSettingsMenu(menu)
        if menu and menu.item_table and menu.item_table._sui_qs_panel
                and type(menu.updateItems) == "function" then
            menu.is_fresh = true
            pcall(menu.updateItems, menu)
        end
    end
    local fm = liveFileManager()
    refreshQuickSettingsMenu(fm and fm.menu)
    local RUI = package.loaded["apps/reader/readerui"]
    refreshQuickSettingsMenu(RUI and RUI.instance and RUI.instance.menu)
end

local function installEntryWrapper()
    if QA._plugin_enhancements_dual_icons_orig_getEntry then return end
    local original = QA.getEntry
    QA._plugin_enhancements_dual_icons_orig_getEntry = original

    QA.getEntry = function(action_id)
        local entry = original(action_id)
        if type(action_id) ~= "string" or not action_id:match("^custom_qa_%d+$") then
            return entry
        end

        local pair = configuredPair(action_id)
        if not pair then return entry end
        local cfg = QA.getCustomQAConfig(action_id)
        local active = stateForConfig(cfg)
        if active == nil then return entry end
        -- Preserve every field SimpleUI attaches to the resolved entry
        -- (2.6 adds dim/state metadata consumed by the shared QA renderer).
        -- Only the icon is ours to replace.
        local resolved = {}
        for key, value in pairs(type(entry) == "table" and entry or {}) do
            resolved[key] = value
        end
        resolved.icon = active and pair.icon_on or pair.icon_off
        resolved.label = resolved.label or cfg.label or action_id
        return resolved
    end
end

local function installExecuteWrapper()
    if QA._plugin_enhancements_dual_icons_orig_executeCustomQA then return end
    local original = QA.executeCustomQA
    QA._plugin_enhancements_dual_icons_orig_executeCustomQA = original

    QA.executeCustomQA = function(action_id, ...)
        local pair = configuredPair(action_id)
        local cfg = pair and QA.getCustomQAConfig(action_id) or nil
        local before = cfg and stateForConfig(cfg) or nil
        local results = { pcall(original, action_id, ...) }

        if pair and cfg then
            UIManager:scheduleIn(0, function()
                local after = stateForConfig(cfg)
                if after ~= nil and after ~= before then refreshSimpleUISurfaces() end
            end)
            if cfg.dispatcher_action == "toggle_wifi"
                    or cfg.dispatcher_action == "toggle_frontlight" then
                UIManager:scheduleIn(1, refreshSimpleUISurfaces)
            end
        end

        if not results[1] then error(results[2], 0) end
        table.remove(results, 1)
        return unpackValues(results)
    end
end

local function shouldKeepQuickSettingsOpen(action_id)
    if type(action_id) ~= "string" or not action_id:match("^custom_qa_%d+$") then
        return false
    end
    local pair = configuredPair(action_id)
    if not pair then return false end
    local cfg = QA.getCustomQAConfig(action_id)
    -- Dispatcher actions must retain SimpleUI's original callback. SimpleUI
    -- deliberately closes the TouchMenu first and executes these actions on
    -- the next UI tick; running them immediately while the menu is still open
    -- can prevent device/system events from taking effect. It also overrides
    -- SimpleUI's own decision about whether the panel should close.
    if type(cfg) ~= "table" or not cfg.plugin_key or cfg.plugin_key == "" then
        return false
    end
    local state = stateForConfig(cfg)
    return state ~= nil
end

local function executeInQuickSettings(touch_menu, action_id)
    local fm = liveFileManager()
    local plugin = simpleUIPlugin()
    local ok, err = pcall(QA.execute, action_id, {
        plugin = plugin,
        fm = fm,
    })
    if not ok then
        logger.warn("plugin_enhancements: quick settings action failed", action_id, tostring(err))
    end

    -- Rebuild the still-open panel immediately. The execute wrapper also
    -- schedules another refresh for state changes that settle asynchronously.
    if touch_menu and type(touch_menu.updateItems) == "function" then
        touch_menu.is_fresh = true
        pcall(touch_menu.updateItems, touch_menu)
    end
    return true
end

local function installQuickSettingsKeepOpenWrapper()
    local ok_tm, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok_tm or not TouchMenu or type(TouchMenu.updateItems) ~= "function" then return end

    -- SimpleUI may install/uninstall its own TouchMenu wrapper after this patch
    -- loads. Re-wrap whenever the active implementation has changed.
    if TouchMenu.updateItems == TouchMenu._plugin_enhancements_dual_icons_updateItems then
        return
    end
    local original_update_items = TouchMenu.updateItems
    TouchMenu._plugin_enhancements_dual_icons_orig_updateItems = original_update_items

    local wrapper
    wrapper = function(touch_menu, ...)
        local results = { original_update_items(touch_menu, ...) }

        if touch_menu.item_table and touch_menu.item_table._sui_qs_panel
                and touch_menu._sui_qs_refs
                and type(touch_menu._sui_qs_refs.buttons) == "table" then
            local slots = storeGet("simpleui_qs_bar_slots")
            slots = type(slots) == "table" and slots or {}
            for index, ref in ipairs(touch_menu._sui_qs_refs.buttons) do
                local action_id = slots[index]
                if action_id and ref and shouldKeepQuickSettingsOpen(action_id) then
                    local bound_action_id = action_id
                    ref.callback = function()
                        return executeInQuickSettings(touch_menu, bound_action_id)
                    end
                end
            end
        end

        return unpackValues(results)
    end
    TouchMenu._plugin_enhancements_dual_icons_updateItems = wrapper
    TouchMenu.updateItems = wrapper
end

local function installQuickSettingsHook()
    local ok_qs, QSBar = SimpleUICompat.tryRequire("quicksettings")
    if not ok_qs or not QSBar then return end

    if type(QSBar.install) == "function"
            and not QSBar._plugin_enhancements_dual_icons_orig_install then
        local original_install = QSBar.install
        QSBar._plugin_enhancements_dual_icons_orig_install = original_install
        QSBar.install = function(...)
            local results = { original_install(...) }
            installQuickSettingsKeepOpenWrapper()
            return unpackValues(results)
        end
    end

    -- Covers the normal case where SimpleUI has already installed the bar.
    installQuickSettingsKeepOpenWrapper()
end

local function showMessage(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function iconLabel(icon)
    if type(icon) ~= "string" or icon == "" then return "未设置" end
    local ok_config, Config = SimpleUICompat.tryRequire("config")
    if ok_config and Config and type(Config.nerdIconChar) == "function" then
        local char = Config.nerdIconChar(icon)
        if char then return char end
    end
    return icon:match("([^/\\]+)$") or icon
end

local function saveActionIcon(action_id, field, icon)
    local settings = loadIconSettings()
    local item = type(settings[action_id]) == "table" and settings[action_id] or {}
    item[field] = icon
    if not item.icon_on and not item.icon_off then
        settings[action_id] = nil
    else
        settings[action_id] = item
    end
    saveIconSettings(settings)
end

local function selectIcon(action_id, field, current, touchmenu_instance)
    local picker_key = "_plugin_enhancements_dual_icon_" .. action_id .. "_" .. field
    QA.showIconPicker(current, function(icon)
        saveActionIcon(action_id, field, icon)
        refreshSimpleUISurfaces()
        if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
            touchmenu_instance:updateItems()
        end
    end, "未设置（使用 SimpleUI 单图标）", P, picker_key, true)
end

local function actionSettingsMenu(action_id, cfg, touchmenu_instance)
    local state, source = stateForConfig(cfg)
    local state_text = state == nil and "不可用" or (state and "开启" or "关闭")
    local function currentIcon(field)
        local settings = loadIconSettings()
        local icons = type(settings[action_id]) == "table" and settings[action_id] or {}
        return icons[field]
    end
    return {
        {
            text = "当前状态：" .. state_text .. "（" .. tostring(source) .. "）",
            enabled = false,
        },
        {
            text_func = function() return "开启图标：" .. iconLabel(currentIcon("icon_on")) end,
            keep_menu_open = true,
            callback = function()
                selectIcon(action_id, "icon_on", currentIcon("icon_on"), touchmenu_instance)
            end,
        },
        {
            text_func = function() return "关闭图标：" .. iconLabel(currentIcon("icon_off")) end,
            keep_menu_open = true,
            callback = function()
                selectIcon(action_id, "icon_off", currentIcon("icon_off"), touchmenu_instance)
            end,
        },
        {
            text = "清除双状态图标",
            enabled_func = function()
                return currentIcon("icon_on") ~= nil or currentIcon("icon_off") ~= nil
            end,
            keep_menu_open = true,
            callback = function()
                local all = loadIconSettings()
                all[action_id] = nil
                saveIconSettings(all)
                refreshSimpleUISurfaces()
                if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
                    touchmenu_instance:updateItems()
                end
                showMessage("已恢复使用 SimpleUI 原有单图标。")
            end,
        },
    }
end

local function boundActionsMenu(touchmenu_instance)
    local list = QA.getCustomQAList()
    local items = {}
    local relevant_ids = {}

    for _, action_id in ipairs(type(list) == "table" and list or {}) do
        local cfg = QA.getCustomQAConfig(action_id)
        if isBoundPluginOrSystem(cfg) then
            relevant_ids[action_id] = true
            local state, source = stateForConfig(cfg)
            local label = cfg.label or action_id
            local kind = cfg.plugin_key and "插件" or "系统操作"
            if state == nil then
                items[#items + 1] = {
                    text = label .. " — 仅单图标",
                    enabled = false,
                    help_text = kind .. "已绑定，但不支持双状态图标：" .. tostring(source),
                }
            else
                local configured = configuredPair(action_id) ~= nil
                local item_action_id = action_id
                local item_cfg = cfg
                items[#items + 1] = {
                    text = label .. " — " .. kind .. (configured and " ✓" or ""),
                    help_text = "状态来源：" .. tostring(source),
                    sub_item_table_func = function()
                        return actionSettingsMenu(item_action_id, item_cfg, touchmenu_instance)
                    end,
                }
            end
        end
    end

    local all_settings = loadIconSettings()
    local changed = false
    for action_id in pairs(all_settings) do
        if not relevant_ids[action_id] then
            all_settings[action_id] = nil
            changed = true
        end
    end
    if changed then saveIconSettings(all_settings) end

    if #items == 0 then
        items[1] = {
            text = "没有已绑定的插件或系统快捷动作",
            enabled = false,
            help_text = "请先在 SimpleUI 的快捷动作中绑定插件或系统操作。",
        }
    end
    return items
end

local function openSettingsMenu(touchmenu_instance)
    if not touchmenu_instance or type(touchmenu_instance.onMenuSelect) ~= "function" then
        showMessage("无法打开双状态图标设置菜单。")
        return
    end
    touchmenu_instance:onMenuSelect({
        text = "双状态图标设置",
        sub_item_table_func = function() return boundActionsMenu(touchmenu_instance) end,
    })
end

function P.apply()
    local ok_qa, qa = SimpleUICompat.tryRequire("quickactions")
    local ok_store, store = SimpleUICompat.tryRequire("store")
    if not ok_qa or not qa or not ok_store or not store then
        return false, "当前 SimpleUI 没有可用的快捷动作或设置 API"
    end
    if type(qa.getEntry) ~= "function" or type(qa.getCustomQAList) ~= "function"
            or type(qa.getCustomQAConfig) ~= "function"
            or type(qa.execute) ~= "function"
            or type(qa.executeCustomQA) ~= "function"
            or type(qa.showIconPicker) ~= "function" then
        return false, "当前 SimpleUI 快捷动作 API 不兼容（支持目标：2.5.0 / 2.6.x）"
    end

    QA = qa
    SUISettings = store
    installEntryWrapper()
    installExecuteWrapper()
    installQuickSettingsHook()
    P._applied = true
    logger.info("plugin_enhancements: configurable SimpleUI dual-state Quick Action icons enabled")
    return true
end

P.hold_callback = function(touchmenu_instance)
    if not P._applied or not QA or not SUISettings then
        showMessage("请先启用“快捷设置栏：双状态图标”，然后重启 KOReader。")
        return
    end
    openSettingsMenu(touchmenu_instance)
end

return P
