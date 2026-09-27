--[[
-- 子类创建成本分解：根类 vs 单继承 vs 双继承
-- 差值即为 PushBase 全链路（成员合并 + EnsureList + insert + 子类登记 +
-- 属性模式判断 + vTable 元表安装 + 析构链检查）的成本。
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

local uid = 0
local function nextName()
    uid = uid + 1
    return "SC" .. uid
end

-- 预建两个带成员与方法的基类（不计入计时）
local BaseA = class("SC_BaseA")
BaseA.x = 1
BaseA.ma = function(self) end

local BaseB = class("SC_BaseB")
BaseB.y = 2
BaseB.mb = function(self) end

local N = tonumber(arg and arg[1]) or 20000

local function bench(pFn)
    local best = math.huge
    for _ = 1, 3 do
        collectgarbage("collect")
        local t0 = os.clock()
        for _ = 1, N do
            pFn()
        end
        local dt = os.clock() - t0
        if dt < best then best = dt end
    end
    return best / N * 1e9
end

-- 预热（交替）
bench(function() class(nextName()) end)
bench(function() class(nextName(), BaseA) end)
bench(function() class(nextName(), BaseA, BaseB) end)

local root = bench(function() class(nextName()) end)
local sub1 = bench(function() class(nextName(), BaseA) end)
local sub2 = bench(function() class(nextName(), BaseA, BaseB) end)

print(string.format("  根类（无继承）  : %7.1f ns/op", root))
print(string.format("  单继承子类      : %7.1f ns/op   PushBase 全链路 = +%.0f ns", sub1, sub1 - root))
print(string.format("  双继承子类      : %7.1f ns/op   第 2 个基类 = +%.0f ns", sub2, sub2 - sub1))
