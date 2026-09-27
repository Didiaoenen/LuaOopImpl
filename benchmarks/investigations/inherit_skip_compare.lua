--[[
-- A/B 对照：根类是否调用 CreateClassInherit(cls, {})
--
-- 唯一差异是那一行，用于分离"空基类列表分配 + 函数调用"的真实成本。
-- 注意：必须"交替顺序 + 预热 + 取各自最优"——否则后测的一组总会快 20% 以上
-- （堆已扩展、GC 进入稳定状态），得出完全相反的结论。
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
local CI = require("LuaOOP.ClassImpl")

local uid = 0
local function nextName()
    uid = uid + 1
    return "AB" .. uid
end

local function build(pWithInherit)
    local cls = CI.CreateClass(nextName())
    CI.CreateClassTables(cls)
    CI.MakeInternalObjectMeta(cls)
    setmetatable(cls, CI.ClassMeta)

    if pWithInherit then
        CI.CreateClassInherit(cls, {})
    end

    local as     = CI.CreateClassAs(cls)
    local new    = CI.CreateClassNew(cls)
    local delete = CI.CreateClassDelete(cls)
    CI.AttachClassFunctions(cls, as, new, delete)
end

local N = 50000

local function measureOnce(pWithInherit)
    collectgarbage("collect")
    local t0 = os.clock()
    for _ = 1, N do
        build(pWithInherit)
    end
    return (os.clock() - t0) / N * 1e9
end

-- 预热（不计入）
measureOnce(false)
measureOnce(true)

local bestSkip, bestEnter = math.huge, math.huge
for round = 1, 6 do
    if round % 2 == 1 then
        bestSkip  = math.min(bestSkip,  measureOnce(false))
        bestEnter = math.min(bestEnter, measureOnce(true))
    else
        bestEnter = math.min(bestEnter, measureOnce(true))
        bestSkip  = math.min(bestSkip,  measureOnce(false))
    end
end

print(string.format("  跳过 CreateClassInherit : %7.1f ns/op", bestSkip))
print(string.format("  进入 CreateClassInherit : %7.1f ns/op", bestEnter))
print(string.format("  差（前者省下）    : %7.1f ns/op  (%.2f%%)",
    bestEnter - bestSkip, (bestEnter - bestSkip) / bestEnter * 100))
