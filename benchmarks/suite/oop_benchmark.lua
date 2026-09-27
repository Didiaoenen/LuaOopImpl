--[[
-- 共有功能对比基准（实现无关）
--
-- 本文件只放「测试定义 + 入口」：42 项共有功能定义一次（本文件的 TESTS），实现特有的东西
--   （多继承、属性、单例等）一概不在这里，见 oop_features_profile.lua。
--
-- 参与对比的实现由入口一行 Test(table.unpack(Adapter.discover())) 自动收集：每个 OOP 实现对应
--   benchmarks/suite/impls/ 下的一个适配层文件，扫描到几个就有几列。
--   新增一个实现＝往 impls/ 放一个文件；删掉一个实现＝删掉那个文件。
--   本文件、入口、适配层机制都不需要改。
--   列顺序由适配层里的 order 字段决定（省略 = 100，同值按文件名升序）。
--   想临时只跑其中几个：把不需要的文件移出 impls/，或把入口改成显式传表
--     local impls = Adapter.discover()      -- 按列顺序排好的实现表数组
--     Test(impls[1], impls[3])              -- 只跑第 1、3 列
--   适配层文件本身怎么写：见 impls/ 下三个现成例子，或 benchmarks/README.md 的「实现表接口」。
--
-- 适配层机制在 impl_adapter.lua：接入字段的逐字段说明、校验归一化、形状工厂、
--   impls/ 目录扫描（M.discover）都在那里；impls/ 下的每个文件只写"本实现怎么接入"。
--   实现不具备的能力不参与测试，对应单元格显示 n/a（例如无同步删除 ⇒ 析构 3 项 n/a）。
--
-- 计时口径：预热后 best-of-3，每轮之间 collectgarbage；单位 us/op。
--   实现原语只在准备阶段调用（含建/删实例的形状分支，见 Adapter 的形状工厂），
--   计时闭包内只保留被测操作本身，不引入额外函数帧。
--
-- 本框架特有功能（属性 / 单例 / 多继承等）见 oop_features_profile.lua。
--]]

-- ============================================================
-- 配置
-- ============================================================

local ITER = {
    -- 生命周期
    class_creation              = 10000,
    instance_creation           = 100000,
    inherit_class_creation      = 5000,
    inherit_instance            = 100000,
    full_lifecycle              = 100000,
    instance_delete             = 100000,
    dtor_chain                  = 100000,
    ctor_chain                  = 100000,
    -- 字段访问
    single_field_read           = 2000000,
    single_field_write          = 1000000,
    field_read_3                = 1000000,
    field_write_3               = 500000,
    field_read_5                = 1000000,
    field_read_10               = 1000000,
    string_field_read           = 2000000,
    bool_field_read             = 2000000,
    inherited_field_read        = 1000000,
    cow_default_read            = 2000000,
    cow_write_then_read         = 1000000,
    multi_instance_field_read   = 1000000,
    -- 方法调用
    method_call                 = 1000000,
    method_call_1arg            = 1000000,
    method_call_3args           = 1000000,
    method_call_return          = 1000000,
    method_call_self_field      = 1000000,
    method_call_delegate        = 1000000,
    method_call_5methods        = 1000000,
    inherited_method_call       = 1000000,
    hotupdate_method            = 500000,
    -- 继承深度
    inherit1_method             = 1000000,
    inherit2_method             = 1000000,
    inherit3_method             = 1000000,
    inherit5_method             = 1000000,
    inherit10_method            = 1000000,
    inherit1_field              = 1000000,
    inherit2_field              = 1000000,
    inherit3_field              = 1000000,
    inherit5_field              = 1000000,
    inherit10_field             = 1000000,
    -- 综合
    mixed_operations            = 100000,
    many_fields_rw              = 500000,
    many_methods_call            = 500000,
}

-- ============================================================
-- 路径引导
-- 本脚本位于 benchmarks/suite/，仓库根目录即其上方两级。
-- 按脚本自身位置解析，从任意工作目录运行结果一致。
-- ============================================================

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

-- 实现适配层机制：接入字段契约 / 校验归一化 / 形状工厂 / impls 目录扫描
local Adapter = require("benchmarks.suite.impl_adapter")

-- ============================================================
-- 工具函数
-- ============================================================

local function now() return os.clock() end

local function bench(iter, fn)
    fn()
    collectgarbage("collect")
    local best
    for _ = 1, 3 do
        local t0 = now()
        for i = 1, iter do fn() end
        local e = (now() - t0) / iter * 1e6
        if not best or e < best then best = e end
    end
    return best
end

-- 数值列格式：nil（该实现无等价能力 / 未参与）显示 n/a
local function fnum(us)
    return us and string.format("%8.3f", us) or "     n/a"
end

-- 倍率文本："参照实现 / 该实现"，该实现为空时显示 n/a
local function ratio_text(ref_us, other_us)
    if not ref_us or not other_us then return "n/a" end
    local ratio = ref_us / other_us
    if ratio > 1.005 then
        return string.format("%.2fx慢", ratio)
    elseif ratio < 0.995 then
        return string.format("%.2fx快", 1 / ratio)
    else
        return "持平"
    end
end

-- 显示宽度：CJK 等全角字符按 2 列计，避免中文测试名导致整表错位
local function dwidth(s)
    local w = 0
    for _, cp in utf8.codes(s) do
        if cp >= 0x1100 and (cp <= 0x115F or cp == 0x2329 or cp == 0x232A
            or (cp >= 0x2E80 and cp <= 0xA4CF) or (cp >= 0xAC00 and cp <= 0xD7A3)
            or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFE30 and cp <= 0xFE6F)
            or (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6)) then
            w = w + 2
        else
            w = w + 1
        end
    end
    return w
end

local function pad_right(s, width)
    local d = width - dwidth(s)
    return d > 0 and (s .. string.rep(" ", d)) or s
end

local function pad_left(s, width)
    local d = width - dwidth(s)
    return d > 0 and (string.rep(" ", d) .. s) or s
end

-- 类名唯一化：所有实现共用同一计数器（LuaOOP 侧类名不允许重复）
local _uid = 0
local function uid() _uid = _uid + 1; return _uid end
local function mkname(tag) return tag .. "_" .. uid() end

-- 准备期/计时期建实例一律走适配层的形状工厂（A.obj 立即建、A.t_new 只建、A.t_new_delete 建+删、
-- A.t_new_use_delete 建+调一次方法+删、A.t_new_call2 建(2参)+调两个方法），形状分支全在适配层
-- 的准备阶段展开，见 impl_adapter.lua。

-- ops 收到的上下文：唯一名生成
local ctx = {
    uid = function(prefix) return prefix .. "_" .. uid() end,
}

-- ============================================================
-- 共有测试定义（实现无关，定义一次）
--
-- make(A) 在准备阶段调用，返回计时闭包；返回 nil 或 requires 不满足 ⇒ 该实现此项 n/a。
-- requires 取值：ctor / method / dtor / default / redefine / multibase
-- ============================================================

local TESTS = {}
local function T(key, label, requires, make)
    TESTS[#TESTS + 1] = { key = key, label = label, requires = requires, make = make }
end

-- ===================== 生命周期 =====================

do -- 类创建（无继承）
    T("class_creation", "类创建（无继承）", { "ctor", "method" }, function(A)
        local CREATE, CTOR = A.create, A.write_ctor
        return function()
            local c = CREATE(mkname("cc"))
            CTOR(c, function(self, name) self.name = name end)
            c.speak = function(self) return self.name end
        end
    end)
end

do -- 单继承 - 子类创建
    T("inherit_class_creation", "单继承 - 子类创建", { "ctor", "method" }, function(A)
        local CREATE, CTOR = A.create, A.write_ctor
        return function()
            local base = CREATE(mkname("pc"))
            CTOR(base, function(self) self.x = 0 end)
            base.get_x = function(self) return self.x end
            local child = CREATE(mkname("ci"), base)
            CTOR(child, function(self) self.y = 0 end)
        end
    end)
end

do -- 实例创建
    T("instance_creation", "实例创建", { "ctor" }, function(A)
        local C = A.create(mkname("inst"))
        A.write_ctor(C, function(self) self.name = "dog"; self.age = 0 end)
        return A.t_new(C)
    end)
end

do -- 单继承 - 子类实例创建
    T("inherit_instance", "单继承 - 子类实例创建", { "ctor", "method" }, function(A)
        local base = A.create(mkname("ii_base"))
        A.write_ctor(base, function(self) self.x = 0 end)
        A.set_method(base, "get_x", function(self) return self.x end)
        local child = A.create(mkname("ii_child"), base)
        A.write_ctor(child, function(self) self.y = 0 end)
        return A.t_new(child)
    end)
end

do -- 完整生命周期（创建 + 使用 + 删除）
    T("full_lifecycle", "完整生命周期（创建+使用+删除）", { "ctor", "method", "dtor" }, function(A)
        local C = A.create(mkname("life"))
        A.write_ctor(C, function(self) self.x = 1 end)
        A.write_dtor(C, function(self) self.x = nil end)
        A.set_method(C, "add", function(self, n) self.x = self.x + n end)
        -- 建/删实例都在计时体内：形状由适配层在准备期展开
        return A.t_new_use_delete(C, "add", 1)
    end)
end

do -- 实例删除（含析构）
    T("instance_delete", "实例删除（含析构）", { "ctor", "dtor" }, function(A)
        local C = A.create(mkname("del"))
        A.write_ctor(C, function(self) self.data = "hello" end)
        A.write_dtor(C, function(self) self.data = nil end)
        return A.t_new_delete(C)
    end)
end

do -- 析构函数链（3 层，子类先、父类后）
    T("dtor_chain", "析构函数链（3层）", { "ctor", "dtor" }, function(A)
        local ca = A.create(mkname("da"))
        A.write_ctor(ca, function(self) self.a = 1 end)
        A.write_dtor(ca, function(self) self.a = nil end)
        local cb = A.create(mkname("db"), ca)
        A.write_ctor(cb, function(self) self.b = 2 end)
        A.write_dtor(cb, function(self) self.b = nil end)
        local cc = A.create(mkname("dc"), cb)
        A.write_ctor(cc, function(self) self.c = 3 end)
        A.write_dtor(cc, function(self) self.c = nil end)
        return A.t_new_delete(cc)
    end)
end

do -- 构造函数链（3 层）
    T("ctor_chain", "构造函数链（3层）", { "ctor" }, function(A)
        local ca = A.create(mkname("ca"))
        A.write_ctor(ca, function(self) self.a = 1 end)
        local cb = A.create(mkname("cb"), ca)
        A.write_ctor(cb, function(self) self.b = 2 end)
        local cc = A.create(mkname("cc3"), cb)
        A.write_ctor(cc, function(self) self.c = 3 end)
        return A.t_new(cc)
    end)
end

-- ===================== 字段访问 =====================

do -- 单字段读取
    T("single_field_read", "单字段读取", { "ctor" }, function(A)
        local C = A.create(mkname("sfr"))
        A.write_ctor(C, function(self) self.x = 42 end)
        local o = A.obj( C)
        local sink
        return function() sink = o.x end
    end)
end

do -- 单字段写入
    T("single_field_write", "单字段写入", { "ctor" }, function(A)
        local C = A.create(mkname("sfw"))
        A.write_ctor(C, function(self) self.x = 0 end)
        local o = A.obj( C)
        return function() o.x = 99 end
    end)
end

do -- 3 字段读取
    T("field_read_3", "3字段读取（求和）", { "ctor" }, function(A)
        local C = A.create(mkname("fr3"))
        A.write_ctor(C, function(self) self.a = 1; self.b = 2; self.c = 3 end)
        local o = A.obj( C)
        local sink
        return function() sink = o.a + o.b + o.c end
    end)
end

do -- 3 字段写入
    T("field_write_3", "3字段写入（赋值）", { "ctor" }, function(A)
        local C = A.create(mkname("fw3"))
        A.write_ctor(C, function(self) self.a = 0; self.b = 0; self.c = 0 end)
        local o = A.obj( C)
        return function() o.a = 1; o.b = 2; o.c = 3 end
    end)
end

do -- 5 字段读取
    T("field_read_5", "5字段读取（求和）", { "ctor" }, function(A)
        local C = A.create(mkname("fr5"))
        A.write_ctor(C, function(self) self.a=1; self.b=2; self.c=3; self.d=4; self.e=5 end)
        local o = A.obj( C)
        local sink
        return function() sink = o.a + o.b + o.c + o.d + o.e end
    end)
end

do -- 10 字段读取
    T("field_read_10", "10字段读取（求和）", { "ctor" }, function(A)
        local C = A.create(mkname("fr10"))
        A.write_ctor(C, function(self)
            self.a1=1; self.a2=2; self.a3=3; self.a4=4; self.a5=5
            self.a6=6; self.a7=7; self.a8=8; self.a9=9; self.a10=10
        end)
        local o = A.obj( C)
        local sink
        return function()
            sink = o.a1+o.a2+o.a3+o.a4+o.a5+o.a6+o.a7+o.a8+o.a9+o.a10
        end
    end)
end

do -- 字符串字段读取
    T("string_field_read", "字符串字段读取", { "ctor" }, function(A)
        local C = A.create(mkname("strr"))
        A.write_ctor(C, function(self) self.name = "hello world" end)
        local o = A.obj( C)
        local sink
        return function() sink = o.name end
    end)
end

do -- 布尔字段读取
    T("bool_field_read", "布尔字段读取", { "ctor" }, function(A)
        local C = A.create(mkname("boolr"))
        A.write_ctor(C, function(self) self.active = true end)
        local o = A.obj( C)
        local sink
        return function() sink = o.active end
    end)
end

do -- 继承字段读取
    T("inherited_field_read", "继承字段读取", { "ctor" }, function(A)
        local base = A.create(mkname("ifr_b"))
        A.write_ctor(base, function(self) self.base_val = 42 end)
        local child = A.create(mkname("ifr_c"), base)
        A.write_ctor(child, function(self) self.child_val = 99 end)
        local o = A.obj( child)
        local sink
        return function() sink = o.base_val end
    end)
end

do -- COW 默认值读取（类成员默认值，读路径不复制）
    T("cow_default_read", "COW 默认值读取（类表默认值）", { "default" }, function(A)
        local C = A.create(mkname("cowr"))
        A.set_default(C, "hp", 100)
        -- 四列同为"类表默认值 + 实例读穿透"：实例上不落该字段，读取时穿透到类表 / vTable
        local o = A.new_bare and A.new_bare(C) or A.obj( C)
        local sink
        return function() sink = o.hp end
    end)
end

do -- COW 写入后读取
    T("cow_write_then_read", "COW 写入后读取", { "default" }, function(A)
        local C = A.create(mkname("cowrw"))
        A.set_default(C, "hp", 100)
        local o = A.new_bare and A.new_bare(C) or A.obj( C)
        local sink
        return function() o.hp = 80; sink = o.hp end
    end)
end

do -- 多实例同名字段读取
    T("multi_instance_field_read", "多实例同名字段读取", { "ctor" }, function(A)
        local C = A.create(mkname("mir"))
        A.write_ctor(C, function(self) self.x = 1 end)
        local a = A.obj( C)
        local b = A.obj( C)
        b.x = 2
        local sink
        return function() sink = a.x + b.x end
    end)
end

-- ===================== 方法调用 =====================

do -- 方法调用（无参）
    T("method_call", "方法调用（无参）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mc0"))
        A.write_ctor(C, function(self) self.val = 0 end)
        A.set_method(C, "inc", function(self) self.val = self.val + 1 end)
        local o = A.obj( C)
        return function() o:inc() end
    end)
end

do -- 方法调用（1 参数）
    T("method_call_1arg", "方法调用（1参数）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mc1"))
        A.write_ctor(C, function(self) self.val = 0 end)
        A.set_method(C, "add", function(self, n) self.val = self.val + n end)
        local o = A.obj( C)
        return function() o:add(1) end
    end)
end

do -- 方法调用（3 参数）
    T("method_call_3args", "方法调用（3参数）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mc3"))
        A.write_ctor(C, function(self) self.x = 0; self.y = 0; self.z = 0 end)
        A.set_method(C, "move", function(self, dx, dy, dz)
            self.x = self.x + dx; self.y = self.y + dy; self.z = self.z + dz
        end)
        local o = A.obj( C)
        return function() o:move(1, 2, 3) end
    end)
end

do -- 方法调用（带返回值）
    T("method_call_return", "方法调用（带返回值）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mcr"))
        A.write_ctor(C, function(self) self.val = 42 end)
        A.set_method(C, "get_val", function(self) return self.val end)
        local o = A.obj( C)
        local sink
        return function() sink = o:get_val() end
    end)
end

do -- 方法内访问自身字段
    T("method_call_self_field", "方法调用（内访自身字段）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mcsf"))
        A.write_ctor(C, function(self) self.x = 10; self.y = 20 end)
        A.set_method(C, "sum", function(self) return self.x + self.y end)
        local o = A.obj( C)
        local sink
        return function() sink = o:sum() end
    end)
end

do -- 方法内调用另一方法（委托）
    T("method_call_delegate", "方法调用（内部委托）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mcd"))
        A.write_ctor(C, function(self) self.val = 0 end)
        A.set_method(C, "_inner", function(self, n) self.val = self.val + n end)
        A.set_method(C, "delegate", function(self) self:_inner(1) end)
        local o = A.obj( C)
        return function() o:delegate() end
    end)
end

do -- 5 方法轮换调用
    T("method_call_5methods", "5方法轮换调用", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mc5"))
        A.write_ctor(C, function(self) self.v = 0 end)
        A.set_method(C, "m1", function(self) self.v = self.v + 1 end)
        A.set_method(C, "m2", function(self) self.v = self.v + 2 end)
        A.set_method(C, "m3", function(self) self.v = self.v + 3 end)
        A.set_method(C, "m4", function(self) self.v = self.v + 4 end)
        A.set_method(C, "m5", function(self) self.v = self.v + 5 end)
        local o = A.obj( C)
        return function() o:m1(); o:m2(); o:m3(); o:m4(); o:m5() end
    end)
end

do -- 继承方法调用
    T("inherited_method_call", "继承方法调用", { "ctor", "method" }, function(A)
        local base = A.create(mkname("imc_b"))
        A.write_ctor(base, function(self) self.val = 0 end)
        A.set_method(base, "add", function(self, n) self.val = self.val + n end)
        local child = A.create(mkname("imc_c"), base)
        A.write_ctor(child, function(self) self.child_val = 0 end)
        local o = A.obj( child)
        return function() o:add(1) end
    end)
end

do -- 热更新后方法调用
    T("hotupdate_method", "热更新后方法调用", { "ctor", "method", "redefine" }, function(A)
        local C = A.create(mkname("hot"))
        A.write_ctor(C, function(self) self.val = 1 end)
        A.set_method(C, "compute", function(self) return self.val * 2 end)
        local o = A.obj( C)
        A.redefine(C, "compute", function(self) return self.val * 3 end)
        local sink
        return function() sink = o:compute() end
    end)
end

-- ===================== 继承深度 =====================

-- 10 层继承链每个实现只建一次（进程内按实现缓存），方法项与字段项共用
local chain_cache = setmetatable({}, { __mode = "k" })
local function dchain(A)
    local cached = chain_cache[A]
    if cached then return cached end
    local D = {}
    for i = 1, 10 do
        local cls = A.create(mkname("d" .. i), D[i - 1])
        A.write_ctor(cls, function(self) self.level = i end)
        if i == 1 then
            A.set_method(cls, "method", function(self) return self.level end)
        end
        D[i] = cls
    end
    local chain = {
        o1  = A.obj( D[2]),
        o2  = A.obj( D[3]),
        o3  = A.obj( D[4]),
        o5  = A.obj( D[6]),
        o10 = A.obj( D[10]),
    }
    chain_cache[A] = chain
    return chain
end

local DEPTHS = {
    { 1, "o1" },
    { 2, "o2" },
    { 3, "o3" },
    { 5, "o5" },
    { 10, "o10" },
}

for _, d in ipairs(DEPTHS) do
    local depth, slot = d[1], d[2]
    T("inherit" .. depth .. "_method", depth .. "层继承方法调用", { "ctor", "method" }, function(A)
        local o = dchain(A)[slot]
        local sink
        return function() sink = o:method() end
    end)
    T("inherit" .. depth .. "_field", depth .. "层继承字段读取", { "ctor", "method" }, function(A)
        local o = dchain(A)[slot]
        local sink
        return function() sink = o.level end
    end)
end

-- ===================== 综合/压力 =====================

do -- 混合操作（创建 + 读写 + 方法）
    T("mixed_operations", "混合操作（创建+读写+方法）", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mix"))
        A.write_ctor(C, function(self, x, y) self.x = x or 0; self.y = y or 0 end)
        A.set_method(C, "move", function(self, dx, dy) self.x = self.x + dx; self.y = self.y + dy end)
        A.set_method(C, "distance", function(self)
            return math.sqrt(self.x * self.x + self.y * self.y)
        end)
        -- 建实例(1, 2) → move(3, 4) → distance()：形状由适配层在准备期展开
        return A.t_new_call2(C, 1, 2, "move", 3, 4, "distance")
    end)
end

do -- 10 字段类读写
    T("many_fields_rw", "10字段类读写", { "ctor" }, function(A)
        local C = A.create(mkname("mf"))
        A.write_ctor(C, function(self)
            self.f1=1; self.f2=2; self.f3=3; self.f4=4; self.f5=5
            self.f6=6; self.f7=7; self.f8=8; self.f9=9; self.f10=10
        end)
        local o = A.obj( C)
        local sink
        return function()
            o.f1=11; o.f2=12; o.f3=13
            sink = o.f1+o.f2+o.f3+o.f4+o.f5+o.f6+o.f7+o.f8+o.f9+o.f10
        end
    end)
end

do -- 10 方法类调用
    T("many_methods_call", "10方法类调用", { "ctor", "method" }, function(A)
        local C = A.create(mkname("mm"))
        A.write_ctor(C, function(self) self.v = 0 end)
        for i = 1, 10 do
            A.set_method(C, "m" .. i, function(self) self.v = self.v + 1 end)
        end
        local o = A.obj( C)
        return function()
            o:m1(); o:m2(); o:m3(); o:m4(); o:m5()
            o:m6(); o:m7(); o:m8(); o:m9(); o:m10()
        end
    end)
end

-- ============================================================
-- 运行与输出
-- ============================================================

local function run(raw)
    for _, A in ipairs(raw) do Adapter.validate(A) end
    local impls = {}
    for i, A in ipairs(raw) do impls[i] = Adapter.norm(A) end

    local n_impl = #impls
    local ref_i, lower_i
    for i, A in ipairs(impls) do
        if A.reference then ref_i = i end
        if A.lower_bound then lower_i = i end
    end
    ref_i = ref_i or n_impl
    local ref = impls[ref_i]

    -- 倍率列：每个"非参照且非下界"的实现一列
    local ratio_idx = {}
    for i, A in ipairs(impls) do
        if i ~= ref_i and i ~= lower_i then ratio_idx[#ratio_idx + 1] = i end
    end

    local results = {}
    for _, e in ipairs(TESTS) do results[e.key] = {} end

    for _, e in ipairs(TESTS) do
        local fns = {}
        for i, A in ipairs(impls) do
            if Adapter.req_ok(Adapter.caps_of(A), e.requires) then
                local op = A.ops and A.ops[e.key]
                fns[i] = op and op(ctx) or e.make(A)
            end
        end
        for i = 1, n_impl do
            if fns[i] then
                results[e.key][i] = bench(ITER[e.key] or 1000000, fns[i])
            end
        end
    end

    return impls, ref_i, ref, lower_i, ratio_idx, results
end

local function report(impls, ref_i, ref, lower_i, ratio_idx, results)
    local n_impl = #impls

    local titles = {}
    for i, A in ipairs(impls) do titles[i] = A.label end

    local LBLW = 0
    for _, e in ipairs(TESTS) do
        local w = dwidth(e.label)
        if w > LBLW then LBLW = w end
    end
    LBLW = LBLW + 2

    -- cells 为已格式化的定宽字符串（表头传列名，数据行传 fnum 结果）
    local function fmt_row(label, cells, rats)
        local parts = {}
        for i = 1, n_impl do parts[i] = cells[i] end
        local s = "  " .. pad_right(label, LBLW) .. "  " .. table.concat(parts, "  ")
        if #rats > 0 then
            local rp = {}
            for i = 1, #rats do rp[i] = string.format("%-9s", rats[i]) end
            s = s .. "   " .. table.concat(rp, " ")
        end
        return s
    end

    print("============================================================")
    print("  共有功能对比基准：" .. table.concat(titles, " / "))
    print("  " .. _VERSION .. "  |  " .. os.date("%Y-%m-%d %H:%M:%S"))
    print("============================================================")

    print("\n╔════════════════════════════════════════════════════════════════════════╗")
    print("║  共有功能对比（" .. table.concat(titles, " / ") .. "）")
    print("╚════════════════════════════════════════════════════════════════════════╝")
    print("")

    -- 表头
    do
        local head = {}
        local subs = {}
        for i = 1, n_impl do
            head[i] = pad_left(titles[i], 8)
            subs[i] = pad_left("(us/op)", 8)
        end
        local rats, rsubs = {}, {}
        for i = 1, #ratio_idx do
            rats[i]  = "vs " .. titles[ratio_idx[i]]
            rsubs[i] = ""
        end
        print(fmt_row("测试项", head, rats))
        print(fmt_row(string.rep("-", LBLW - 2), subs, rsubs))
    end
    print("")

    for _, e in ipairs(TESTS) do
        local r = results[e.key]
        local cells, rats = {}, {}
        for i = 1, n_impl do cells[i] = fnum(r[i]) end
        for i = 1, #ratio_idx do
            local j = ratio_idx[i]
            rats[i] = ratio_text(r[ref_i], r[j])
        end
        print(fmt_row(e.label, cells, rats))
    end

    -- ====================== 汇总 ======================
    print("\n╔══════════════════════════════════════════════════════════════╗")
    print("║  汇总分析                                                    ║")
    print("╚══════════════════════════════════════════════════════════════╝")
    print("")

    print(string.format("  共有功能 (%d 项):", #TESTS))

    for i, A in ipairs(impls) do
        if i ~= ref_i then
            local win, lose, tie, na = 0, 0, 0, 0
            local win_items, lose_items = {}, {}
            for _, e in ipairs(TESTS) do
                local r = results[e.key]
                local mine, keep = r[i], r[ref_i]
                if not mine then
                    na = na + 1
                elseif keep then
                    local ratio = r[ref_i] / mine     -- >1 表示本实现更快
                    if ratio > 1.005 then
                        win = win + 1
                        win_items[#win_items + 1] = { e.label, ratio }
                    elseif ratio < 0.995 then
                        lose = lose + 1
                        lose_items[#lose_items + 1] = { e.label, ratio }
                    else
                        tie = tie + 1
                    end
                end
            end
            local cmp = #TESTS - na
            if i == lower_i then
                -- 下界参考列只报不适用项数；领先/落后统计由下面"相对下界"一行给出，避免重复
                print(string.format("    %s: 不适用 %d 项 (可比 %d 项)", A.label, na, cmp))
            else
                print(string.format("    %s: %s 领先 %d 项 | %s 领先 %d 项 | 持平 %d 项 | 不适用 %d 项 (可比 %d 项)",
                    A.label, A.label, win, ref.label, lose, tie, na, cmp))
            end
            if na > 0 then
                local na_labels = {}
                for _, e in ipairs(TESTS) do
                    if not results[e.key][i] then na_labels[#na_labels + 1] = e.label end
                end
                print("      不适用项: " .. table.concat(na_labels, "、"))
            end
            if i ~= lower_i then
                if #win_items > 0 then
                    print(string.format("    %s 领先 %s 的项:", A.label, ref.label))
                    for _, it in ipairs(win_items) do
                        print(string.format("      • %s (%.2fx 快)", it[1], it[2]))
                    end
                end
                if #lose_items > 0 then
                    print(string.format("    %s 领先的项:", ref.label))
                    for _, it in ipairs(lose_items) do
                        print(string.format("      • %s (%.2fx 慢)", it[1], 1 / it[2]))
                    end
                end
            end
        end
    end

    if lower_i then
        local faster, slower, tie = 0, 0, 0
        for _, e in ipairs(TESTS) do
            local lb, mine = results[e.key][lower_i], results[e.key][ref_i]
            if lb and mine then
                local ratio = mine / lb
                if ratio < 0.995 then
                    faster = faster + 1
                elseif ratio > 1.005 then
                    slower = slower + 1
                else
                    tie = tie + 1
                end
            end
        end
        print(string.format("    相对%s下界: %s 更快 %d 项 | 更慢 %d 项 | 持平 %d 项",
            impls[lower_i].label, ref.label, faster, slower, tie))
    end

    -- ====================== 明细 ======================
    -- 紧凑数值/倍率格式
    local function f6(us) return us and string.format("%.3f", us) or "  n/a" end
    local function r6(ref_us, us)
        return ref_us and us and string.format("%.2fx", ref_us / us) or "n/a"
    end

    local NLW = 0
    for _, i in ipairs(ratio_idx) do
        local w = dwidth(impls[i].label)
        if w > NLW then NLW = w end
    end

    local function fmt_compact(label, r)
        local parts = {}
        for i = 1, n_impl do parts[i] = pad_right(titles[i], NLW) .. " " .. f6(r[i]) end
        local s = "    " .. pad_right(label, LBLW - 2) .. "  " .. table.concat(parts, "  ")
        local rats = {}
        for i = 1, #ratio_idx do
            local j = ratio_idx[i]
            rats[i] = "vs " .. titles[j] .. " " .. r6(r[ref_i], r[j])
        end
        if #rats > 0 then s = s .. "  (" .. table.concat(rats, " / ") .. ")" end
        return s
    end

    print("\n  ── 热路径专项（单层字段/方法） ──")
    local hot_keys = {
        { "single_field_read",  "单字段读取" },
        { "single_field_write", "单字段写入" },
        { "field_read_3",       "3字段读取" },
        { "method_call",        "方法调用" },
        { "method_call_1arg",   "方法调用(1参数)" },
        { "method_call_return", "方法调用(返回值)" },
    }
    for _, entry in ipairs(hot_keys) do
        local r = results[entry[1]]
        if r then print(fmt_compact(entry[2], r)) end
    end

    print("\n  ── 继承深度趋势 ──")
    print("  方法调用:")
    for _, depth in ipairs({ 1, 2, 3, 5, 10 }) do
        local r = results["inherit" .. depth .. "_method"]
        if r then print(fmt_compact(depth .. "层:", r)) end
    end
    print("  字段读取:")
    for _, depth in ipairs({ 1, 2, 3, 5, 10 }) do
        local r = results["inherit" .. depth .. "_field"]
        if r then print(fmt_compact(depth .. "层:", r)) end
    end

    print("")
    print("============================================================")
    print("  测试完成")
    print("============================================================")
end

local function Test(...)
    local impls = {}
    for i = 1, select("#", ...) do
        local A = select(i, ...)
        assert(type(A) == "table",
            "Test 的实参必须都是实现表，第 " .. i .. " 个是 " .. type(A))
        impls[#impls + 1] = A
    end
    report(run(impls))
end

-- ============================================================
-- 入口
--
-- 默认：自动收集 impls/ 下全部适配层，扫描到几个实现就出几列（列顺序＝适配层里的 order）。
-- 想临时只跑其中几个：把不需要的适配层文件移出 impls/，或把下面这行换成显式传表，例如
--   local impls = Adapter.discover()   -- 按列顺序排好的实现表数组
--   Test(impls[1], impls[3])           -- 只跑第 1、3 列
-- ============================================================

Test(table.unpack(Adapter.discover()))

return Test

