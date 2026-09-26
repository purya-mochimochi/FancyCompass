addon.name    = 'FancyCompass'
addon.author  = 'purya-mochi (Original: Arielfy)'
addon.version = '1.1'
addon.desc    = 'Compass, HUD radar, and tracker'
addon.link    = ''

require 'common'

local cos = math.cos
local sin = math.sin

local imgui    = require('imgui')
local settings = require('settings')
local pi       = math.pi
local gdi      = require('gdifonts.include')
local ffi      = require('ffi')
local d3d      = require('d3d8')

-- Helper modules
local camera      = require('lib.camera')
local vana        = require('lib.vana')
local grid        = require('lib.grid')
local weather     = require('lib.weather')
local color       = require('lib.color')
local chat_anchor = require('lib.chat_anchor')
local menu        = require('lib.menu')

-- =========================================================================
-- D3DX テクスチャローダー
-- =========================================================================
local d3d8dev = d3d.get_device()
ffi.cdef[[
    HRESULT __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture);
]]
local D3DX = ffi.C

local _act_tex   = {}
local _act_keep  = {}

local function load_activity_texture(name, filename)
    local ptr  = ffi.new('IDirect3DTexture8*[1]')
    local path = ('%s\\imgs\\textures\\%s'):format(addon.path, filename)
    if D3DX.D3DXCreateTextureFromFileA(d3d8dev, path, ptr) == 0 then
        local tex = ffi.new('IDirect3DTexture8*', ptr[0])
        d3d.gc_safe_release(tex)
        _act_keep[name] = tex
        _act_tex[name]  = tonumber(ffi.cast('uint32_t', tex))
    end
end

-- =========================================================================
-- GDI フォント設定 & 曜日テーブル
-- =========================================================================
local CLOCK_FONT_NAME = 'MyricaM M'
local day_font_obj    = nil
local clock_font_obj  = nil
local moon_font_obj   = nil
local fish_font_obj   = nil
local dig_font_obj    = nil

local JP_DAY_CHARS = {
    [0] = '火',
    [1] = '土',
    [2] = '水',
    [3] = '風',
    [4] = '氷',
    [5] = '雷',
    [6] = '光',
    [7] = '闇',
}

-- 属性カラー（純正風）
local JP_DAY_COLORS = {
    [0] = 0xFFFF4433, -- 火: 赤
    [1] = 0xFFDDAA44, -- 土: 黄土
    [2] = 0xFF3399FF, -- 水: 青
    [3] = 0xFF44EE55, -- 風: 緑
    [4] = 0xFF66FFFF, -- 氷: 水色
    [5] = 0xFFFF66FF, -- 雷: 紫
    [6] = 0xFFFFFF77, -- 光: 白黄
    [7] = 0xFF9966FF, -- 闇: 紫
}

local cfg

local INGAME_COMPASS_SIG  = '33C0668B81????????483DE3000000'
local ingame_compass_addr = 0
local ingame_compass_orig = nil
local patch_done = false
local login_time = 0

-- -------------------------------------------------------------------------
-- 月齢・釣果・チョコボ掘りデータ
-- -------------------------------------------------------------------------
local MOON_PHASE_INFO = {
    [0]  = { name = '新月',     fish = '︿',  fish_col = 0xFF55FF55, dig = '︽',  dig_col = 0xFF55FF55 },
    [1]  = { name = '三日月',   fish = '─',   fish_col = 0xFF888888, dig = '︿',  dig_col = 0xFF88FF88 },
    [2]  = { name = '七日月',   fish = '─',   fish_col = 0xFF888888, dig = '─',   dig_col = 0xFF888888 },
    [3]  = { name = '上弦の月', fish = '﹀',  fish_col = 0xFF7799FF, dig = '﹀',  dig_col = 0xFF7799FF },
    [4]  = { name = '十日夜',   fish = '─',   fish_col = 0xFF888888, dig = '─',   dig_col = 0xFF888888 },
    [5]  = { name = '十三夜',   fish = '─',   fish_col = 0xFF888888, dig = '︿',  dig_col = 0xFF88FF88 },
    [6]  = { name = '満月',     fish = '︿',  fish_col = 0xFF55FF55, dig = '︽',  dig_col = 0xFF55FF55 },
    [7]  = { name = '十六夜',   fish = '─',   fish_col = 0xFF888888, dig = '︿',  dig_col = 0xFF88FF88 },
    [8]  = { name = '居待月',   fish = '─',   fish_col = 0xFF888888, dig = '─',   dig_col = 0xFF888888 },
    [9]  = { name = '下弦の月', fish = '﹀',  fish_col = 0xFF7799FF, dig = '﹀',  dig_col = 0xFF7799FF },
    [10] = { name = '二十日余月', fish = '─', fish_col = 0xFF888888, dig = '─',   dig_col = 0xFF888888 },
    [11] = { name = '二十六夜', fish = '─',   fish_col = 0xFF888888, dig = '︿',  dig_col = 0xFF88FF88 },
}

local VANA_EPOCH_OFFSET = 92514960
local EARTH_SECONDS_PER_VANA_DAY = 3456

local function calculate_moon_data()
    local raw = os.time() + VANA_EPOCH_OFFSET
    local total_days = math.floor(raw / EARTH_SECONDS_PER_VANA_DAY)
    local cycle_days = 84
    local signed_percent = ((((total_days + 26) % cycle_days) - (cycle_days / 2)) / (cycle_days / 2)) * 100

    local phase = 0
    if signed_percent >= 7 and signed_percent <= 38 then
        phase = 1
    elseif signed_percent >= 40 and signed_percent <= 55 then
        phase = 2
    elseif signed_percent >= 57 and signed_percent <= 88 then
        phase = 5
    elseif signed_percent >= 90 or signed_percent <= -95 then
        phase = 6
    elseif signed_percent >= -93 and signed_percent <= -62 then
        phase = 7
    elseif signed_percent >= -60 and signed_percent <= -45 then
        phase = 9
    elseif signed_percent >= -43 and signed_percent <= -12 then
        phase = 11
    else
        phase = 0
    end

    local percent = math.floor(math.abs(signed_percent) + 0.5)
    local is_waxing = (signed_percent >= 0)
    return phase, percent, is_waxing
end

local function draw_moon_icon(dl, cx, cy, radius, phase, is_waxing)
    local col_bg    = 0xFF181510
    local col_light = 0xFFFF9922
    local col_edge  = 0xCC000000

    dl:AddCircleFilled({ cx, cy }, radius, col_bg, 24)

    if phase == 0 then
        dl:AddCircle({ cx, cy }, radius, col_edge, 24, 1.0)
        return
    elseif phase == 6 then
        dl:AddCircleFilled({ cx, cy }, radius, col_light, 24)
        dl:AddCircle({ cx, cy }, radius, col_edge, 24, 1.0)
        return
    end

    local segs = 16
    local start_ang = is_waxing and (-pi * 0.5) or (pi * 0.5)
    local end_ang   = is_waxing and (pi * 0.5)  or (pi * 1.5)
    dl:PathArcTo({ cx, cy }, radius, start_ang, end_ang, segs)
    dl:PathFillConvex(col_light)

    local p_norm = is_waxing and (phase / 6) or ((12 - phase) / 6)
    local k = (p_norm - 0.5) * 2.0
    local shadow_col = (k < 0) and col_bg or col_light

    dl:PathClear()
    for i = 0, segs do
        local theta = -pi * 0.5 + (pi * i / segs)
        local ex = cx + radius * math.abs(k) * math.cos(theta) * (is_waxing and 1 or -1)
        local ey = cy + radius * math.sin(theta)
        dl:PathLineTo({ ex, ey })
    end
    for i = segs, 0, -1 do
        local theta = -pi * 0.5 + (pi * i / segs)
        local ex = cx
        local ey = cy + radius * math.sin(theta)
        dl:PathLineTo({ ex, ey })
    end
    dl:PathFillConvex(shadow_col)
    dl:AddCircle({ cx, cy }, radius, col_edge, 24, 1.0)
end

local function init_ingame_compass_patch()
    ingame_compass_addr = ashita.memory.find('FFXiMain.dll', 0, INGAME_COMPASS_SIG, 0, 0)
    if ingame_compass_addr ~= 0 then
        ashita.memory.unprotect(ingame_compass_addr + 0x24, 1)
        local b = ashita.memory.read_uint8(ingame_compass_addr + 0x24)
        ingame_compass_orig = (b ~= 0) and b or 1
    end
end

local function apply_ingame_compass_patch(hide)
    if ingame_compass_addr == 0 or ingame_compass_orig == nil then return end
    ashita.memory.write_uint8(ingame_compass_addr + 0x24, hide and 0 or ingame_compass_orig)
end

local last_login_status = -1
local saw_lobby         = true

local function apply_clock_command(hide)
    if AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() ~= 2 then return end
    AshitaCore:GetChatManager():QueueCommand(-1, hide and '/clock off' or '/clock on')
end

local function check_login_for_clock()
    local s = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus()
    if s == 0 then saw_lobby = true end
    if login_time ~= 0 and os.clock() - login_time > 3 then
        AshitaCore:GetChatManager():QueueCommand(-1, '/clock off')
        apply_ingame_compass_patch(true)
        login_time = 0
    end
    if s == 2 and last_login_status ~= 2 and saw_lobby and cfg.hide_ingame then
        login_time = os.clock()
        saw_lobby = false
    end
    last_login_status = s
end

-- =========================================================================
-- 設定テーブルの初期値
-- =========================================================================
local default_cfg = T{
    x                = 42,
    y                = 562,
    radius           = 100,
    range            = 40,
    dot_size         = 3,
    clock_font_size  = 16,
    show_pets        = true,
    show_moon        = true,
    show_activities  = true,
    hide_ingame      = true,
    anchor_to_chat   = false,
    anchor_window    = 1,
    anchor_offset_x  = 0,
    anchor_offset_y  = -10,
    hide_on_menu     = true,
    tilt             = 0.45,
    color_isac_main  = 0xDD0080FF,
    color_isac_dark  = 0x44004088,
    color_isac_sub   = 0x88667788,
    color_n          = 0xFF00AAFF,
    color_card       = 0x99557788,
    color_stamp      = 0xFFFFFFFF,
    color_npc        = 0x2244DD44,
    color_pc         = 0x22FFAA33,
    color_mob        = 0x222233FF,
    color_pet        = 0x2244DDDD,
}

cfg = settings.load(default_cfg)
if cfg.hide_on_menu == nil then cfg.hide_on_menu = true end
if cfg.clock_font_size == nil then cfg.clock_font_size = 16 end
if cfg.show_moon == nil then cfg.show_moon = true end
if cfg.show_activities == nil then cfg.show_activities = true end

settings.register('settings', 'compass_settings_update', function(s)
    if s ~= nil then cfg = s end
    settings.save()
end)

local visible          = { true }
local force_pos        = true
local settings_visible = { false }
local SCAN_INTERVAL_S  = 0.05

local pets_cache        = {}
local entity_cache      = {}
local entity_cache_n    = 0
local entity_last_rebuild = -math.huge
local dots              = {}
local dots_n            = 0

local active_slots   = {}
local active_n       = 0
local active_set     = {}
local CHUNK_SIZE     = 192
local rescan_cursor  = 0

local CARDINALS = {
    { label = 'S', angle = 0          },
    { label = 'W', angle = pi / 2     },
    { label = 'N', angle = pi         },
    { label = 'E', angle = 3 * pi / 2 },
}

local function draw_vector_char(dl, char, cx, cy, sz, col, outline_col, thickness)
    local hw = sz * 0.4
    local hh = sz * 0.5
    local lines = {}
    if char == 'N' then
        lines = { { -hw, hh, -hw, -hh }, { -hw, -hh, hw, hh }, { hw, hh, hw, -hh } }
    elseif char == 'S' then
        lines = { { hw, -hh, -hw, -hh }, { -hw, -hh, -hw, 0 }, { -hw, 0, hw, 0 }, { hw, 0, hw, hh }, { hw, hh, -hw, hh } }
    elseif char == 'E' then
        lines = { { hw, -hh, -hw, -hh }, { -hw, -hh, -hw, hh }, { -hw, hh, hw, hh }, { -hw, 0, hw * 0.8, 0 } }
    elseif char == 'W' then
        lines = { { -hw, -hh, -hw * 0.5, hh }, { -hw * 0.5, hh, 0, -hh * 0.2 }, { 0, -hh * 0.2, hw * 0.5, hh }, { hw * 0.5, hh, hw, -hh } }
    end
    if outline_col and outline_col ~= 0 then
        for _, l in ipairs(lines) do
            dl:AddLine({ cx + l[1], cy + l[2] }, { cx + l[3], cy + l[4] }, outline_col, thickness + 2.0)
        end
    end
    for _, l in ipairs(lines) do
        dl:AddLine({ cx + l[1], cy + l[2] }, { cx + l[3], cy + l[4] }, col, thickness)
    end
end

-- -------------------------------------------------------------------------
-- Events
-- -------------------------------------------------------------------------
ashita.events.register('load', 'compass_load', function()
    camera.init()
    vana.init()
    grid.init()
    weather.init()
    chat_anchor.init()
    menu.init()
    init_ingame_compass_patch()

    load_activity_texture('fish', 'fish.png')
    load_activity_texture('dig',  'dig.png')

    gdi:set_auto_render(false)
    local f_size   = cfg.clock_font_size or 16
    local sub_size = math.max(11, math.floor(f_size * 0.78))

    -- 曜日漢字専用オブジェクト: 潰れを防ぐためフチを1pxに最適化
    day_font_obj = gdi:create_object({
        font_family = CLOCK_FONT_NAME, font_height = f_size, font_flags = gdi.FontFlags.Bold,
        font_color = 0xFFFFFFFF, outline_width = 1, outline_color = 0xFF000000, visible = true,
    }, false)

    clock_font_obj = gdi:create_object({
        font_family = CLOCK_FONT_NAME, font_height = f_size, font_flags = gdi.FontFlags.Bold,
        font_color = 0xFFFFFFFF, outline_width = 2, outline_color = 0xFF000000, visible = true,
    }, false)

    moon_font_obj = gdi:create_object({
        font_family = CLOCK_FONT_NAME, font_height = f_size, font_flags = gdi.FontFlags.Bold,
        font_color = 0xFFFFFFFF, outline_width = 2, outline_color = 0xFF000000, visible = true,
    }, false)

    fish_font_obj = gdi:create_object({
        font_family = CLOCK_FONT_NAME, font_height = sub_size, font_flags = gdi.FontFlags.Bold,
        font_color = 0xFFCCCCCC, outline_width = 2, outline_color = 0xFF000000, visible = true,
    }, false)

    dig_font_obj = gdi:create_object({
        font_family = CLOCK_FONT_NAME, font_height = sub_size, font_flags = gdi.FontFlags.Bold,
        font_color = 0xFFCCCCCC, outline_width = 2, outline_color = 0xFF000000, visible = true,
    }, false)

    last_login_status = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus()
end)

ashita.events.register('d3d_present', 'compass_present', function()
    check_login_for_clock()
    if last_login_status ~= 2 then return end
    if not patch_done then
        apply_ingame_compass_patch(cfg.hide_ingame)
        patch_done = true
        apply_clock_command(cfg.hide_ingame)
    end

    if not visible[1] or (cfg.hide_on_menu and menu.is_menu_open()) then
        if day_font_obj   then day_font_obj:set_visible(false)   end
        if clock_font_obj then clock_font_obj:set_visible(false) end
        if moon_font_obj  then moon_font_obj:set_visible(false)  end
        if fish_font_obj  then fish_font_obj:set_visible(false)  end
        if dig_font_obj   then dig_font_obj:set_visible(false)   end
        return
    end

    local heading     = camera.get_heading()
    local r           = cfg.radius
    local size_scale  = r / 66
    local pad         = 24 * size_scale
    local outer_reach = r * cfg.range / 25
    local sz          = (outer_reach + pad) * 2

    chat_anchor.poll()
    local raw = cfg.anchor_to_chat and chat_anchor.get(cfg.anchor_window) or nil
    local anchor
    if raw then
        anchor = { x = raw.x, y = (raw.visible == 1) and (raw.y - (raw.extra or 0)) or (raw.y + raw.h) }
    end

    local effective_x = anchor and (anchor.x + cfg.anchor_offset_x - (sz * 0.5 - r - 16 * size_scale)) or cfg.x
    local effective_y = anchor and (anchor.y + cfg.anchor_offset_y - (sz * 0.5 + r * cfg.tilt + 15)) or cfg.y

    if anchor or force_pos then
        imgui.SetNextWindowPos({ effective_x, effective_y }, ImGuiCond_Always)
        if not anchor then force_pos = false end
    else
        imgui.SetNextWindowPos({ effective_x, effective_y }, ImGuiCond_FirstUseEver)
    end
    imgui.SetNextWindowSize({ sz, sz + 140 }, ImGuiCond_Always)
    imgui.SetNextWindowBgAlpha(0.0)

    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    if imgui.Begin('##compass', visible, ImGuiWindowFlags_NoDecoration + ImGuiWindowFlags_NoNav) then
        local dl       = imgui.GetWindowDrawList()
        local wpx, wpy = imgui.GetWindowPos()
        if not anchor then cfg.x, cfg.y = math.floor(wpx), math.floor(wpy) end

        local cx   = wpx + sz * 0.5
        local cy   = wpy + sz * 0.5
        local tilt = cfg.tilt

        local C_ORANGE = cfg.color_isac_main or 0xDD0080FF
        local C_DARK   = cfg.color_isac_dark or 0x44004088
        local C_SUB    = cfg.color_isac_sub  or 0x88667788
        local C_CARD   = cfg.color_card      or 0x99557788
        local C_N      = cfg.color_n         or 0xFF00AAFF

        -- 多重同心円スキャンサークル
        local segs = 64
        local function draw_oval(radius, col, thick)
            local px, py = cx + radius, cy
            for i = 1, segs do
                local th = (i / segs) * 2 * pi
                local nx = cx + radius * math.cos(th)
                local ny = cy + radius * math.sin(th) * tilt
                dl:AddLine({ px, py }, { nx, ny }, col, thick or 1.0)
                px, py = nx, ny
            end
        end

        draw_oval(r * 0.28, C_DARK, 1.0)
        draw_oval(r * 0.50, C_SUB,  1.0)
        draw_oval(r * 0.75, C_DARK, 1.2)
        draw_oval(r * 1.00, C_DARK, 1.5)
        draw_oval(r * 1.14, C_DARK, 1.0)

        -- メインの分割太アークリング (北を軸に同期)
        local arc_segs  = 16
        local arc_r     = r * 0.88
        local arc_thick = math.max(3.5, 4.5 * size_scale)
        local north_a   = (pi * 0.5) - heading
        local arc_gaps = {
            { start_a = north_a - pi * 0.42, end_a = north_a - pi * 0.12 },
            { start_a = north_a + pi * 0.12, end_a = north_a + pi * 0.42 },
            { start_a = north_a + pi * 0.60, end_a = north_a + pi * 1.40 },
        }
        for _, arc in ipairs(arc_gaps) do
            dl:PathClear()
            for i = 0, arc_segs do
                local a = arc.start_a + (arc.end_a - arc.start_a) * (i / arc_segs)
                dl:PathLineTo({ cx + arc_r * math.cos(a), cy + arc_r * math.sin(a) * tilt })
            end
            dl:PathStroke(C_ORANGE, false, arc_thick)
        end

        -- 最外周の精密スリット・ノッチ目盛り
        local slit_r_in  = r * 1.08
        local slit_r_out = r * 1.14
        local num_slits  = 72
        for i = 0, num_slits - 1 do
            local a = -heading + (i / num_slits) * 2 * pi
            local ca, sa = math.cos(a), math.sin(a)
            local is_major = (i % 6 == 0)
            local rin = is_major and (r * 1.05) or slit_r_in
            local col = is_major and C_ORANGE or C_SUB
            local th  = is_major and 1.8 or 1.0
            dl:AddLine({ cx + rin * ca, cy + rin * sa * tilt },
                       { cx + slit_r_out * ca, cy + slit_r_out * sa * tilt }, col, th)
        end

        -- 方位文字 (N, S, E, W)
        local char_size = 13 * size_scale
        for _, card in ipairs(CARDINALS) do
            local screen_a = card.angle - heading - (pi / 2)
            local lr       = r * 1.25
            local lx       = cx + lr * math.cos(screen_a)
            local ly       = cy + lr * math.sin(screen_a) * tilt
            local col      = (card.label == 'N') and C_N or C_CARD
            draw_vector_char(dl, card.label, lx, ly, char_size, col, 0xCC000000, 1.8)
        end

        -- Entity レーダードット
        local mm = AshitaCore:GetMemoryManager()
        local em = mm:GetEntity()
        local party = mm:GetParty()
        local p_idx = party:GetMemberTargetIndex(0)
        if p_idx ~= 0 then
            local p_x, p_y = em:GetLocalPositionX(p_idx), em:GetLocalPositionY(p_idx)
            local range    = cfg.range
            local r_sq     = range * range
            local pos_scale = r / 25

            local _now = os.clock()
            if _now - entity_last_rebuild >= SCAN_INTERVAL_S then
                entity_last_rebuild = _now
                local last = math.min(2303, rescan_cursor + CHUNK_SIZE - 1)
                for idx = rescan_cursor, last do
                    if idx ~= p_idx and not active_set[idx] and em:GetServerId(idx) ~= 0 then
                        active_n = active_n + 1
                        active_slots[active_n] = idx
                        active_set[idx] = true
                    end
                end
                rescan_cursor = (last >= 2303) and 0 or (last + 1)

                for k in pairs(pets_cache) do pets_cache[k] = nil end
                for ai = 1, active_n do
                    local pet_idx = em:GetPetTargetIndex(active_slots[ai])
                    if pet_idx ~= 0 then pets_cache[pet_idx] = true end
                end

                entity_cache_n = 0
                local write_back = 0
                for ai = 1, active_n do
                    local idx = active_slots[ai]
                    if em:GetServerId(idx) == 0 then
                        active_set[idx] = nil
                    else
                        write_back = write_back + 1
                        active_slots[write_back] = idx
                        local rf = em:GetRenderFlags0(idx)
                        if bit.band(rf, 0x200) == 0x200 and bit.band(rf, 0x4000) == 0 and em:GetName(idx) ~= '' then
                            local et = em:GetType(idx)
                            local rgb, edge_a
                            local is_pet = pets_cache[idx] or (em:GetTrustOwnerTargetIndex(idx) ~= 0)
                            if is_pet then
                                if cfg.show_pets then rgb, edge_a = cfg.color_pet % 0x1000000, 0xDD end
                            elseif et <= 2 then
                                local sf = em:GetSpawnFlags(idx)
                                if bit.band(sf, 0x10) ~= 0 then
                                    rgb, edge_a = cfg.color_mob % 0x1000000, 0xFF
                                elseif et == 0 and bit.band(sf, 0x01) ~= 0 then
                                    rgb, edge_a = cfg.color_pc % 0x1000000, 0xFF
                                elseif bit.band(sf, 0x02) ~= 0 then
                                    rgb, edge_a = cfg.color_npc % 0x1000000, 0xFF
                                end
                            end
                            if rgb ~= nil then
                                entity_cache_n = entity_cache_n + 1
                                local e = entity_cache[entity_cache_n] or {}
                                e.dx = em:GetLocalPositionX(idx) - p_x
                                e.dy = em:GetLocalPositionY(idx) - p_y
                                e.rgb, e.edge_a = rgb, edge_a
                                entity_cache[entity_cache_n] = e
                            end
                        end
                    end
                end
                for k = write_back + 1, active_n do active_slots[k] = nil end
                active_n = write_back
            end

            dots_n = 0
            local dot_r = cfg.dot_size * size_scale
            for i = 1, entity_cache_n do
                local e = entity_cache[i]
                local d_sq = e.dx * e.dx + e.dy * e.dy
                if d_sq <= r_sq then
                    local dist  = math.sqrt(d_sq)
                    local sa    = math.atan2(-e.dx, -e.dy) - heading - (pi / 2)
                    local pd    = dist * pos_scale
                    local alpha = math.floor(0xFF - (0xFF - e.edge_a) * (dist / range))
                    dots_n = dots_n + 1
                    local d = dots[dots_n] or {}
                    d.x = cx + pd * math.cos(sa)
                    d.y = cy + pd * math.sin(sa) * tilt
                    d.color = alpha * 0x1000000 + e.rgb
                    dots[dots_n] = d
                end
            end
            for i = 1, dots_n do
                dl:AddCircleFilled({ dots[i].x, dots[i].y }, dot_r, dots[i].color)
            end
        end

        -- 天候アイコン
        do
            local elem, count = weather.get_current()
            local tex = elem and weather.get_texture(elem) or nil
            if tex ~= nil and count > 0 then
                local isz = 18 * size_scale
                local row_y = cy - r * tilt - isz - 12 * size_scale
                local x = cx - r - 16 * size_scale
                for j = 1, count do
                    dl:AddImage(tex, { x, row_y }, { x + isz, row_y + isz }, { 0, 0 }, { 1, 1 }, 0xCCFFFFFF)
                    x = x + isz + 2
                end
            end
        end

        -- 北(N) ゲートミニ三角
        do
            local tri_r = r * 0.96
            local tri_sz = 3.5 * size_scale
            local tip_x = cx + tri_r * math.cos(north_a)
            local tip_y = cy + tri_r * math.sin(north_a) * tilt
            local base_r = tri_r - tri_sz * 1.6
            local p1_a = north_a - 0.05
            local p2_a = north_a + 0.05
            dl:AddTriangleFilled(
                { tip_x, tip_y },
                { cx + base_r * math.cos(p1_a), cy + base_r * math.sin(p1_a) * tilt },
                { cx + base_r * math.cos(p2_a), cy + base_r * math.sin(p2_a) * tilt },
                C_ORANGE
            )
        end

        -- 自キャラ正面ポインター
        do
            local ptr_in  = r * 0.28
            local ptr_out = r * 0.44
            dl:AddLine({ cx, cy - ptr_in * tilt }, { cx, cy - ptr_out * tilt }, C_ORANGE, 1.6)
        end

        -- =================================================================
        -- 下部ステータス表示 (純正風: 漢字 + 属性アーク)
        -- =================================================================
        local vana_time, vana_day = vana.get_time()
        local sh        = cfg.clock_font_size or 16
        local sub_h     = math.max(12, math.floor(sh * 0.78))
        local line_gap  = 4 * size_scale
        local left_edge = cx - r - 16 * size_scale
        local row_top   = cy + r * tilt + 14 * size_scale + 7

        local day_char  = JP_DAY_CHARS[vana_day] or '火'
        local day_col   = JP_DAY_COLORS[vana_day] or 0xFFFF4433

        -- 1. 曜日漢字
        if day_font_obj then
            day_font_obj:set_visible(true)
            day_font_obj:set_position_x(left_edge)
            day_font_obj:set_position_y(row_top)
            day_font_obj:set_text(day_char)
            day_font_obj:set_font_color(0xFFFFFFFF)
        end

        -- 2. 純正風: 三日月弧（アーク）
        local kanji_w = sh * 0.95
        local arc_cx  = left_edge + kanji_w + 3
        local arc_cy  = row_top + sh * 0.52
        local arc_rad = sh * 0.38

        dl:PathClear()
        dl:PathArcTo({ arc_cx, arc_cy }, arc_rad, -pi * 0.45, pi * 0.45, 12)
        dl:PathStroke(day_col, false, 2.5)

        -- 3. ヴァナ時間・座標
        local stamp_x = arc_cx + arc_rad + 6
        if clock_font_obj then
            clock_font_obj:set_visible(true)
            clock_font_obj:set_position_x(stamp_x)
            clock_font_obj:set_position_y(row_top)
            clock_font_obj:set_text(('%s (%s)'):format(vana_time, grid.get_coords()))
            clock_font_obj:set_font_color(cfg.color_stamp)
        end

        local next_y = row_top + sh + line_gap

        -- 2行目: 月アイコン + 月齢テキスト (cfg.show_moon でトグル)
        local moon_phase, moon_pct, is_waxing = calculate_moon_data()
        local m_info    = MOON_PHASE_INFO[moon_phase] or MOON_PHASE_INFO[0]
        local trend_str = is_waxing and '︿' or '﹀'

        if cfg.show_moon then
            draw_moon_icon(dl, left_edge + 7, next_y + sub_h * 0.5, 6, moon_phase, is_waxing)
            if moon_font_obj then
                moon_font_obj:set_visible(true)
                moon_font_obj:set_position_x(left_edge + 18)
                moon_font_obj:set_position_y(next_y)
                moon_font_obj:set_text(('%s %d%% (%s)'):format(m_info.name, moon_pct, trend_str))
            end
            next_y = next_y + sub_h + line_gap
        else
            if moon_font_obj then moon_font_obj:set_visible(false) end
        end

        -- 3行目 & 4行目: 釣り・チョコボ掘り (cfg.show_activities でトグル)
        if cfg.show_activities then
            local tex_fish = _act_tex['fish']
            local icon_dim = sub_h + 2
            if tex_fish then
                dl:AddImage(tex_fish, { left_edge + 2, next_y }, { left_edge + 2 + icon_dim, next_y + icon_dim })
            end
            if fish_font_obj then
                fish_font_obj:set_visible(true)
                fish_font_obj:set_position_x(left_edge + 18)
                fish_font_obj:set_position_y(next_y)
                fish_font_obj:set_text(m_info.fish)
                fish_font_obj:set_font_color(m_info.fish_col)
            end
            next_y = next_y + sub_h + line_gap

            local tex_dig = _act_tex['dig']
            if tex_dig then
                dl:AddImage(tex_dig, { left_edge + 2, next_y }, { left_edge + 2 + icon_dim, next_y + icon_dim })
            end
            if dig_font_obj then
                dig_font_obj:set_visible(true)
                dig_font_obj:set_position_x(left_edge + 18)
                dig_font_obj:set_position_y(next_y)
                dig_font_obj:set_text(m_info.dig)
                dig_font_obj:set_font_color(m_info.dig_col)
            end
        else
            if fish_font_obj then fish_font_obj:set_visible(false) end
            if dig_font_obj  then dig_font_obj:set_visible(false)  end
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end)

-- =========================================================================
-- 設定ウィンドウの描画処理
-- =========================================================================
ashita.events.register('d3d_present', 'compass_settings_ui', function()
    if not settings_visible[1] then return end

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 12, 10 })
    if imgui.Begin('FancyCompass Settings', settings_visible, ImGuiWindowFlags_AlwaysAutoResize) then
        local changed   = false
        local col_x     = 220
        local widget_w  = 340

        imgui.Text('General Layout')
        imgui.Separator()

        imgui.Text('Size (Radius)')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_size = { cfg.radius }
        if imgui.SliderInt('##size', v_size, 20, 200) then
            cfg.radius = v_size[1]; changed = true
        end

        imgui.Text('Tilt Perspective')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_tilt = { cfg.tilt }
        if imgui.SliderFloat('##tilt', v_tilt, 0.1, 1.0, '%.2f') then
            cfg.tilt = v_tilt[1]; changed = true
        end

        imgui.Text('Radar Dot Size')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_dot = { cfg.dot_size }
        if imgui.SliderFloat('##dotsize', v_dot, 1.0, 10.0, '%.1f') then
            cfg.dot_size = v_dot[1]; changed = true
        end

        imgui.Text('Clock Font Size')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_cfont = { cfg.clock_font_size or 16 }
        if imgui.SliderInt('##clockfontsize', v_cfont, 10, 36) then
            cfg.clock_font_size = v_cfont[1]
            local sub_s = math.max(11, math.floor(cfg.clock_font_size * 0.78))
            if day_font_obj   then day_font_obj:set_font_height(cfg.clock_font_size) end
            if clock_font_obj then clock_font_obj:set_font_height(cfg.clock_font_size) end
            if moon_font_obj  then moon_font_obj:set_font_height(cfg.clock_font_size) end -- ここを cfg.clock_font_size に
            if fish_font_obj  then fish_font_obj:set_font_height(sub_s) end
            if dig_font_obj   then dig_font_obj:set_font_height(sub_s) end
            changed = true
        end

        if imgui.Checkbox('Show pets and trusts', { cfg.show_pets }) then
            cfg.show_pets = not cfg.show_pets; changed = true
        end

        if imgui.Checkbox('Show moon phase', { cfg.show_moon }) then
            cfg.show_moon = not cfg.show_moon; changed = true
        end

        if imgui.Checkbox('Show activities (Fishing & Digging)', { cfg.show_activities }) then
            cfg.show_activities = not cfg.show_activities; changed = true
        end

        if imgui.Checkbox('Hide standard in-game compass', { cfg.hide_ingame }) then
            cfg.hide_ingame = not cfg.hide_ingame
            apply_ingame_compass_patch(cfg.hide_ingame)
            apply_clock_command(cfg.hide_ingame)
            changed = true
        end

        imgui.Spacing()
        imgui.Text('Chat Anchor')
        imgui.Separator()
        if imgui.Checkbox('Anchor to FancyChat', { cfg.anchor_to_chat }) then
            cfg.anchor_to_chat = not cfg.anchor_to_chat; changed = true
        end
        imgui.SameLine()
        imgui.TextDisabled('[' .. chat_anchor.status() .. ']')

        imgui.Text('Chat window index')
        imgui.SameLine(); imgui.SetCursorPosX(col_x)
        if imgui.RadioButton('Window 1##aw1', cfg.anchor_window == 1) then
            cfg.anchor_window = 1; changed = true
        end
        imgui.SameLine()
        if imgui.RadioButton('Window 2##aw2', cfg.anchor_window == 2) then
            cfg.anchor_window = 2; changed = true
        end

        imgui.Text('Anchor Offset X')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_aox = { cfg.anchor_offset_x }
        if imgui.SliderInt('##anchorox', v_aox, -400, 400) then
            cfg.anchor_offset_x = v_aox[1]; changed = true
        end

        imgui.Text('Anchor Offset Y')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_aoy = { cfg.anchor_offset_y }
        if imgui.SliderInt('##anchoroy', v_aoy, -400, 400) then
            cfg.anchor_offset_y = v_aoy[1]; changed = true
        end

        if changed then settings.save() end
    end
    imgui.End()
    imgui.PopStyleVar(1)
end)

ashita.events.register('d3d_endscene', 'compass_endscene', function(isRenderingBackBuffer)
    if not isRenderingBackBuffer then return end
    if clock_font_obj and clock_font_obj.settings.visible then gdi:render() end
end)

ashita.events.register('unload', 'compass_unload', function()
    settings.save()
    apply_ingame_compass_patch(false)
    apply_clock_command(false)
    chat_anchor.shutdown()
    day_font_obj   = nil
    clock_font_obj = nil
    moon_font_obj  = nil
    fish_font_obj  = nil
    dig_font_obj   = nil
    for k in pairs(_act_keep) do _act_keep[k] = nil end
    for k in pairs(_act_tex) do _act_tex[k] = nil end
    gdi:destroy_interface()
end)

-- =========================================================================
-- コマンド処理
-- =========================================================================
ashita.events.register('command', 'compass_command', function(e)
    local cmd = e.command:lower()
    local args = cmd:args()
    if args[1] ~= '/fancycompass' and args[1] ~= '/fcompass' then return end

    local sub = args[2]

    if sub == nil or sub == 'config' or sub == 'settings' or sub == 'menu' then
        settings_visible[1] = not settings_visible[1]
        print(('[fancycompass] Settings GUI: %s'):format(settings_visible[1] and 'Opened' or 'Closed'))
        e.blocked = true
        return
    end

    if sub == 'toggle' or sub == 'show' or sub == 'hide' then
        visible[1] = not visible[1]
        print(('[fancycompass] Compass: %s'):format(visible[1] and 'Shown' or 'Hidden'))
        e.blocked = true
        return
    end

    if sub == 'move' and args[3] and args[4] then
        local nx = tonumber(args[3])
        local ny = tonumber(args[4])
        if nx and ny then
            cfg.anchor_to_chat = false
            cfg.x, cfg.y = math.floor(nx), math.floor(ny)
            force_pos = true
            settings.save()
            print(('[fancycompass] Position set to: %d, %d (Chat anchor disabled)'):format(cfg.x, cfg.y))
        else
            print('[fancycompass] Invalid coordinates. Usage: /fcompass move <x> <y>')
        end
        e.blocked = true
        return
    end

    if sub == 'size' and args[3] then
        local ns = tonumber(args[3])
        if ns then
            cfg.radius = math.max(15, math.min(200, math.floor(ns)))
            settings.save()
            print(('[fancycompass] Radius set to: %d'):format(cfg.radius))
        else
            print('[fancycompass] Invalid size. Usage: /fcompass size <20-200>')
        end
        e.blocked = true
        return
    end

    print('[fancycompass] Commands:')
    print('  /fcompass (or /fcompass config) : Toggle Settings GUI')
    print('  /fcompass move <x> <y>          : Move to coordinates (Disables chat anchor)')
    print('  /fcompass size <radius>         : Change compass radius (20 - 200)')
    print('  /fcompass toggle                : Show/Hide compass')
    e.blocked = true
end)
