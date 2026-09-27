--[[
-- 惰性析构链模式（Config.LazyDtorChain = true）功能自检
-- 覆盖：基本 dtor / 继承链顺序 / 菱形去重 / dtor 热更新 / 重复 delete / dtor 置空
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

local Cfg = require("LuaOOP.Config")
Cfg.LazyDtorChain = true          -- 必须在加载 Class 之前设置

require("LuaOOP.Class")
local class = class

local pass, fail = 0, 0
local function check(pName, pOk, pDetail)
    if pOk then
        pass = pass + 1
    else
        fail = fail + 1
    end
    print(string.format("  [%s] %-30s %s", pOk and "PASS" or "FAIL", pName, pDetail or ""))
end

-- 1. 基本 dtor
do
    local n = 0
    local A = class("Lazy_A")
    A.dtor = function() n = n + 1 end
    A.new():delete()
    check("基本 dtor 执行一次", n == 1, "次数=" .. n)
end

-- 2. 继承链顺序（子类先、父类后）
do
    local trace = {}
    local P = class("Lazy_P")
    P.dtor = function() trace[#trace + 1] = "P" end
    local C = class("Lazy_C", P)
    C.dtor = function() trace[#trace + 1] = "C" end

    C.new():delete()
    local seq = table.concat(trace, "→")
    check("继承链顺序 子→父", seq == "C→P", seq)
end

-- 3. 菱形继承去重
do
    local trace = {}
    local R = class("Lazy_R")
    R.dtor = function() trace[#trace + 1] = "R" end
    local L = class("Lazy_L", R)
    L.dtor = function() trace[#trace + 1] = "L" end
    local Rt = class("Lazy_Rt", R)
    Rt.dtor = function() trace[#trace + 1] = "Rt" end
    local Leaf = class("Lazy_Leaf", L, Rt)
    Leaf.dtor = function() trace[#trace + 1] = "Leaf" end

    Leaf.new():delete()
    local rootCount = 0
    for _, v in ipairs(trace) do
        if v == "R" then rootCount = rootCount + 1 end
    end
    check("菱形共同祖先只执行一次", rootCount == 1,
        table.concat(trace, "→") .. " (Root×" .. rootCount .. ")")
end

-- 4. 父类后补 dtor（热更新）
do
    local trace = {}
    local Q = class("Lazy_Q")
    local R = class("Lazy_R2", Q)
    R.dtor = function() trace[#trace + 1] = "R" end

    Q.dtor = function() trace[#trace + 1] = "Q" end   -- 热更新
    R.new():delete()
    local seq = table.concat(trace, "→")
    check("父类后补 dtor 生效", seq == "R→Q", seq)
end

-- 5. 重复 delete / 缓存 delete 引用
do
    local cnt = 0
    local S = class("Lazy_S")
    S.dtor = function() cnt = cnt + 1 end
    local obj = S.new()
    local del = obj.delete
    del(obj)
    del(obj)
    check("重复 delete 只执行一次", cnt == 1, "次数=" .. cnt)
end

-- 6. dtor 置空后不再调用
do
    local n = 0
    local T = class("Lazy_T")
    T.dtor = function() n = n + 1 end
    T.new():delete()
    T.dtor = nil
    T.new():delete()
    check("dtor 置空后不再执行", n == 1, "次数=" .. n)
end

print(string.format("\n  惰性模式: %d 通过 / %d 失败", pass, fail))
