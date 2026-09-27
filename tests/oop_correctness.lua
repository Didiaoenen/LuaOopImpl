--[[
-- LuaOOP 优化后全面正确性测试
-- 覆盖：属性(get/set/opt)、单例、多继承、热更新(vTable缓存失效)、
--       菱形继承、成员默认值(copy-on-write)、Null检查、深层继承、压力测试
-- ]]

-- 路径引导：本脚本位于 tests/，仓库根目录即其上一级。
-- 按脚本自身位置解析，从任意工作目录运行结果一致（不依赖 CWD 的 ./?.lua）。
local _dir  = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*[\\/])") or ""
local _sep  = package.config:sub(1, 1)
local _root = _dir .. ".." .. _sep
package.path = table.concat({
    _root .. "?.lua",
    _root .. "?.lua.txt",
    _root .. "LuaOOP" .. _sep .. "?.lua.txt",
    _root .. "LuaOOP" .. _sep .. "?.lua",
    package.path,
}, ";")

require("LuaOOP.Class")
local class = class

local passed = 0
local failed = 0

local function check(name, condition)
    if condition then
        passed = passed + 1
        print("  [PASS] " .. name)
    else
        failed = failed + 1
        print("  [FAIL] " .. name)
    end
end

-- ============================================================
-- 1. 属性 (get/set/opt)
-- ============================================================
print("\n[1] 属性 (get/set/opt)")

do
    local Vec2 = class("Vec2")

    Vec2.ctor = function(self, x, y)
        self.x = x or 0
        self.y = y or 0
        self.nx = 0
        self.ny = 0
        self._label = "unnamed"
    end

    -- get 属性：只读计算属性
    Vec2.get.magnitude = function(self)
        return math.sqrt(self.x * self.x + self.y * self.y)
    end

    -- set 属性：写入拦截
    Vec2.set.normalized = function(self, v)
        self.nx = v.x
        self.ny = v.y
    end

    -- opt 属性：可选读写
    Vec2.opt.label = function(self, v)
        if v then self._label = v else return self._label end
    end

    local v = Vec2.new(3, 4)
    check("get 属性 - magnitude", v.magnitude == 5.0)
    check("get 属性 - 多次访问一致", v.magnitude == 5.0)

    v.normalized = {x = 1, y = 0}
    check("set 属性 - normalized 写入", v.nx == 1 and v.ny == 0)

    -- opt 属性通过属性语法访问：读 v.label 调用 getter，写 v.label = value 调用 setter
    check("opt 属性 - 读取默认值", v.label == "unnamed")  -- ctor 中设置了 self._label = "unnamed"
    v.label = "myvec"
    check("opt 属性 - 设置后读取", v.label == "myvec")
end

-- ============================================================
-- 2. 单例
-- ============================================================
print("\n[2] 单例")

do
    local Config = class("Config2")
    Config.ctor = function(self)
        self.value = 42
    end
    Config.__singleton = function()
        return Config.new()
    end

    local inst1 = Config.Instance
    local inst2 = Config.Instance
    check("单例 - 多次获取同一实例", inst1 == inst2)
    check("单例 - 值正确", inst1.value == 42)
end

-- ============================================================
-- 3. 多继承
-- ============================================================
print("\n[3] 多继承")

do
    local A = class("MA")
    A.ctor = function(self) self.a = 1 end
    A.method_a = function(self) return "a" end

    local B = class("MB")
    B.ctor = function(self) self.b = 2 end
    B.method_b = function(self) return "b" end

    local C = class("MC", A, B)
    C.ctor = function(self)
        A.ctor(self)
        B.ctor(self)
        self.c = 3
    end

    local obj = C.new()
    check("多继承 - 第一个基类方法", obj:method_a() == "a")
    check("多继承 - 第二个基类方法", obj:method_b() == "b")
    check("多继承 - 字段初始化", obj.a == 1 and obj.b == 2 and obj.c == 3)
    check("多继承 - as 类型检查", obj:as(C) and obj:as(A) and obj:as(B))
end

-- ============================================================
-- 4. 热更新 (vTable 缓存失效)
-- ============================================================
print("\n[4] 热更新 (vTable 缓存失效)")

do
    local Base = class("HotBase")
    Base.ctor = function(self) self.val = 0 end
    Base.compute = function(self) return self.val * 2 end

    local Child = class("HotChild", Base)
    Child.ctor = function(self) Base.ctor(self); self.extra = 10 end

    local obj = Child.new()
    obj.val = 5
    check("热更新 - 初始方法结果 (5*2)", obj:compute() == 10)

    -- 热更新：修改基类方法
    Base.compute = function(self) return self.val * 3 end

    -- 已存在实例的 vTable 可能缓存了旧方法；InvalidateCache 应递归清掉子类缓存，
    -- 使该实例下次访问重新查找父类 vTable，从而拿到新方法（15 而非 10）
    check("热更新 - 基类方法更新后已存在实例用新方法 (5*3)", obj:compute() == 15)

    -- 新实例应该用新方法
    local obj2 = Child.new()
    obj2.val = 4
    check("热更新 - 新实例使用新方法 (4*3)", obj2:compute() == 12)

    -- 热更新：给子类添加新方法
    Child.new_method = function(self) return 999 end
    local obj3 = Child.new()
    check("热更新 - 子类新增方法对新实例可见", obj3:new_method() == 999)
    check("热更新 - 子类新增方法对旧实例可见（实例 __index 正指向该 vTable）", obj:new_method() == 999)
end

-- ============================================================
-- 5. 菱形继承（钻石继承）
-- ============================================================
print("\n[5] 菱形继承")

do
    local Root = class("DiamondRoot")
    Root.ctor = function(self) self.root_val = 1 end
    Root.root_method = function(self) return "root" end

    local Left = class("DiamondLeft", Root)
    Left.ctor = function(self) Root.ctor(self); self.left_val = 2 end

    local Right = class("DiamondRight", Root)
    Right.ctor = function(self) Root.ctor(self); self.right_val = 3 end

    local Diamond = class("DiamondChild", Left, Right)
    Diamond.ctor = function(self)
        Left.ctor(self)
        Right.ctor(self)
        self.diamond_val = 4
    end

    local obj = Diamond.new()
    check("菱形继承 - 根类方法可访问", obj:root_method() == "root")
    check("菱形继承 - 类型检查", obj:as(Root) and obj:as(Left) and obj:as(Right))
    check("菱形继承 - 字段正确", obj.diamond_val == 4)
end

-- ============================================================
-- 6. 成员默认值 (copy-on-write via vTable)
-- ============================================================
print("\n[6] 成员默认值 (copy-on-write)")

do
    local Entity = class("COWEntity")
    Entity.ctor = function(self)
        -- 默认值通过 vTable __index 提供
    end

    -- 设置非函数成员（存入 ClassesMembers，由 vTable 提供默认值）
    Entity.hp = 100
    Entity.mp = 50
    Entity.name = "unknown"

    local e1 = Entity.new()
    local e2 = Entity.new()

    check("COW - 默认值可读(hp)", e1.hp == 100)
    check("COW - 默认值可读(mp)", e1.mp == 50)
    check("COW - 默认值可读(name)", e1.name == "unknown")

    -- 写入时 copy-on-write
    e1.hp = 80
    check("COW - 写入不影响另一实例", e2.hp == 100)
    check("COW - 写入后新值生效", e1.hp == 80)
end

-- ============================================================
-- 7. 析构链正确性
-- ============================================================
print("\n[7] 析构链正确性")

do
    local log = {}

    local A = class("DtorA")
    A.ctor = function(self) table.insert(log, "A.ctor") end
    A.dtor = function(self) table.insert(log, "A.dtor") end

    local B = class("DtorB", A)
    B.ctor = function(self) A.ctor(self); table.insert(log, "B.ctor") end
    B.dtor = function(self) table.insert(log, "B.dtor") end

    local C = class("DtorC", B)
    C.ctor = function(self) B.ctor(self); table.insert(log, "C.ctor") end
    C.dtor = function(self) table.insert(log, "C.dtor") end

    log = {}
    local obj = C.new()
    check("析构链 - 构造顺序", #log == 3 and log[1] == "A.ctor")

    log = {}
    obj:delete()
    check("析构链 - 析构调用数量", #log == 3)
    -- 析构顺序应为 C → B → A（与原 CascadeDelete 一致：子类先，父类后）
    check("析构链 - 析构顺序 C→B→A", log[1] == "C.dtor" and log[2] == "B.dtor" and log[3] == "A.dtor")
end

-- ============================================================
-- 8. Null 检查 / 死亡标记
-- ============================================================
print("\n[8] Null 检查 / 死亡标记")

do
    local ClassImpl2 = require("LuaOOP.ClassImpl")

    local Entity = class("NullEntity")
    Entity.ctor = function(self) self.alive = true end

    local obj = Entity.new()
    check("Null - 活对象非 Null", not ClassImpl2.Null(obj))

    obj:delete()
    check("Null - 已删除对象为 Null", ClassImpl2.Null(obj))
    check("Null - nil 为 Null", ClassImpl2.Null(nil))
    check("Null - false 为 Null", ClassImpl2.Null(false))
end

-- ============================================================
-- 9. 深层继承链
-- ============================================================
print("\n[9] 深层继承链")

do
    local depth = 10
    local classes = {}

    classes[1] = class("Deep1")
    classes[1].ctor = function(self) self.level = 1 end
    classes[1].method = function(self) return self.level end

    for i = 2, depth do
        classes[i] = class("Deep" .. i, classes[i - 1])
        classes[i].ctor = function(self)
            classes[i - 1].ctor(self)
            self.level = i
        end
    end

    local obj = classes[depth].new()
    check("深层继承 - 构造正确", obj.level == depth)
    check("深层继承 - 继承方法可调用", obj:method() == depth)
    check("深层继承 - as 类型检查", obj:as(classes[1]))
end

-- ============================================================
-- 10. 大量实例压力测试
-- ============================================================
print("\n[10] 大量实例压力测试")

do
    local Item = class("Item")
    Item.ctor = function(self, id)
        self.id = id
        self.name = "item_" .. id
        self.count = 1
    end
    Item.get_info = function(self)
        return self.name .. ":" .. self.count
    end

    local N = 50000
    local items = {}
    for i = 1, N do
        items[i] = Item.new(i)
    end

    -- 全量访问一遍：确认大批实例下方法调用与字段读取均正常
    for i = 1, N do
        local info = items[i]:get_info()
    end

    check("压力测试 - 全部创建成功", items[1] ~= nil and items[N] ~= nil)
    check("压力测试 - 数据正确", items[N // 2].id == N // 2)

    for i = 1, N do
        items[i]:delete()
    end
end

-- ============================================================
-- 11. 属性读取值正确性
-- ============================================================
print("\n[11] 属性读取值正确性")

do
    local Point = class("Point")
    Point.get.distance = function(self)
        return math.sqrt(self.x * self.x + self.y * self.y)
    end
    Point.ctor = function(self, x, y)
        self.x = x or 0
        self.y = y or 0
    end

    local p = Point.new(3, 4)
    check("属性读取 - getter 计算值正确", p.distance == 5.0)
end

-- ============================================================
-- 12. 类字段重赋值后实例读到新值
-- ============================================================
print("\n[12] 类字段重赋值后实例读到新值")

do
    local A = class("FieldRedefA")
    A.ctor = function(self)
        -- 不设置字段，让它走 vTable 默认值
    end
    A.x = 1

    local o = A.new()
    check("字段重赋值 - 初始值 o.x == 1", o.x == 1)

    -- 重赋值类字段（不应被已存在实例的旧读取结果遮蔽）
    A.x = 2
    check("字段重赋值 - 重赋值后 o.x == 2", o.x == 2)

    A.x = 3
    check("字段重赋值 - 再次重赋值 o.x == 3", o.x == 3)
end

-- ============================================================
-- 13. 父类方法热更新后子类实例读到新方法
-- ============================================================
print("\n[13] 父类方法热更新后子类实例读到新方法")

do
    local Base = class("HotMethodBase")
    Base.ctor = function(self) self.val = 0 end
    Base.compute = function(self) return self.val * 2 end

    local Child = class("HotMethodChild", Base)
    Child.ctor = function(self) Base.ctor(self) end

    local obj = Child.new()
    check("方法热更新 - 初始 compute() == 0", obj:compute() == 0)

    obj.val = 5
    check("方法热更新 - compute(5*2) == 10", obj:compute() == 10)

    -- 热更新基类方法：子类 vTable 里缓存下来的旧方法必须被清掉
    Base.compute = function(self) return self.val * 3 end
    check("方法热更新 - 已存在实例 compute(5*3) == 15", obj:compute() == 15)

    -- 新实例也应用新方法
    local obj2 = Child.new()
    obj2.val = 4
    check("方法热更新 - 新实例 compute(4*3) == 12", obj2:compute() == 12)
end

-- ============================================================
-- 14. 方法改成 getter 后子类实例按 getter 求值
-- ============================================================
print("\n[14] 方法改成 getter 后子类实例按 getter 求值")

do
    local Base = class("MethodToGetBase")
    Base.ctor = function(self) self._val = 42 end
    Base.getval = function(self) return self._val end

    local Child = class("MethodToGetChild", Base)
    Child.ctor = function(self) Base.ctor(self) end

    local obj = Child.new()
    -- 先以方法调用，让子类 vTable 缓存下同名方法
    check("方法改 getter - 初始 getval() == 42", obj:getval() == 42)

    -- 将方法改为 getter 属性
    Base.get.getval = function(self) return self._val * 10 end

    -- 子类实例应读到 getter，而非 vTable 里的旧方法
    check("方法改 getter - 改为 getter 后 getval == 420", obj.getval == 420)
end

-- ============================================================
-- 15. 析构顺序全序列（三层，构造与析构都要校验次序）
-- ============================================================
print("\n[15] 析构顺序全序列（三层）")

do
    local log = {}

    local X = class("DtorOrderX")
    X.ctor = function(self) table.insert(log, "X.ctor") end
    X.dtor = function(self) table.insert(log, "X.dtor") end

    local Y = class("DtorOrderY", X)
    Y.ctor = function(self) X.ctor(self); table.insert(log, "Y.ctor") end
    Y.dtor = function(self) table.insert(log, "Y.dtor") end

    local Z = class("DtorOrderZ", Y)
    Z.ctor = function(self) Y.ctor(self); table.insert(log, "Z.ctor") end
    Z.dtor = function(self) table.insert(log, "Z.dtor") end

    log = {}
    local obj = Z.new()
    check("析构顺序 - 构造顺序 X→Y→Z", log[1] == "X.ctor" and log[2] == "Y.ctor" and log[3] == "Z.ctor")

    log = {}
    obj:delete()
    check("析构顺序 - 析构顺序 Z→Y→X", log[1] == "Z.dtor" and log[2] == "Y.dtor" and log[3] == "X.dtor")
end

-- ============================================================
-- 16. 祖先 dtor 热更新后孙子类析构链重建
-- ============================================================
print("\n[16] 祖先 dtor 热更新后孙子类析构链重建")

do
    local log = {}

    local A = class("DtorHotA")
    A.dtor = function(self) table.insert(log, "A1") end

    local B = class("DtorHotB", A)
    B.dtor = function(self) table.insert(log, "B1") end

    local C = class("DtorHotC", B)
    C.dtor = function(self) table.insert(log, "C1") end

    -- 先验证初始析构顺序
    log = {}
    local obj1 = C.new()
    obj1:delete()
    check("dtor 热更新 - 初始析构顺序 C1→B1→A1", log[1] == "C1" and log[2] == "B1" and log[3] == "A1")

    -- 热更新 A 的 dtor：孙子类 C 的析构链必须被递归重建
    A.dtor = function(self) table.insert(log, "A2") end

    log = {}
    local obj2 = C.new()
    obj2:delete()
    check("dtor 热更新 - 热更新 A.dtor 后 C 实例析构含 A2",
        log[1] == "C1" and log[2] == "B1" and log[3] == "A2")

    -- 热更新 B 的 dtor
    B.dtor = function(self) table.insert(log, "B2") end

    log = {}
    local obj3 = C.new()
    obj3:delete()
    check("dtor 热更新 - 热更新 B.dtor 后 C 实例析构含 B2+A2",
        log[1] == "C1" and log[2] == "B2" and log[3] == "A2")
end

-- ============================================================
-- [17] 多继承优先级统一：方法 / 属性 / 成员默认值 一律"先声明优先"
-- ============================================================
print("\n[17] 多继承优先级统一（先声明优先）")

do
    local P1 = class("Prio_P1")
    P1.v = 10
    P1.m = function(self) return "p1" end
    P1.set.s = function(self, x) self._s = x end

    local P2 = class("Prio_P2")
    P2.v = 20
    P2.m = function(self) return "p2" end
    P2.set.s = function(self, x) self._s = x * 100 end

    local MI = class("Prio_MI", P1, P2)

    check("多继承 - 方法先声明优先", MI.new():m() == "p1")
    check("多继承 - 成员默认值先声明优先", MI.new().v == 10)

    local o = MI.new()
    o.s = 1
    check("多继承 - 属性先声明优先", o._s == 1)

    -- 低优先级基类热更新不应击穿高优先级基类
    P2.v = 200
    P2.m = function(self) return "p2b" end
    check("多继承 - 低优先级基类改成员默认值不击穿", MI.new().v == 10)
    check("多继承 - 低优先级基类改方法不击穿", MI.new():m() == "p1")

    -- 高优先级基类热更新应生效
    P1.v = 11
    P1.m = function(self) return "p1b" end
    check("多继承 - 高优先级基类改成员默认值生效", MI.new().v == 11)
    check("多继承 - 高优先级基类改方法生效", MI.new():m() == "p1b")

    -- 已存在实例同样要看到变化
    local o2 = MI.new()
    P1.v = 12
    check("多继承 - 已存在实例看到高优先级热更新", o2.v == 12)
    P2.v = 999
    check("多继承 - 已存在实例不受低优先级热更新影响", o2.v == 12)

    -- 高优先级基类删除该成员 -> 回落到次优先级基类
    P1.v = nil
    check("多继承 - 高优先级删除后回落到次优先级基类", MI.new().v == 999)
    check("多继承 - 已存在实例同样回落到次优先级基类", o2.v == 999)
    P1.v = 10

    -- 子类自有声明不被父类热更新击穿
    local OC = class("Prio_OC", P1, P2)
    OC.v = 99
    OC.m = function(self) return "oc" end
    P1.v = 13
    P1.m = function(self) return "p1c" end
    check("多继承 - 子类自有成员默认值不被击穿", OC.new().v == 99)
    check("多继承 - 子类自有方法不被击穿", OC.new():m() == "oc")

    -- 深层继承链 + 多继承混合
    local A = class("Prio_A"); A.deep = 1; A.dm = function(self) return "a" end
    local B = class("Prio_B", A)
    local C = class("Prio_C", B)
    check("深层继承 - 成员默认值", C.new().deep == 1)
    A.deep = 5
    A.dm = function(self) return "a2" end
    check("深层继承 - 成员默认值热更新", C.new().deep == 5)
    check("深层继承 - 方法热更新", C.new():dm() == "a2")

    local P2b = class("Prio_P2b"); P2b.deep = 777
    local MI2 = class("Prio_MI2", B, P2b)
    check("多继承混合 - 先声明链优先", MI2.new().deep == 5)
end

-- ============================================================
-- [18] 成员默认值改写为属性（缓存失效与优先级）
-- ============================================================
print("\n[18] 成员默认值改写为属性")

do
    -- 成员默认值 -> get 属性
    local A = class("Edge_A"); A.x = 1
    local B = class("Edge_B", A)
    local b = B.new()
    check("改写 - 初始继承成员默认值", b.x == 1)
    A.get.x = function() return 100 end
    check("改写 - 成员默认值改成 get 属性后已存在实例可见", b.x == 100)

    -- 后代自有同名默认值不被清掉
    local C = class("Edge_C", A); C.x = 99
    A.get.x = function() return 101 end
    check("改写 - 后代自有同名成员默认值不被清掉", C.new().x == 99)

    -- 多继承：低优先级基类改写属性不应击穿高优先级基类的成员默认值
    local Q1 = class("Edge_Q1"); Q1.k = 1
    local Q2 = class("Edge_Q2"); Q2.k = 2
    local MI = class("Edge_MI", Q1, Q2)
    check("改写 - 多继承初始先声明优先", MI.new().k == 1)
    Q2.get.k = function() return 222 end
    check("改写 - 低优先级基类改成属性不击穿", MI.new().k == 1)
    Q1.get.k = function() return 111 end
    check("改写 - 高优先级基类改成属性生效", MI.new().k == 111)

    -- 成员默认值 -> set / opt 属性
    local D = class("Edge_D"); D.v = 1
    local E = class("Edge_E", D)
    local e = E.new()
    D.set.v = function(self, x) self._v = x end
    e.v = 7
    check("改写 - 成员默认值改成 set 属性", e._v == 7)

    local F = class("Edge_F"); F.w = 1
    local G = class("Edge_G", F)
    local g = G.new()
    F.opt.w = function(self, x) if x then self._w = x else return self._w end end
    g.w = 5
    check("改写 - 成员默认值改成 opt 属性", g.w == 5)

    -- 已存在实例：成员默认值 <-> 方法 互相改写
    local T = class("Edge_T"); T.z = 5
    local T2 = class("Edge_T2", T)
    local t = T2.new()
    check("改写 - 成员默认值初始读", t.z == 5)
    T.z = function() return 6 end
    check("改写 - 成员默认值改成方法后可见", t:z() == 6)

    local U = class("Edge_U"); U.w = function() return 1 end
    local U2 = class("Edge_U2", U)
    local u = U2.new()
    check("改写 - 方法初始调用", u:w() == 1)
    U.w = 42
    check("改写 - 方法改成成员默认值后可见", u.w == 42)
end

-- ============================================================
-- [19] 交叉路径回归
-- 覆盖：装饰器别名持有 / 通道级热更新 / __new·__delete 继承与热更新 /
--       析构重入 / 参数校验 —— 这些"多机制交互"路径曾是测试盲区
-- ============================================================
print("\n[19] 交叉路径回归")

do -- 装饰器别名持有：get/set 各自独立代理
    local C = class("Reg_Alias")
    local get = C.get
    local set = C.set
    get.x = function() return "GETTER" end
    set.x = function(self, pValue) self.raw = pValue end

    check("装饰器别名 - get.x 注册为 getter", C.new().x == "GETTER")
end

do -- 通道级热更新：子类自有 setter 不应阻断父类 getter 的失效
    local A = class("Reg_ChanA")
    A.get.v = function() return "A1" end
    local B = class("Reg_ChanB", A)
    B.set.v = function(self, pValue) end

    local obj = B.new()
    local before = obj.v
    A.get.v = function() return "A2" end
    check("通道级热更新 - 父类 getter 对子类实例生效",
        before == "A1" and obj.v == "A2")
end

do -- 多继承 __new 应是"先声明优先"
    local X = class("Reg_NX"); X.__new = function() return { from = "X" } end
    local Y = class("Reg_NY"); Y.__new = function() return { from = "Y" } end
    local Z = class("Reg_NZ", X, Y)

    check("多继承 - __new 先声明优先", Z.new().from == "X")
end

do -- __new 热更新下发给已创建子类
    local P = class("Reg_NP"); P.__new = function() return { tag = "v1" } end
    local Q = class("Reg_NQ", P)
    local before = Q.new().tag
    P.__new = function() return { tag = "v2" } end

    check("热更新 - 父类 __new 下发给已建子类",
        before == "v1" and Q.new().tag == "v2")
end

do -- __delete 热更新下发给已创建子类
    local order = {}
    local P = class("Reg_DP"); P.__delete = function() order[#order + 1] = "P1" end
    local Q = class("Reg_DQ", P)

    local o1 = Q.new(); o1:delete()
    P.__delete = function() order[#order + 1] = "P2" end
    local o2 = Q.new(); o2:delete()

    check("热更新 - 父类 __delete 下发给已建子类",
        table.concat(order, ",") == "P1,P2")
end

do -- 析构重入：缓存的 delete 引用重复调用
    local count = 0
    local D = class("Reg_Dup"); D.dtor = function() count = count + 1 end

    local obj = D.new()
    local del = obj.delete
    del(obj)
    del(obj)

    check("析构 - 重复 delete 只执行一次 dtor", count == 1)
end

do -- 析构重入：dtor 内部再次 delete
    local count = 0
    local D = class("Reg_Reenter")
    D.dtor = function(self) count = count + 1; self:delete() end

    D.new():delete()
    check("析构 - dtor 内部再次 delete 不重入", count == 1)
end

do -- 参数校验
    local okName, errName = pcall(class, nil)
    local okBase, errBase = pcall(class, "Reg_Bad", {})

    check("校验 - class(nil) 给出名称错误",
        (not okName) and tostring(errName):find("name", 1, true) ~= nil)
    check("校验 - 非类基类给出基类错误",
        (not okBase) and tostring(errBase):find("base", 1, true) ~= nil)
end

-- ============================================================
-- 结果汇总
-- ============================================================
print("\n============================================================")
print(string.format("  测试结果: %d 通过 / %d 失败 / %d 总计", passed, failed, passed + failed))
if failed > 0 then
    print("  ⚠ 存在失败的测试项！")
else
    print("  ✓ 全部通过！优化未破坏任何功能。")
end
print("============================================================")

os.exit(failed > 0 and 1 or 0)
