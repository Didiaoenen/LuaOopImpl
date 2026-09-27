--[[
-- 类创建专项基准（best of 3 + 每次 GC collect）
-- 只测本框架：根类 / 带方法 / 单继承 / 带属性（触发整类切换到函数 __index）
-- 用法: lua54.exe benchmarks/investigations/class_create_profile.lua
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

-- 本框架：require("LuaOOP.Class") 会设置全局 class，这里收敛为局部别名
require("LuaOOP.Class")
local myClass = class

local uid = 0
local function nm()
    uid = uid + 1
    return "CB_" .. uid
end

local function bench(label, n, fn)
    fn(200)
    collectgarbage("collect")
    local best
    for r = 1, 3 do
        local t0 = os.clock()
        fn(n)
        local e = (os.clock() - t0) / n * 1e6
        if not best or e < best then best = e end
        collectgarbage("collect")
    end
    print(string.format("  %-30s %8.3f us/op", label, best))
    return best
end

local N = 20000

print("============================================================")
print("  类创建专项基准 (best of 3, N=" .. N .. ")")
print("============================================================")

print("\n[类创建基本形态]")
bench("根类（无继承）", N, function(n)
    for _ = 1, n do
        local c = myClass(nm())
    end
end)
bench("根类 + 2 方法", N, function(n)
    for _ = 1, n do
        local c = myClass(nm())
        c.ctor = function(self) end
        c.speak = function(self) end
    end
end)
bench("父类 + 子类（各 2 方法）", N, function(n)
    for _ = 1, n do
        local b = myClass(nm())
        b.ctor = function(self) end
        b.m = function(self) end
        local c = myClass(nm(), b)
        c.ctor = function(self) end
    end
end)

print("\n[带属性：触发整类切换到函数 __index]")
bench("根类 + get 属性", N, function(n)
    for _ = 1, n do
        local c = myClass(nm())
        c.get.v = function(self) return 1 end
    end
end)
bench("根类 + opt 属性", N, function(n)
    for _ = 1, n do
        local c = myClass(nm())
        c.opt.v = function(self, v) if v then self._v = v else return self._v end end
    end
end)
print("============================================================")