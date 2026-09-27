--[[
-- LuaOOP 独有功能性能基准测试
-- 测试对照实现（OtherOOP/）不具备的本框架特性：
--   1. 属性 (get/set/opt) 吞吐量
--   3. 单例获取
--   4. 多继承方法分发
--   5. 菱形继承方法查找
--   6. Copy-on-write 成员
--   7. Null 检查 (ClassesDeathMark)
--   8. 热更新缓存失效
--   9. 深层继承方法查找
--  10. SafeCreate 开关对比
--  11. 大规模场景模拟 (100+ 类、万级实例)
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
local ClassImpl = require("LuaOOP.ClassImpl")
local Config = require("LuaOOP.Config")

-- 唯一类名计数器
local _uid = 0
local function uid()
    _uid = _uid + 1
    return _uid
end

-- ============================================================
-- 工具函数
-- ============================================================

local function now()
    return os.clock()
end

local function bench(name, iter, fn)
    -- 预热
    fn()
    -- 正式计时
    local t0 = now()
    for i = 1, iter do
        fn()
    end
    local elapsed = now() - t0
    local per_op = elapsed / iter * 1e6  -- 微秒
    print(string.format("  %-48s %8d 次  总耗时 %8.3f ms  平均 %.3f us/op", name, iter, elapsed * 1000, per_op))
    return per_op
end

-- 记录结果用于最终汇总
local results = {}

local function benchRecord(name, iter, fn)
    local per_op = bench(name, iter, fn)
    results[name] = per_op
    return per_op
end

-- ============================================================
-- 1. 属性 (get/set/opt) 吞吐量
-- ============================================================

local function test_property_performance()
    print("\n------------------------------------------------------------")
    print("  1. 属性 (get/set/opt) 吞吐量")
    print("------------------------------------------------------------")

    local Vec2 = class("Vec2_" .. uid())
    Vec2.ctor = function(self, x, y)
        self.x = x or 0
        self.y = y or 0
        self._label = "default"
        self._magnitude = 5          -- get 属性读的落点，与 opt 的 _label 等重
        self._value = 0              -- set 属性写的落点，与 opt 的 _label 等重
    end
    -- get 属性：body 只读一个实例字段，与 opt 读等重。
    -- 这样 get / opt 两行的差值只来自分派机制本身，而不是 getter 函数体的计算量
    -- （原实现 body 是 math.sqrt(x*x + y*y)，是个重活，会把 get 行抬高、让 opt 显得更省）。
    Vec2.get.magnitude = function(self)
        return self._magnitude
    end
    -- set 属性：body 只写一个实例字段，与 opt 写等重。
    -- 原实现 body 写两个字段，且计时循环里每轮新建 { x = 1, y = 0 } 字面表，
    -- 把"每次一表分配"的成本也摊进了属性开销；现统一为单字段标量口径。
    Vec2.set.value = function(self, v)
        self._value = v
    end
    Vec2.opt.label = function(self, v)
        if v then self._label = v else return self._label end
    end

    local v = Vec2.new(3, 4)

    -- 普通字段读取基准
    local N = 1000000
    local sink = 0
    local t0 = now()
    for i = 1, N do sink = v.x end
    local field_read = (now() - t0) / N * 1e6

    -- get 属性读取
    t0 = now()
    for i = 1, N do sink = v.magnitude end
    local get_read = (now() - t0) / N * 1e6

    -- set 属性写入（写标量，与 opt 写同口径；不再每轮新建表）
    t0 = now()
    for i = 1, N do v.value = 1 end
    local set_write = (now() - t0) / N * 1e6

    -- opt 属性读取
    t0 = now()
    for i = 1, N do sink = v.label end
    local opt_read = (now() - t0) / N * 1e6

    -- opt 属性写入
    t0 = now()
    for i = 1, N do v.label = "test" end
    local opt_write = (now() - t0) / N * 1e6

    print(string.format("  字段读取:       %.3f us/op (基准)", field_read))
    print(string.format("  get 属性读取:   %.3f us/op (%.1fx 字段读取)", get_read, get_read / math.max(field_read, 0.001)))
    print(string.format("  set 属性写入:   %.3f us/op", set_write))
    print(string.format("  opt 属性读取:   %.3f us/op (%.1fx 字段读取)", opt_read, opt_read / math.max(field_read, 0.001)))
    print(string.format("  opt 属性写入:   %.3f us/op", opt_write))

    results["字段读取"] = field_read
    results["get属性读取"] = get_read
    results["set属性写入"] = set_write
    results["opt属性读取"] = opt_read
    results["opt属性写入"] = opt_write
end

-- ============================================================
-- 3. 单例获取
-- ============================================================

local function test_singleton_performance()
    print("\n------------------------------------------------------------")
    print("  3. 单例获取")
    print("------------------------------------------------------------")

    local Config = class("Singleton_" .. uid())
    Config.ctor = function(self)
        self.value = 42
    end
    Config.__singleton = function()
        return Config.new()
    end

    -- 首次获取（创建）
    local inst = Config.Instance

    -- 后续获取（缓存命中）
    local N = 1000000
    local sink
    benchRecord("[单例] 缓存命中获取 Instance", N, function()
        sink = Config.Instance
    end)
end

-- ============================================================
-- 4. 多继承方法分发
-- ============================================================

local function test_multi_inheritance_performance()
    print("\n------------------------------------------------------------")
    print("  4. 多继承方法分发")
    print("------------------------------------------------------------")

    local A = class("MIA_" .. uid())
    A.ctor = function(self) self.a = 1 end
    A.method_a = function(self) return self.a end

    local B = class("MIB_" .. uid())
    B.ctor = function(self) self.b = 2 end
    B.method_b = function(self) return self.b end

    local C = class("MIC_" .. uid(), A, B)
    C.ctor = function(self) A.ctor(self); B.ctor(self); self.c = 3 end

    local obj = C.new()

    local N = 500000
    -- 第一个基类方法（vTable 首次查找后缓存）
    benchRecord("[多继承] 第一个基类方法调用 method_a", N, function()
        obj:method_a()
    end)

    -- 第二个基类方法
    benchRecord("[多继承] 第二个基类方法调用 method_b", N, function()
        obj:method_b()
    end)

    -- 类型检查
    benchRecord("[多继承] as 类型检查 (3 层)", N, function()
        obj:as(A)
    end)
end

-- ============================================================
-- 5. 菱形继承方法查找
-- ============================================================

local function test_diamond_inheritance_performance()
    print("\n------------------------------------------------------------")
    print("  5. 菱形继承方法查找")
    print("------------------------------------------------------------")

    local Root = class("DmRoot_" .. uid())
    Root.ctor = function(self) self.root_val = 1 end
    Root.root_method = function(self) return "root" end
    Root.root_field = 100

    local Left = class("DmLeft_" .. uid(), Root)
    Left.ctor = function(self) Root.ctor(self); self.left_val = 2 end
    Left.left_method = function(self) return "left" end

    local Right = class("DmRight_" .. uid(), Root)
    Right.ctor = function(self) Root.ctor(self); self.right_val = 3 end
    Right.right_method = function(self) return "right" end

    local Diamond = class("DmChild_" .. uid(), Left, Right)
    Diamond.ctor = function(self)
        Left.ctor(self)
        Right.ctor(self)
        self.diamond_val = 4
    end

    local obj = Diamond.new()

    local N = 500000
    -- 首次 vs 后续访问（vTable 缓存效果）
    benchRecord("[菱形] 根类方法 root_method (首次后缓存)", N, function()
        obj:root_method()
    end)

    -- 左分支方法
    benchRecord("[菱形] 左分支方法 left_method", N, function()
        obj:left_method()
    end)

    -- 根类 COW 成员
    local sink = 0
    benchRecord("[菱形] 根类 COW 成员读取", N, function()
        sink = obj.root_field
    end)
end

-- ============================================================
-- 6. Copy-on-write 成员
-- ============================================================

local function test_cow_performance()
    print("\n------------------------------------------------------------")
    print("  6. Copy-on-write 成员")
    print("------------------------------------------------------------")

    local Entity = class("COW_" .. uid())
    Entity.hp = 100
    Entity.mp = 50
    Entity.name = "unknown"

    local e1 = Entity.new()
    local e2 = Entity.new()

    local N = 1000000
    -- COW 读取（从 vTable 获取默认值）
    local sink = 0
    benchRecord("[COW] 读取默认值 (vTable 提供)", N, function()
        sink = e1.hp
    end)

    -- COW 写入（rawset 到实例）
    benchRecord("[COW] 写入新值 (copy-on-write)", N, function()
        e1.hp = 80
    end)

    -- 写入后再次读取（从实例获取）
    benchRecord("[COW] 写入后读取 (实例存储)", N, function()
        sink = e1.hp
    end)

    -- 未写入的实例仍从 vTable 读取
    benchRecord("[COW] 未写入实例读取 (vTable)", N, function()
        sink = e2.hp
    end)

    -- 多 COW 成员同时读取
    benchRecord("[COW] 3 个默认成员同时读取", N, function()
        sink = e2.hp + e2.mp
    end)
end

-- ============================================================
-- 7. Null 检查 (ClassesDeathMark)
-- ============================================================

local function test_null_performance()
    print("\n------------------------------------------------------------")
    print("  7. Null 检查 (ClassesDeathMark)")
    print("------------------------------------------------------------")

    local Entity = class("Null_" .. uid())
    Entity.ctor = function(self) self.alive = true end

    local obj = Entity.new()
    local deadObj = Entity.new()
    deadObj:delete()

    local N = 1000000
    -- 活对象检查
    benchRecord("[Null] 活对象 Null 检查", N, function()
        ClassImpl.Null(obj)
    end)

    -- 已删除对象检查
    benchRecord("[Null] 已删除对象 Null 检查", N, function()
        ClassImpl.Null(deadObj)
    end)

    -- nil 检查
    benchRecord("[Null] nil Null 检查", N, function()
        ClassImpl.Null(nil)
    end)
end

-- ============================================================
-- 8. 热更新缓存失效
-- ============================================================

local function test_hotupdate_performance()
    print("\n------------------------------------------------------------")
    print("  8. 热更新缓存失效")
    print("------------------------------------------------------------")

    local Base = class("HotBase_" .. uid())
    Base.ctor = function(self) self.val = 0 end
    Base.compute = function(self) return self.val * 2 end

    local Child = class("HotChild_" .. uid(), Base)
    Child.ctor = function(self) Base.ctor(self); self.extra = 10 end

    -- 预创建实例
    local instances = {}
    for i = 1, 1000 do
        instances[i] = Child.new()
    end

    -- 热更新前方法调用
    local N = 500000
    benchRecord("[热更新] 正常方法调用", N, function()
        instances[1]:compute()
    end)

    -- 热更新：修改基类方法（触发子类 vTable 失效）
    local hotupdate_count = 100
    local t0 = now()
    for i = 1, hotupdate_count do
        Base.compute = function(self) return self.val * (i + 2) end
    end
    local elapsed = (now() - t0) / hotupdate_count * 1e6
    print(string.format("  %-48s %8d 次  总耗时 %8.3f ms  平均 %.3f us/op",
        "[热更新] 基类方法替换（含子类 vTable 失效）", hotupdate_count,
        (now() - t0) * 1000, elapsed))

    -- 热更新后首次访问（vTable 重建）
    benchRecord("[热更新] 失效后首次方法调用", N, function()
        instances[1]:compute()
    end)
end

-- ============================================================
-- 9. 深层继承方法查找
-- ============================================================

local function test_deep_inheritance_performance()
    print("\n------------------------------------------------------------")
    print("  9. 深层继承方法查找")
    print("------------------------------------------------------------")

    -- 构建不同深度的继承链
    local depths = { 3, 5, 10, 20 }

    for _, depth in ipairs(depths) do
        local classes = {}

        classes[1] = class("Deep" .. depth .. "_1_" .. uid())
        classes[1].ctor = function(self) self.level = 1 end
        classes[1].method = function(self) return self.level end

        for i = 2, depth do
            classes[i] = class("Deep" .. depth .. "_" .. i .. "_" .. uid(), classes[i - 1])
            local prev = classes[i - 1]
            classes[i].ctor = function(self)
                prev.ctor(self)
                self.level = i
            end
        end

        local obj = classes[depth].new()
        local N = 1000000
        local sink = 0

        -- 继承方法调用（首次后 vTable 缓存）
        benchRecord(string.format("[深层] %2d 层继承方法调用 (vTable缓存)", depth), N, function()
            sink = obj:method()
        end)
    end
end

-- ============================================================
-- 10. SafeCreate 开关对比
-- ============================================================

local function test_safecreate_performance()
    print("\n------------------------------------------------------------")
    print("  10. SafeCreate 开关对比")
    print("------------------------------------------------------------")

    -- SafeCreate = true (默认)
    Config.SafeCreate = true

    local SafeClass = class("Safe_" .. uid())
    SafeClass.ctor = function(self)
        self.x = 1
        self.y = 2
    end

    local N = 100000
    local safe_time = benchRecord("[SafeCreate=true] pcall 包裹创建实例", N, function()
        local obj = SafeClass.new()
    end)

    -- SafeCreate = false
    Config.SafeCreate = false

    local UnsafeClass = class("Unsafe_" .. uid())
    UnsafeClass.ctor = function(self)
        self.x = 1
        self.y = 2
    end

    local unsafe_time = benchRecord("[SafeCreate=false] 直接创建实例", N, function()
        local obj = UnsafeClass.new()
    end)

    -- 恢复默认
    Config.SafeCreate = true

    print(string.format("\n  SafeCreate 对比: 关闭 pcall 可提速 %.1fx",
        safe_time / math.max(unsafe_time, 0.001)))
end

-- ============================================================
-- 11. 大规模场景模拟
-- ============================================================

local function test_large_scale_simulation()
    print("\n------------------------------------------------------------")
    print("  11. 大规模场景模拟 (100+ 类、万级实例)")
    print("------------------------------------------------------------")

    -- 创建 100 个类，形成 4 层继承树
    local baseClasses = {}
    for i = 1, 10 do
        local cls = class("ScaleBase" .. i .. "_" .. uid())
        cls.ctor = function(self) self["base" .. i .. "_val"] = i end
        cls["base_method_" .. i] = function(self) return i end
        baseClasses[i] = cls
    end

    local midClasses = {}
    for i = 1, 30 do
        local parent = baseClasses[(i - 1) % 10 + 1]
        local cls = class("ScaleMid" .. i .. "_" .. uid(), parent)
        cls.ctor = function(self)
            parent.ctor(self)
            self["mid" .. i .. "_val"] = i * 10
        end
        cls["mid_method_" .. i] = function(self) return i * 10 end
        midClasses[i] = cls
    end

    local leafClasses = {}
    for i = 1, 60 do
        local parent = midClasses[(i - 1) % 30 + 1]
        local cls = class("ScaleLeaf" .. i .. "_" .. uid(), parent)
        cls.ctor = function(self)
            parent.ctor(self)
            self["leaf" .. i .. "_val"] = i * 100
            self.hp = 100
            self.name = "entity_" .. i
        end
        -- 所有叶子类都定义同名方法，方便统一调用
        cls.get_hp = function(self) return self.hp end
        leafClasses[i] = cls
    end

    -- 批量创建实例
    local INSTANCE_COUNT = 30000
    local instances = {}
    local t0 = now()
    for i = 1, INSTANCE_COUNT do
        local cls = leafClasses[(i - 1) % 60 + 1]
        instances[i] = cls.new()
    end
    local create_time = (now() - t0) * 1000

    -- 方法调用（所有叶子类都有 get_hp 方法）
    t0 = now()
    for i = 1, INSTANCE_COUNT do
        instances[i]:get_hp()
    end
    local method_time = (now() - t0) * 1000
    local sink = 0
    for i = 1, INSTANCE_COUNT do
        sink = instances[i].hp  -- COW 成员读取
    end
    local access_time = (now() - t0) * 1000

    -- 字段写入
    t0 = now()
    for i = 1, INSTANCE_COUNT do
        instances[i].hp = 80
    end
    local write_time = (now() - t0) * 1000

    -- 批量删除
    t0 = now()
    for i = 1, INSTANCE_COUNT do
        instances[i]:delete()
    end
    local delete_time = (now() - t0) * 1000

    print(string.format("  %d 类 × %d 实例:", #baseClasses + #midClasses + #leafClasses, INSTANCE_COUNT))
    print(string.format("    创建:   %.1f ms  (%.1f us/op)", create_time, create_time / INSTANCE_COUNT * 1000))
    print(string.format("    方法:   %.1f ms  (%.1f us/op)", method_time, method_time / INSTANCE_COUNT * 1000))
    print(string.format("    读取:   %.1f ms  (%.1f us/op)", access_time, access_time / INSTANCE_COUNT * 1000))
    print(string.format("    写入:   %.1f ms  (%.1f us/op)", write_time, write_time / INSTANCE_COUNT * 1000))
    print(string.format("    删除:   %.1f ms  (%.1f us/op)", delete_time, delete_time / INSTANCE_COUNT * 1000))
end

-- ============================================================
-- 运行所有测试
-- ============================================================

print("============================================================")
print("  LuaOOP 独有功能性能基准测试")
print("  Lua " .. _VERSION)
print("============================================================")

test_property_performance()
test_singleton_performance()
test_multi_inheritance_performance()
test_diamond_inheritance_performance()
test_cow_performance()
test_null_performance()
test_hotupdate_performance()
test_deep_inheritance_performance()
test_safecreate_performance()
test_large_scale_simulation()

-- ============================================================
-- 结果汇总
-- ============================================================

print("\n============================================================")
print("  结果汇总")
print("============================================================")

-- 属性开销摘要
if results["get属性读取"] and results["字段读取"] then
    print(string.format("  属性(get) vs 字段读取: %.1fx 开销",
        results["get属性读取"] / math.max(results["字段读取"], 0.001)))
end
if results["opt属性读取"] and results["字段读取"] then
    print(string.format("  属性(opt) vs 字段读取: %.1fx 开销",
        results["opt属性读取"] / math.max(results["字段读取"], 0.001)))
end

-- 继承查找摘要
local deep3 = results["[深层]  3 层继承方法调用 (vTable缓存)"]
local deep20 = results["[深层] 20 层继承方法调用 (vTable缓存)"]
if deep3 and deep20 then
    print(string.format("  3层 vs 20层 继承方法调用: %.3f vs %.3f us/op (%.1fx)",
        deep3, deep20, deep20 / math.max(deep3, 0.001)))
end

print("\n============================================================")
print("  测试完成")
print("============================================================")
