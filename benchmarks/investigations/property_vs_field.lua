--[[
-- 属性 vs 字段：逐环节成本分离
--
-- 目的：回答"属性能不能接近字段"。
-- 把"读一个属性"拆成若干层，逐层测成本，找出哪些是框架可优化的、哪些是
-- Lua 元方法模型本身不可消除的。
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

local N = 1000000

local function bench(pLabel, pFn)
    local best = math.huge
    for _ = 1, 3 do
        collectgarbage("collect")
        local t0 = os.clock()
        for i = 1, N do
            pFn(i)
        end
        local dt = os.clock() - t0
        if dt < best then best = dt end
    end
    print(string.format("  %-46s %8.1f ns/op", pLabel, best / N * 1e9))
    return best / N * 1e9
end

local sink = 0

print("============================================================")
print("  属性 vs 字段：逐环节分离  (N = " .. N .. ")")
print("============================================================\n")

print("[1] 纯表访问（无任何元表）")
do
    local obj = { f = 1 }
    bench("读字段 obj.f", function()
        sink = sink + obj.f
    end)
    bench("写字段 obj.f = i", function(pI)
        obj.f = pI
    end)
end

print("\n[2] 纯函数调用（无元方法）")
do
    local obj = { f = 1 }
    local getter = function(pSelf) return pSelf.f end
    local setter = function(pSelf, pV) pSelf.f = pV end
    bench("读  getter(obj)", function()
        sink = sink + getter(obj)
    end)
    bench("写  setter(obj, i)", function(pI)
        setter(obj, pI)
    end)
end

print("\n[3] 元方法层（函数 __index / __newindex，不含属性表查找）")
do
    local obj = setmetatable({}, { __index = function() return 1 end })
    bench("读  __index 返回常量", function()
        sink = sink + obj.anything
    end)
end
do
    local obj = setmetatable({}, { __newindex = function() end })
    bench("写  __newindex 空实现", function(pI)
        obj.anything = pI
    end)
end

print("\n[4] 元方法 + 一层表查")
do
    local store = { anything = 1 }
    local obj = setmetatable({}, {
        __index = function(pT, pKey) return store[pKey] end
    })
    bench("读  __index + store[key]", function()
        sink = sink + obj.anything
    end)
end

print("\n[5] 逐层逼近属性实现（手工模拟 funcIndex）")
do
    -- 5a：元方法 + vTable 查（未命中）+ readable 查（扁平：直接是函数）
    local vTable = {}
    local readableFlat = { anything = function() return 1 end }
    local objA = setmetatable({}, {
        __index = function(pT, pKey)
            local value = vTable[pKey]
            if value ~= nil then return value end
            local fn = readableFlat[pKey]
            if fn then return fn(pT) end
        end
    })
    bench("读  扁平描述符（readable[key] 即函数）", function()
        sink = sink + objA.anything
    end)

    -- 5b：当前实现——描述符是子表，多一次 [1] 索引 + 一次 [2] 静态位判断
    local vTableB = {}
    local readableSub = { anything = { function() return 1 end } }
    local objB = setmetatable({}, {
        __index = function(pT, pKey)
            local value = vTableB[pKey]
            if value ~= nil then return value end
            local property = readableSub[pKey]
            if property and not property[2] then
                return property[1](pT)
            end
        end
    })
    bench("读  子表描述符（当前实现：{fn, static}）", function()
        sink = sink + objB.anything
    end)

    -- 5c：set 路径——扁平 vs 子表
    local writableFlat = { w = function(pT, pV) pT.raw = pV end }
    local objC = setmetatable({}, {
        __newindex = function(pT, pKey, pV)
            local fn = writableFlat[pKey]
            if fn then return fn(pT, pV) end
            rawset(pT, pKey, pV)
        end
    })
    bench("写  扁平描述符", function(pI)
        objC.w = pI
    end)

    local writableSub = { w = { function(pT, pV) pT.raw = pV end } }
    local objD = setmetatable({}, {
        __newindex = function(pT, pKey, pV)
            local property = writableSub[pKey]
            if property and not property[2] then
                return property[1](pT, pV)
            end
            rawset(pT, pKey, pV)
        end
    })
    bench("写  子表描述符（当前实现）", function(pI)
        objD.w = pI
    end)
end

print("\n[6] 框架真实属性（端到端）")
do
    local cls = class("PVF_Real")
    cls._v = 0
    cls._o = 0
    cls.get.v = function(pSelf) return pSelf._v end
    cls.set.w = function(pSelf, pV) pSelf._w = pV end
    cls.opt.o = function(pSelf, pV)
        if pV ~= nil then pSelf._o = pV end
        return pSelf._o
    end
    cls.get_v = function(pSelf) return pSelf._v end

    local obj = cls.new()

    bench("读  get 属性 obj.v（getter 读 vTable 命中的字段）", function()
        sink = sink + obj.v
    end)
    bench("写  set 属性 obj.w = i", function(pI)
        obj.w = pI
    end)
    bench("读  opt 属性 obj.o", function()
        sink = sink + obj.o
    end)
    bench("读  普通方法 obj:get_v()", function()
        sink = sink + obj:get_v()
    end)
    -- 对照：函数式 __index 不缓存"查不到"的结果，每次都要走 SearchBaseMethod
    bench("读  未定义字段 obj.__nope（每次走 SearchBaseMethod）", function()
        sink = sink + (obj.__nope == nil and 1 or 0)
    end)
end

print("\n[7] 无属性类的继承成员读（表 __index，作为对照）")
do
    local cls = class("PVF_Plain")
    cls.m = 42
    local obj = cls.new()
    bench("读  成员默认值（表 __index）obj.m", function()
        sink = sink + obj.m
    end)
end

print("\n  (sink = " .. sink .. ")")
