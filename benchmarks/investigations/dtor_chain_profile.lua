--[[
-- 析构链专项基准
--
-- 为什么需要单独一份：
--   现有 benchmark 里的 dtor_chain 场景是 "new + delete"，LuaOOP 的构造链成本
--   （2.0us 左右）远高于析构链本身，混在一起看不出析构链的优化效果。
--   这里预创建对象、只对 delete 计时，把 new 与 delete 彻底分离。
--
-- 覆盖（只测本框架）：
--   1) 空析构链 / 1 层 / 3 层 / 5 层 / 10 层
--   2) 菱形继承：共同祖先只执行一次的语义验证 + 性能
--   3) dtor 热更新（父类后补 dtor，子类链重建）
--   4) 现有口径的 new+delete 对照
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
local myClass = class

local N       = 100000
local BEST_OF = 3
local NS      = 1e9

-- new + delete 混合（对齐现有 benchmark 口径）
local function bench(pLabel, pN, pFn)
    local best = math.huge
    for _ = 1, BEST_OF do
        collectgarbage("collect")
        local t0 = os.clock()
        for i = 1, pN do
            pFn()
        end
        local dt = os.clock() - t0
        if dt < best then best = dt end
    end
    print(string.format("  %-42s %8.1f ms  %8.1f ns/op", pLabel, best * 1000, best / pN * NS))
    return best / pN * NS
end

-- 纯 delete：先预创建 pN 个对象，只对 delete 循环计时
-- （对象删除后会被标记 ClassesDeathMark，不能重复 delete，所以必须每次重建对象池）
local function benchDelete(pLabel, pN, pCreate, pDelete)
    local best = math.huge
    for _ = 1, BEST_OF do
        local objs = {}
        for i = 1, pN do
            objs[i] = pCreate()
        end
        collectgarbage("collect")

        local t0 = os.clock()
        for i = 1, pN do
            pDelete(objs[i])
        end
        local dt = os.clock() - t0
        if dt < best then best = dt end

        objs = nil
        collectgarbage("collect")
    end
    print(string.format("  %-42s %8.1f ms  %8.1f ns/op", pLabel, best * 1000, best / pN * NS))
    return best / pN * NS
end

-- ============================================================
-- 类构造辅助
-- ============================================================

-- 本框架：pDepth 层继承链，pWithDtor 控制每层是否定义 dtor
local function makeChain(pPrefix, pDepth, pWithDtor)
    local cls = myClass(pPrefix .. "_1")
    cls.ctor = function(self) self.v = 1 end
    if pWithDtor then
        cls.dtor = function(self) self.v = nil end
    end

    for i = 2, pDepth do
        local prev = cls
        cls = myClass(pPrefix .. "_" .. i, prev)
        cls.ctor = function(self) prev.ctor(self) end
        if pWithDtor then
            cls.dtor = function(self) self.v = nil end
        end
    end
    return cls
end

print("============================================================")
print("  析构链专项基准（纯 delete 计时，NEW 已预先完成）")
print("  " .. _VERSION .. "  |  best of " .. BEST_OF .. "  |  N = " .. N)
print("============================================================")

-- ============================================================
-- 1. 继承深度扫描（每层都定义 dtor）
-- ============================================================
print("\n[1] 纯 delete —— 继承深度扫描（本框架）")
local depthNs = {}
for _, depth in ipairs({ 1, 3, 5, 10 }) do
    local cls = makeChain("DSC_" .. depth, depth, true)
    depthNs[depth] = benchDelete(depth .. " 层继承链（每层 1 个 dtor）", N,
        function() return cls.new() end,
        function(o) o:delete() end)
end

print("\n[2] 纯 delete —— 无 dtor（空链，验证零成本）")
local noDtorChain = makeChain("DSC_NODTOR", 3, false)
benchDelete("3 层继承，无任何 dtor", N,
    function() return noDtorChain.new() end,
    function(o) o:delete() end)

-- ============================================================
-- 3. 菱形继承
-- ============================================================
print("\n[3] 菱形继承（共同祖先只执行一次）")
do
    local trace = {}
    local A = class("DiaRoot")
    A.dtor = function(self) trace[#trace + 1] = "Root" end
    local B = class("DiaLeft", A)
    B.dtor = function(self) trace[#trace + 1] = "Left" end
    local C = class("DiaRight", A)
    C.dtor = function(self) trace[#trace + 1] = "Right" end
    local D = class("DiaLeaf", B, C)
    D.dtor = function(self) trace[#trace + 1] = "Leaf" end

    local obj = D.new()
    obj:delete()

    local rootCount = 0
    for _, name in ipairs(trace) do
        if name == "Root" then rootCount = rootCount + 1 end
    end

    print("  调用顺序: " .. table.concat(trace, " → "))
    print("  共同祖先执行次数: " .. rootCount .. (rootCount == 1 and "    [PASS]" or "    [FAIL]"))

    benchDelete("菱形继承 delete（4 个 dtor，去重后）", N,
        function() return D.new() end,
        function(o) o:delete() end)
end

-- ============================================================
-- 4. dtor 热更新（父类后补 dtor，子类链必须重建）
-- ============================================================
print("\n[4] dtor 热更新")
do
    local A = class("HU_A")
    local B = class("HU_B", A)
    A.ctor = function(self) end

    local huge = {}
    B.dtor = function(self) huge[#huge + 1] = "B" end

    local obj = B.new()
    obj:delete()
    print("  父类补 dtor 前，子类链: " .. (table.concat(huge, " → ") == "B" and "B [PASS]" or "异常 [FAIL]"))

    huge = {}
    A.dtor = function(self) huge[#huge + 1] = "A" end  -- 热更新：父类后补 dtor
    local obj2 = B.new()
    obj2:delete()
    local seq = table.concat(huge, " → ")
    print("  父类补 dtor 后，子类链: " .. seq .. (seq == "B → A" and "    [PASS]" or "    [FAIL]"))
end

-- ============================================================
-- 5. 现有口径对照（new + delete 混合）
-- ============================================================
print("\n[5] 现有口径对照（new + delete 混合，含构造链成本）")
do
    local chain = makeChain("MIX", 3, true)
    bench("3 层链 new+delete", N, function() local o = chain.new(); o:delete() end)
end

print("")
