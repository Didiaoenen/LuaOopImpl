--[[
-- 类创建成本分解
--
-- 目的：定位 class(name) 的开销具体落在哪一步。
-- 方法：把 class(name) 的完整路径手工展开成累加步骤，逐步测量；
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
local myClass   = class
local ClassImpl = require("LuaOOP.ClassImpl")
local Config    = require("LuaOOP.Config")

local N   = 10000
local uid = 0

local function nextName()
    uid = uid + 1
    return "BD" .. uid
end

local function bench(pLabel, pFn)
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
    print(string.format("  %-44s %9.1f ns/op", pLabel, best / N * 1e9))
end

print("============================================================")
print("  类创建成本分解  (N = " .. N .. ", best of 3)")
print("============================================================")

print("\n[1] 累加步骤（每步都完整创建一个类）")
bench("1  CreateClass（查重 + 类表）", function()
    ClassImpl.CreateClass(nextName())
end)

bench("2  + CreateClassTables", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
end)

bench("3  + MakeInternalObjectMeta", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
    ClassImpl.MakeInternalObjectMeta(cls)
end)

bench("4  + setmetatable(ClassMeta)", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
    ClassImpl.MakeInternalObjectMeta(cls)
    setmetatable(cls, ClassImpl.ClassMeta)
end)

bench("5  + CreateClassInherit", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
    ClassImpl.MakeInternalObjectMeta(cls)
    setmetatable(cls, ClassImpl.ClassMeta)
    ClassImpl.CreateClassInherit(cls, {})
end)

bench("6  + CreateClassAs/New/Delete", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
    ClassImpl.MakeInternalObjectMeta(cls)
    setmetatable(cls, ClassImpl.ClassMeta)
    ClassImpl.CreateClassInherit(cls, {})
    ClassImpl.CreateClassAs(cls)
    ClassImpl.CreateClassNew(cls)
    ClassImpl.CreateClassDelete(cls)
end)

bench("7  + AttachClassFunctions（= 完整路径）", function()
    local cls = ClassImpl.CreateClass(nextName())
    ClassImpl.CreateClassTables(cls)
    ClassImpl.MakeInternalObjectMeta(cls)
    setmetatable(cls, ClassImpl.ClassMeta)
    ClassImpl.CreateClassInherit(cls, {})
    local as     = ClassImpl.CreateClassAs(cls)
    local new    = ClassImpl.CreateClassNew(cls)
    local delete = ClassImpl.CreateClassDelete(cls)
    ClassImpl.AttachClassFunctions(cls, as, new, delete)
end)

bench("8  class(name) —— 官方入口", function()
    myClass(nextName())
end)

print("\n[2] 单项隔离（固定对象上反复调用，衡量纯函数成本）")
local probe = { [Config.Field.__name] = "Probe" }

bench("CreateClassTables", function()
    ClassImpl.CreateClassTables(probe)
end)

bench("MakeInternalObjectMeta", function()
    ClassImpl.MakeInternalObjectMeta(probe)
end)

bench("CreateClassAs（1 闭包）", function()
    ClassImpl.CreateClassAs(probe)
end)

bench("CreateClassNew（1 闭包）", function()
    ClassImpl.CreateClassNew(probe)
end)

bench("CreateClassDelete（1 闭包 + 建链）", function()
    ClassImpl.CreateClassDelete(probe)
end)

bench("AttachClassFunctions", function()
    ClassImpl.AttachClassFunctions(probe, 1, 2, 3)
end)

print("\n[3] 类定义阶段（方法 / 成员默认值，走 ClassSet）")
do
    local mcls = myClass("MethodProbe")
    bench("cls.foo = function() end  （方法）", function()
        mcls.foo = function() end
    end)
    bench("cls.bar = 1               （成员默认值）", function()
        mcls.bar = 1
    end)
end

print("\n[4] 基线对照（表分配 / 普通表写入 / 弱表写入）")
do
    local normal = {}
    local weak   = setmetatable({}, { __mode = "k" })
    local key    = { }

    bench("空表分配 {}", function()
        local t = {}
    end)

    bench("普通表写入", function()
        normal[key] = true
    end)

    bench("弱表写入", function()
        weak[key] = true
    end)

    bench("setmetatable(t, mt)", function()
        local t = setmetatable({}, ClassImpl.ClassMeta)
    end)
end

print("\n[5] 方法数量对类创建的影响")
bench("class(name) + 0 方法", function()
    myClass(nextName())
end)

bench("class(name) + 1 方法", function()
    local cls = myClass(nextName())
    cls.f1 = function() end
end)

bench("class(name) + 2 方法", function()
    local cls = myClass(nextName())
    cls.f1 = function() end
    cls.f2 = function() end
end)

print("")
