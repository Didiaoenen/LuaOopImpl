--[[
-- A/B 对照：CreateClassTables 里向 Bases / Child / Members 三张弱表写共享空表，
-- 到底值多少 ns？
--
-- A：写 3 张（当前实现）
-- B：只写 MetaFunc（惰性方案的"理想情况"——省掉 3 次弱表写入）
-- 同样采用"预热 + 交替顺序 + 取最优"，避免顺序偏置。
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
local Cfg = require("LuaOOP.Config")
local T = Cfg.Tables
local Field = Cfg.Field

local EmptyList = {}
local N = 100000

-- 预创建一批充当"类表"的空表（每个 key 都是首次插入，模拟真实建类）
local pool = {}
for i = 1, N do
    pool[i] = {}
end

local function measureOnce(pWriteThree)
    collectgarbage("collect")
    local t0 = os.clock()
    for i = 1, N do
        local cls = pool[i]
        if pWriteThree then
            T.ClassesBases[cls]   = EmptyList
            T.ClassesChild[cls]   = EmptyList
            T.ClassesMembers[cls] = EmptyList
        end
        T.ClassesMetaFunc[cls] = { [Field.__internal] = true }
    end
    return (os.clock() - t0) / N * 1e9
end

-- 预热
measureOnce(true)
measureOnce(false)

local bestWrite, bestSkip = math.huge, math.huge
for round = 1, 6 do
    if round % 2 == 1 then
        bestWrite = math.min(bestWrite, measureOnce(true))
        bestSkip  = math.min(bestSkip,  measureOnce(false))
    else
        bestSkip  = math.min(bestSkip,  measureOnce(false))
        bestWrite = math.min(bestWrite, measureOnce(true))
    end
end

print(string.format("  写 3 张弱表   : %7.1f ns/op", bestWrite))
print(string.format("  不写（惰性）: %7.1f ns/op", bestSkip))
print(string.format("  3 次弱表写入的成本 : %7.1f ns/op", bestWrite - bestSkip))
