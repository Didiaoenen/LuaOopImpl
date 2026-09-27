--[[
-- LuaOOP 双模式对比基准：无属性类（表 __index） vs 有属性类（函数 __index）
--
-- 目的：量化"声明 get/set/opt 属性后整类切换到函数 __index"对各类访问路径的影响。
-- 关键点：切换是"整类"级别的——有属性类的普通字段/方法访问也会走函数闭包，
--         不再享受表 __index 的 C 层查找，本脚本把这部分代价单独测出来。
--
-- 用法: lua54 benchmarks/investigations/index_mode_compare.lua
--]]

-- 路径引导：本脚本位于 benchmarks/<子目录>/，仓库根目录即其上方两级。
-- 按脚本自身位置解析，从任意工作目录运行结果一致（不依赖 CWD 的 ./?.lua）。
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

-- 本框架：require 后设置全局 class，这里立即收敛为局部别名，避免与其他实现冲突
require("LuaOOP.Class")
local myClass = class

local FAST_N   = tonumber(os.getenv("BENCH_N")) or 1000000
local CREATE_N = tonumber(os.getenv("BENCH_CREATE_N")) or 100000
local RUNS     = tonumber(os.getenv("BENCH_RUNS")) or 3

local clock = os.clock
local sink = 0

local function fmt_number(n)
    local s = tostring(math.floor(n + 0.5))
    local left, num, right = s:match("^([^%d]*%d)(%d*)(.-)$")
    if not left then
        return s
    end
    return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

local function fmt_float(n, digits)
    return string.format("%." .. digits .. "f", n)
end

local function best_of(iterations, fn)
    collectgarbage("collect")
    fn(math.min(iterations, 1000))
    collectgarbage("collect")

    local best
    for _ = 1, RUNS do
        local t0 = clock()
        local value = fn(iterations)
        local elapsed = clock() - t0
        sink = sink + (tonumber(value) or 0)
        if not best or elapsed < best then
            best = elapsed
        end
        collectgarbage("collect")
    end

    return best * 1000000000 / iterations
end

-- 交替测量一组函数（创建类用例专用）：创建会大量分配、受 GC 时机影响，
-- 连续分测会让先测的一方背上更多 GC 债，交替测量可消除该顺序污染
local function best_of_interleaved(iterations, fns)
    for _, fn in ipairs(fns) do
        fn(math.min(iterations, 1000))
    end
    collectgarbage("collect")

    local best = {}
    for _ = 1, RUNS do
        for index, fn in ipairs(fns) do
            local t0 = clock()
            local value = fn(iterations)
            local elapsed = clock() - t0
            sink = sink + (tonumber(value) or 0)
            collectgarbage("collect")
            if not best[index] or elapsed < best[index] then
                best[index] = elapsed
            end
        end
    end

    local result = {}
    for index = 1, #fns do
        result[index] = best[index] * 1000000000 / iterations
    end
    return result
end

--=============================================================================
-- 两组测试对象
--=============================================================================

-- 无属性类：表 __index（metaFunc.__index = vTable，C 层查找）
local PlainBase = myClass("ModePlainBase")
PlainBase.value = 11
PlainBase.baseMethod = function(self)
    return 5
end

local PlainChild = myClass("ModePlainChild", PlainBase)
PlainChild.childMethod = function(self)
    return 7
end
PlainChild.childValue = 21

local Plain_obj = PlainChild.new()
Plain_obj.ownField = 101

-- 有属性类：声明 get/set 后整类切换到函数 __index
local PropBase = myClass("ModePropBase")
PropBase._value = 11
PropBase.get.value = function(self)
    return self._value
end
PropBase.set.value = function(self, value)
    self._value = value
end
PropBase.baseMethod = function(self)
    return 5
end

local PropChild = myClass("ModePropChild", PropBase)
PropChild.childMethod = function(self)
    return 7
end
-- 本类属性：readable[pCls][key] 第一级就命中，不走基类链
PropChild.get.value2 = function(self)
    return self._value + 1
end

local Prop_obj = PropChild.new()
Prop_obj.ownField = 101

--=============================================================================
-- 测试项
--=============================================================================

local function read_own(obj)
    return function(n)
        local acc = 0
        for _ = 1, n do
            acc = acc + obj.ownField
        end
        return acc
    end
end

local function write_own(obj)
    return function(n)
        for i = 1, n do
            obj.ownField = i
        end
        return obj.ownField
    end
end

local function read_key(obj, key)
    return function(n)
        local acc = 0
        for _ = 1, n do
            acc = acc + obj[key]
        end
        return acc
    end
end

local function call_child_method(obj, method)
    return function(n)
        local acc = 0
        for _ = 1, n do
            acc = acc + obj[method](obj)
        end
        return acc
    end
end

local function create_oop(cls, n)
    local acc = 0
    for _ = 1, n do
        local obj = cls.new()
        acc = acc + 1
    end
    return acc
end

local function delete_oop(cls, n)
    for _ = 1, n do
        local obj = cls.new()
        obj:delete()
    end
    return n
end

local cases = {
    {
        key = "value_read",
        label = "读继承成员（无属性类成员默认值 / 继承 get 属性）",
        n = FAST_N,
        plain = read_key(Plain_obj, "value"),
        prop = read_key(Prop_obj, "value"),
    },
    {
        key = "child_read",
        label = "读本类成员（无属性类成员默认值 / 本类 get 属性）",
        n = FAST_N,
        plain = read_key(Plain_obj, "childValue"),
        prop = read_key(Prop_obj, "value2"),
    },
    {
        key = "own_read",
        label = "读实例自有字段",
        n = FAST_N,
        plain = read_own(Plain_obj),
        prop = read_own(Prop_obj),
    },
    {
        key = "own_write",
        label = "写实例自有字段",
        n = FAST_N,
        plain = write_own(Plain_obj),
        prop = write_own(Prop_obj),
    },
    {
        key = "method",
        label = "方法调用（子类方法）",
        n = FAST_N,
        plain = call_child_method(Plain_obj, "childMethod"),
        prop = call_child_method(Prop_obj, "childMethod"),
    },
    {
        key = "method_inherit",
        label = "继承方法调用（父类方法）",
        n = FAST_N,
        plain = call_child_method(Plain_obj, "baseMethod"),
        prop = call_child_method(Prop_obj, "baseMethod"),
    },
    {
        key = "create",
        label = "实例创建",
        n = CREATE_N,
        interleave = true,
        plain = function(n) return create_oop(PlainChild, n) end,
        prop = function(n) return create_oop(PropChild, n) end,
    },
    {
        key = "create_delete",
        label = "实例创建 + 删除",
        n = CREATE_N,
        interleave = true,
        plain = function(n) return delete_oop(PlainChild, n) end,
        prop = function(n) return delete_oop(PropChild, n) end,
    },
}

-- 有属性类内部拆解：属性读 / 普通方法 / 普通字段
local prop_detail = {
    { label = "继承属性读取（父类 get.value）", n = FAST_N, fn = read_key(Prop_obj, "value") },
    { label = "本类属性读取（子类 get.value2）", n = FAST_N, fn = read_key(Prop_obj, "value2") },
    { label = "普通字段读取（实例自有）", n = FAST_N, fn = read_own(Prop_obj) },
    { label = "方法调用（子类方法）", n = FAST_N, fn = call_child_method(Prop_obj, "childMethod") },
}

local results = {}
for _, case in ipairs(cases) do
    if case.interleave then
        -- 创建类用例：两态交替测量，消除 GC 顺序污染
        local values = best_of_interleaved(case.n, { case.plain, case.prop })
        results[case.key] = { plain = values[1], prop = values[2] }
    else
        results[case.key] = {
            plain = best_of(case.n, case.plain),
            prop  = best_of(case.n, case.prop),
        }
    end
end

local detail_results = {}
for _, item in ipairs(prop_detail) do
    detail_results[#detail_results + 1] = { label = item.label, ns = best_of(item.n, item.fn) }
end

--=============================================================================
-- 输出
--=============================================================================

print("============================================================")
print("  LuaOOP 双模式对比：无属性类（表 __index） vs 有属性类（函数 __index）")
print("  " .. _VERSION .. "  |  best of " .. RUNS .. "  |  sink: " .. tostring(sink))
print("============================================================")
print("")
print("| 测试项 | 迭代次数 | 无属性类 ns/op | 有属性类 ns/op | 有属性/无属性 |")
print("| --- | ---: | ---: | ---: | ---: |")

for _, case in ipairs(cases) do
    local row = results[case.key]
    print(string.format(
        "| %s | %s | %s | %s | %sx |",
        case.label,
        fmt_number(case.n),
        fmt_float(row.plain, 2),
        fmt_float(row.prop, 2),
        fmt_float(row.prop / row.plain, 2)
    ))
end

print("")
print("### 有属性类内部拆解（ns/op）")
print("")
print("| 操作 | 有属性类 ns/op |")
print("| --- | ---: |")
for _, row in ipairs(detail_results) do
    print(string.format("| %s | %s |", row.label, fmt_float(row.ns, 2)))
end
print("")
print(string.format("* create iterations: `%s`  fast iterations: `%s`", fmt_number(CREATE_N), fmt_number(FAST_N)))
print("* 说明：`读继承成员 / 读本类成员` 两行两列含义——无属性类读的是成员默认值（表查找），有属性类是 get 属性调用（函数 __index 闭包）")