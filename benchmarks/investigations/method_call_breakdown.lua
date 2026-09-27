--[[
-- 方法调用专项分析（只测本框架：Class / ClassImpl）
--
-- 测试结构：
--   父类：5 个方法（inh1..inh5）      子类继承后调用 → 走"继承方法"路径
--   子类：5 个方法（own1..own5）      子类自己定义   → 走"本类方法"路径
--   另有 10 个方法轮流调用 → "混合调用"
--
-- 方法体统一为 return 1（隔离调用机制本身，不掺杂字段访问/业务逻辑）
-- 并额外拆出"只查不调（obj.m）"与"纯调用（f(self)）"，用于定位开销来源。
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

local N_CALL    = 500000    -- 每个方法单独调用次数
local N_MIX     = 1000000   -- 混合调用次数
local N_LOOKUP  = 1000000   -- 只查不调次数
local RUNS      = 5
local clock = os.clock
local sink = 0

local function best_of(iterations, fn)
    fn(math.min(iterations, 1000))
    collectgarbage("collect")
    local best
    for _ = 1, RUNS do
        local t0 = clock()
        sink = sink + (tonumber(fn(iterations)) or 0)
        local elapsed = clock() - t0
        if not best or elapsed < best then
            best = elapsed
        end
        collectgarbage("collect")
    end
    return best * 1e9 / iterations
end

--=============================================================================
-- 类定义：父类 5 个继承方法 + 子类 5 个本类方法
--=============================================================================

local OWN_NAMES = { "own1", "own2", "own3", "own4", "own5" }
local INH_NAMES = { "inh1", "inh2", "inh3", "inh4", "inh5" }
local ALL_NAMES = { "own1", "own2", "own3", "own4", "own5", "inh1", "inh2", "inh3", "inh4", "inh5" }

local function method()
    return 1
end

local MYBase = myClass("MCAnalysisBase")
for i = 1, 5 do
    MYBase[INH_NAMES[i]] = method
end

local MYChild = myClass("MCAnalysisChild", MYBase)
for i = 1, 5 do
    MYChild[OWN_NAMES[i]] = method
end

local myObj = MYChild.new()

--=============================================================================
-- 测量辅助
--=============================================================================

-- obj[name](obj)：含"查表 + 调用"，等价于 obj:name()
local function call_named(obj, name)
    return function(n)
        local acc = 0
        for _ = 1, n do
            acc = acc + obj[name](obj)
        end
        return acc
    end
end

-- 只查不调：把方法取出来（不执行）
local function lookup_named(obj, name)
    return function(n)
        local acc = 0
        for _ = 1, n do
            if obj[name] then
                acc = acc + 1
            end
        end
        return acc
    end
end

-- 纯调用：函数已预先取出，不含查表
local function call_bare(fn)
    return function(n)
        local acc = 0
        for _ = 1, n do
            acc = acc + fn(nil)
        end
        return acc
    end
end

-- 10 个方法轮流调用（索引来自预建数组，无字符串拼接开销）
local function call_mixed(obj)
    local names = ALL_NAMES
    return function(n)
        local acc = 0
        local index = 0
        for _ = 1, n do
            index = index + 1
            if index > 10 then
                index = 1
            end
            acc = acc + obj[names[index]](obj)
        end
        return acc
    end
end

--=============================================================================
-- 运行
--=============================================================================

local function measure(obj)
    local data = { own = {}, inh = {} }

    for i = 1, 5 do
        data.own[i] = best_of(N_CALL, call_named(obj, OWN_NAMES[i]))
    end
    for i = 1, 5 do
        data.inh[i] = best_of(N_CALL, call_named(obj, INH_NAMES[i]))
    end

    local ownSum, inhSum = 0, 0
    for i = 1, 5 do
        ownSum = ownSum + data.own[i]
        inhSum = inhSum + data.inh[i]
    end
    data.ownAvg = ownSum / 5
    data.inhAvg = inhSum / 5

    data.mixed      = best_of(N_MIX, call_mixed(obj))
    data.ownLookup  = best_of(N_LOOKUP, lookup_named(obj, OWN_NAMES[1]))
    data.inhLookup  = best_of(N_LOOKUP, lookup_named(obj, INH_NAMES[1]))
    data.bareCall   = best_of(N_CALL, call_bare(obj[OWN_NAMES[1]]))

    return data
end

local my = measure(myObj)

--=============================================================================
-- 输出
--=============================================================================

print("============================================================")
print("  方法调用专项分析：本框架（LuaOOP）")
print("  " .. _VERSION .. "  |  best of " .. RUNS .. "  |  方法体: return 1")
print("============================================================")

print("")
print("  本类方法（own1~own5）：")
for i = 1, 5 do
    print(string.format("    %-6s %8.2f ns/op", OWN_NAMES[i], my.own[i]))
end
print(string.format("    平均   %8.2f ns/op", my.ownAvg))
print("  继承方法（inh1~inh5，定义在父类）：")
for i = 1, 5 do
    print(string.format("    %-6s %8.2f ns/op", INH_NAMES[i], my.inh[i]))
end
print(string.format("    平均   %8.2f ns/op", my.inhAvg))
print(string.format("  混合调用（10 个方法轮流）        %8.2f ns/op", my.mixed))

print("")
print("【拆解：一次 obj:name() 的开销构成】")
print(string.format("  查表 + 调用 obj.own1             %8.2f ns/op", my.own[1]))
print(string.format("  只查不调 obj.own1                %8.2f ns/op", my.ownLookup))
print(string.format("  只查不调 obj.inh1（继承）        %8.2f ns/op", my.inhLookup))
print(string.format("  纯调用（函数已取出，不含查表）   %8.2f ns/op", my.bareCall))
print("")
print("  sink:", sink)