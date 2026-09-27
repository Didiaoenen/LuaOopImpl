--[[
-- PushBase 成本分解
--
-- 背景：实测 "class(name, Base) - class(name)" = ~2000~2300 ns，
-- 但按代码逐项估算只能解释 ~750 ns。这里用"累加式分解"定位真实构成：
-- 把 PushBase 的 5 个步骤拆开、逐项累加测量，每步增量即该项成本。
-- 最后再直接调用真实 PushBase 做对照，看手工复刻是否等价。
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

require("LuaOOP.Class")
local class = class
local CI = require("LuaOOP.ClassImpl")
local T  = require("LuaOOP.Config").Tables

local EmptyList = {}      -- 与框架同语义的共享空表
local N = 5000

local steps = {}

steps[1] = function(pCls, pBase)
    -- 基类合法性校验
    if T.ClassesVTable[pBase] == nil then
        error("base must be a class created by class()")
    end
end

steps[2] = function(pCls, pBase)
    -- 成员默认值合并（含 EnsureList 建表 + vTable 同步）
    local baseMembers = T.ClassesMembers[pBase] or EmptyList
    local vTable = T.ClassesVTable[pCls]
    local members
    for key, value in pairs(baseMembers) do
        members = members or CI.EnsureList(T.ClassesMembers, pCls)
        if members[key] == nil then
            members[key] = value
            vTable[key] = value
        end
    end
end

steps[3] = function(pCls, pBase)
    -- 继承关系登记
    table.insert(CI.EnsureList(T.ClassesBases, pCls), pBase)
    table.insert(CI.EnsureList(T.ClassesChild, pBase), pCls)
end

steps[4] = function(pCls, pBase)
    -- vTable 继承回退元表（无属性类的继承方法查找靠它）
    if T.ClassesFuncIndex[pBase] then
        CI.SwitchToFuncIndex(pCls)
    else
        CI.InstallVTableInherit(pCls)
    end
end

steps[5] = function(pCls, pBase)
    -- 析构链继承
    local baseChain = T.ClassesDtorChain[pBase]
    if baseChain and #baseChain > 0 then
        CI.RefreshDtorChain(pCls)
    end
end

local function buildTargets(pPrefix)
    local targets = {}
    for i = 1, N do
        local cls = CI.CreateClass(pPrefix .. "_" .. i)
        CI.CreateClassTables(cls)
        CI.MakeInternalObjectMeta(cls)
        targets[i] = cls
    end
    return targets
end

local function makeBase(pName)
    local base = class(pName)
    base.x = 1                      -- 一个成员默认值
    base.m = function(self) end     -- 一个方法
    return base
end

print("============================================================")
print("  PushBase 成本分解  (N = " .. N .. ")")
print("============================================================")

local prev = 0
for upTo = 0, 5 do
    -- 每轮用独立基类，避免 Child 数组跨轮累积干扰
    local base = makeBase("SB_Base_" .. upTo)
    local targets = buildTargets("SB_T" .. upTo)
    collectgarbage("collect")

    local t0 = os.clock()
    for i = 1, N do
        for s = 1, upTo do
            steps[s](targets[i], base)
        end
    end
    local total = (os.clock() - t0) / N * 1e9

    local label = ({ "（空基准）", "基类校验", "成员合并", "继承登记", "vTable 继承元表", "析构链检查" })[upTo + 1]
    print(string.format("  %d 项 %-14s 累计 %7.1f ns   (本步 +%.1f ns)", upTo, label, total, total - prev))
    prev = total
end

print("  ──────────────────────────────────────────")
do
    local base = makeBase("SB_Base_Real")
    local targets = buildTargets("SB_TR")
    collectgarbage("collect")

    local t0 = os.clock()
    for i = 1, N do
        CI.PushBase(targets[i], base)
    end
    local total = (os.clock() - t0) / N * 1e9
    print(string.format("  真实 PushBase（直接调用）      %7.1f ns", total))
    print(string.format("  手工累加 vs 真实之差          %7.1f ns", total - prev))
end

print("")
