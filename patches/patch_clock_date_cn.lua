-- patches/patch_clock_date_cn.lua — SimpleUI Extra Modules
-- Replaces module_clock's _localDate() with a Chinese-format date.
--
-- Original 2.1/2.5: "Wednesday, 3 June"
-- Desktop 2.6 CN:    "星期三, 6月3日"
-- Patched:           "2025年 6月3日 星期三"
--
-- IMPLEMENTATION
-- The patch works by hotfix, it replace function by debug.setupvalue.
--

local logger = require "logger"
local hotfix = require "utils/hotfix"
local _      = require("plugin_enhancements_i18n").translate
local SimpleUICompat = require("utils/simpleui_compat")


local P = {
    id              = "clock_date_cn",
    name            = "时钟模块：中文日期格式支持",
    description     = _([[Shows the homescreen clock date as "2025年 6月3日 星期三" instead of "Wednesday, 3 June"]]),
    default_enabled = false,
}

local _CN_WDAY = { "日", "一", "二", "三", "四", "五", "六" }

local function _localDateCN()
    local t = os.date("*t", os.time())
    if not t or not t.day then return os.date "%m月%d日" end
    local w = _CN_WDAY[t.wday] or "??"
    return string.format("%d年 %d月%d日 星期%s", t.year, t.month, t.day, w)
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------
local _applied = false

function P.apply()
    if _applied then return true end
    _applied = true

    local ok, ClockMod = SimpleUICompat.tryRequire("clock")
    if not ok then
        local reason = "failed to load module_clock"
        logger.warn("simpleui_ext/patch_clock_date_cn: " .. reason)
        return false, reason
    end

    local err = hotfix(_localDateCN, ClockMod.build, "build -> _localDate")
    if err then
        logger.warn("simpleui_ext/patch_clock_date_cn: failed to apply hotfix: " .. err)
        return false, err
    end

    logger.info "simpleui_ext/patch_clock_date_cn: applied patch"
    return true
end

return P
