--[[
-- 惰性析构链 A/B：Config.LazyDtorChain = false（默认，预建链）vs true（惰性）
-- 预热 + 交替顺序 + 取最优，避免顺序偏置。
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
require("LuaOOP.Class")
local CI = require("LuaOOP.ClassImpl")

local uid = 0
local function nextName()
    uid = uid + 1
    return "LD" .. uid
end

local N = 20000

local function build()
    local cls = CI.CreateClass(nextName())
    CI.CreateClassTables(cls)
    CI.MakeInternalObjectMeta(cls)
    setmetatable(cls, CI.ClassMeta)

    local as     = CI.CreateClassAs(cls)
    local new    = CI.CreateClassNew(cls)
    local delete = CI.CreateClassDelete(cls)
    CI.AttachClassFunctions(cls, as, new, delete)
end

local function measureOnce()
    collectgarbage("collect")
    local t0 = os.clock()
    for _ = 1, N do
        build()
    end
    return (os.clock() - t0) / N * 1e9
end

local function measure(pLazy)
    Cfg.LazyDtorChain = pLazy
    return measureOnce()
end

-- 预热
measure(false)
measure(true)

local bestEager, bestLazy = math.huge, math.huge
for round = 1, 6 do
    if round % 2 == 1 then
        bestEager = math.min(bestEager, measure(false))
        bestLazy  = math.min(bestLazy,  measure(true))
    else
        bestLazy  = math.min(bestLazy,  measure(true))
        bestEager = math.min(bestEager, measure(false))
    end
end

print(string.format("  预建链（默认）: %7.1f ns/op", bestEager))
print(string.format("  惰性链        : %7.1f ns/op", bestLazy))
print(string.format("  类创建省下    : %7.1f ns/op  (%.1f%%)",
    bestEager - bestLazy, (bestEager - bestLazy) / bestEager * 100))
