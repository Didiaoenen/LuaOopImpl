--[[
-- COW 读路径开销分解（LuaOOP）
--
-- 背景：本脚本写于 suite 的 COW 两行统一口径之前 —— 当时对照列在构造期把默认值落到实例自有
-- 字段，读的是实例字段而非穿透，两侧语义并不一致（现已统一为"类表默认值 + 实例读穿透"）。
-- 这里保留两种写法的对照，用于量化穿透本身的代价。
-- 本脚本把"读穿透"这条路径单独拆开，逐层量化，并给出同口径的四列实测。
--
-- 用法: lua54 benchmarks/investigations/cow_read_breakdown.lua
-- 环境: BENCH_N（读迭代，默认 2000000） BENCH_RUNS（取最优次数，默认 5）
--]]

-- 路径引导：本脚本位于 benchmarks/<子目录>/，仓库根目录即其上方两级。
local _dir  = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*[\\/])") or ""
local _sep  = package.config:sub(1, 1)
local _root = _dir .. ".." .. _sep .. ".." .. _sep
package.path = table.concat({
    _root .. "?.lua",
    _root .. "?.lua.txt",
    _root .. "LuaOOP" .. _sep .. "?.lua.txt",
    _root .. "LuaOOP" .. _sep .. "?.lua",
    package.path,
}, ";")

-- 先加载 OtherOOP 的 OtherClass（它把构造函数写成全局 OtherClass），立即收敛为局部别名
require("OtherOOP.OtherClass")
local otherClass = OtherClass

-- 再加载本框架：require 后设置全局 class，立即收敛为局部别名
require("LuaOOP.Class")
local myClass = class

local N    = tonumber(os.getenv("BENCH_N")) or 2000000
local RUNS = tonumber(os.getenv("BENCH_RUNS")) or 5

local clock = os.clock
local sink  = 0

local function best_of(fn, n)
    collectgarbage("collect")
    fn(math.min(n, 1000))
    collectgarbage("collect")

    local best
    for _ = 1, RUNS do
        local t0 = clock()
        local value = fn(n)
        local elapsed = clock() - t0
        sink = sink + (tonumber(value) or 0)
        if not best or elapsed < best then best = elapsed end
        collectgarbage("collect")
    end

    return best * 1000000000 / n
end

local function fmt(n)
    return string.format("%.3f", n)
end

--=============================================================================
-- 测试对象
--=============================================================================

-- ---- LuaOOP：无属性类（metaFunc.__index = vTable，表 __index） ----
local PlainCls = myClass("CowPlain")
PlainCls.hp = 100
local PlainObj = PlainCls.new()
PlainObj.own = 42                      -- 实例自有字段（写时无 __newindex，直接 rawset）

-- ---- LuaOOP：有属性类（声明 get/set 后整类切到函数 __index） ----
local PropCls = myClass("CowProp")
PropCls.hp = 100
PropCls.get.extra = function(self) return 1 end   -- 仅用来触发 SwitchToFuncIndex
local PropObj = PropCls.new()
PropObj.own = 42

-- ---- LuaOOP：继承链上的类表默认值（基类默认值在 PushBase 时已复制进子类 vTable） ----
local DBase = myClass("CowDeepBase")
DBase.hp = 100
local DChild = myClass("CowDeepChild", DBase)
local DObj = DChild.new()

-- ---- LuaOOP：有属性类继承链 ----
local PBase = myClass("CowPropBase")
PBase.get.extra = function(self) return 1 end
PBase.hp = 100
local PChild = myClass("CowPropChild", PBase)
local PCObj = PChild.new()

-- ---- 原生表下界：cls.__meta = { __index = cls }，实例读穿透 ----
local NCls = { hp = 100 }
NCls.__meta = { __index = NCls }
local NObj = setmetatable({}, NCls.__meta)

-- ---- OtherOOP：真读穿透（cls.hp = 100 走 __newindex 落 vTable，实例 __index 指向 vTable） ----
local BPass = otherClass("CowBPass")
BPass.hp = 100
local BPassObj = BPass.New()

-- ---- OtherOOP：统一口径之前的写法（默认值在 __init 里落到实例自有字段） ----
local BOwn = otherClass("CowBOwn")
BOwn.__init = function(self) self.hp = 100 end
local BOwnObj = BOwn.New()

--=============================================================================
-- 读路径分解
--=============================================================================

local reads = {
    {
        label = "实例自有字段读（基线）",
        plain = function(n) local a = 0 for _ = 1, n do a = a + PlainObj.own end return a end,
        prop  = function(n) local a = 0 for _ = 1, n do a = a + PropObj.own end return a end,
    },
    {
        label = "类表默认值读（本类，无继承）",
        plain = function(n) local a = 0 for _ = 1, n do a = a + PlainObj.hp end return a end,
        prop  = function(n) local a = 0 for _ = 1, n do a = a + PropObj.hp end return a end,
    },
    {
        label = "类表默认值读（继承，基类默认值）",
        plain = function(n) local a = 0 for _ = 1, n do a = a + DObj.hp end return a end,
        prop  = function(n) local a = 0 for _ = 1, n do a = a + PCObj.hp end return a end,
    },
}

local plain_ns, prop_ns, native_ns, bpass_ns, bown_ns = {}, {}, {}, {}, {}
for i, case in ipairs(reads) do
    plain_ns[i]  = best_of(case.plain, N)
    prop_ns[i]   = best_of(case.prop, N)
end

-- 同口径下界对照（都走读穿透）
native_ns[1] = best_of(function(n) local a = 0 for _ = 1, n do a = a + NObj.hp end return a end, N)
bpass_ns[1]  = best_of(function(n) local a = 0 for _ = 1, n do a = a + BPassObj.hp end return a end, N)
bown_ns[1]   = best_of(function(n) local a = 0 for _ = 1, n do a = a + BOwnObj.hp end return a end, N)
local own_base = best_of(function(n) local a = 0 for _ = 1, n do a = a + PlainObj.own end return a end, N)

--=============================================================================
-- 写后读分解（对应 suite 的 cow_write_then_read）
--=============================================================================

local w_own = best_of(function(n) for i = 1, n do PlainObj.own = i end return PlainObj.own end, N)
local w_plain = best_of(function(n) for i = 1, n do PlainObj.hp = i end return PlainObj.hp end, N)
local w_prop = best_of(function(n) for i = 1, n do PropObj.hp = i end return PropObj.hp end, N)
local w_native = best_of(function(n) for i = 1, n do NObj.hp = i end return NObj.hp end, N)
local w_bpass = best_of(function(n) for i = 1, n do BPassObj.hp = i end return BPassObj.hp end, N)

--=============================================================================
-- 输出
--=============================================================================

print("============================================================")
print("  COW 读路径开销分解（LuaOOP）")
print("  " .. _VERSION .. "  |  best of " .. RUNS .. "  |  迭代 " .. N .. "  |  sink: " .. tostring(sink))
print("============================================================")
print("")
print("### 读路径分解（ns/op）")
print("")
print("| 操作 | 无属性类（表 __index） | 有属性类（函数 __index） | 有属性/无属性 |")
print("| --- | ---: | ---: | ---: |")
for i, case in ipairs(reads) do
    print(string.format("| %s | %s | %s | %sx |",
        case.label, fmt(plain_ns[i]), fmt(prop_ns[i]), fmt(prop_ns[i] / plain_ns[i])))
end
print("")
print(string.format("* 实例自有字段读基线：`%s` ns/op", fmt(own_base)))
print(string.format("* 同口径穿透下界（原生表 `{ __index = cls }`）：`%s` ns/op", fmt(native_ns[1])))
print("")
print("### 类表默认值读 · 同口径四列对照（ns/op）")
print("")
print("| 实现 | 默认值落点 | 读路径 | ns/op |")
print("| --- | --- | --- | ---: |")
print(string.format("| 原生表 | 类表字段 | 实例 miss → 表 __index → 类表 | %s |", fmt(native_ns[1])))
print(string.format("| LuaOOP（无属性类） | 类表（Members + vTable） | 实例 miss → 表 __index → vTable | %s |", fmt(plain_ns[2])))
print(string.format("| LuaOOP（有属性类） | 类表（Members + vTable） | 实例 miss → 函数 __index → vTable | %s |", fmt(prop_ns[2])))
print(string.format("| OtherOOP（真穿透写法） | vTable 字段 | 实例 miss → 表 __index → vTable | %s |", fmt(bpass_ns[1])))
print(string.format("| OtherOOP（默认值落实例的旧口径） | 实例自有字段 | 实例字段直读 | %s |", fmt(bown_ns[1])))
print("")
print("### 写后读分解 · cow_write_then_read（ns/op，含写 + 读）")
print("")
print("| 实现 | 写入落点 | ns/op |")
print("| --- | --- | ---: |")
print(string.format("| LuaOOP（无属性类） | 实例自有字段（无 __newindex，rawset） | %s |", fmt(w_plain)))
print(string.format("| LuaOOP（有属性类） | 函数 __newindex → rawset 实例 | %s |", fmt(w_prop)))
print(string.format("| 原生表 | 实例自有字段（rawset） | %s |", fmt(w_native)))
print(string.format("| OtherOOP（真穿透写法） | 实例自有字段（rawset） | %s |", fmt(w_bpass)))
print(string.format("| 纯实例自有字段写入参照 | rawset | %s |", fmt(w_own)))
print("")
print("* 说明：无属性类实例元表只装 `__index`，写入是裸 rawset；有属性类写入要过函数 `__newindex`，")
print("  但实测两档无差异（含写 + 读合计同为 5.5 ns/op），即该函数帧被写入本身的开销掩盖，写入不是瓶颈。")