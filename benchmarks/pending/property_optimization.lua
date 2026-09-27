--[[
-- 属性优化效果精确对比测试
-- 分离框架开销与 getter 业务逻辑开销：逐层拆解一次属性读取，定位哪些开销
-- 是框架可优化的、哪些是 Lua 元方法模型本身不可消除的。
--
-- 【待优化】
-- 本脚本作为属性优化的常驻工作台：拆解一次属性读取/写入的开销构成，
-- 区分"框架可优化的部分"与"Lua 元方法模型本身不可消除的部分"。
--
-- 校准口径（[4] 已按现行实现重写）：
--   [4] 三种属性表表示共用同一个前置的 vTable 未命中，差别只在属性表怎么存：
--       (a) 历史假设：ClassesReadable[pCls][pKey] 两级哈希（pvTable 方案当时假设的对手）
--       (b) 现行实现：readable 是闭包 upvalue，readable[pKey] 单级 + property[1] 包装表 + 方向判断
--       (c) 扁平化：pvTable[pKey] 单级 + 直接调用 getter（无包装表、无方向判断）
--   → (a)-(b) 是"把 readable 提成 upvalue"已经吃掉的收益；
--     (b)-(c) 才是扁平化相对现行实现真正的净收益。
--   [4] 不含 __index 分派帧；与 [3] 的真实属性读相减，余量即分派帧 + getter 帧。
-- 当前属性数据见: benchmarks/suite/oop_features_profile.lua
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

local function now()
    return os.clock()
end

local N = 2000000
local sink = 0

print("============================================================")
print("  属性优化效果精确对比测试")
print("  Lua " .. _VERSION .. " | " .. N .. " iterations")
print("============================================================")

-- ============================================================
-- 1. 基准线：纯字段访问（无 __index 开销）
-- ============================================================
print("\n[1] 基准线")

do
    local raw = { x = 3, y = 4, _val = 42 }
    local t0 = now()
    for i = 1, N do sink = raw._val end
    local elapsed = (now() - t0) / N * 1e6
    print(string.format("  纯表字段读取:           %.3f us/op", elapsed))
end

-- ============================================================
-- 2. 方法调用：表 __index（无属性类） vs 函数 __index（有属性类）
--    差值 = "声明属性"的隐性成本：整类切到函数 __index 后，所有方法访问都多一跳
-- ============================================================
print("\n[2] LuaOOP 方法调用基准")

do
    local Obj = class("MethodBench")
    Obj.ctor = function(self) self._val = 42 end
    Obj.get_val = function(self) return self._val end

    local obj = Obj.new()
    local t0 = now()
    for i = 1, N do sink = obj:get_val() end
    local method_time = (now() - t0) / N * 1e6
    print(string.format("  方法调用 (表 __index):    %.3f us/op", method_time))

    -- 同一个方法调用，但类声明了属性 → 整类已被 SwitchToFuncIndex 切到函数 __index
    local WithProp = class("MethodPropBench")
    WithProp.ctor = function(self) self._val = 42 end
    WithProp.get_val = function(self) return self._val end
    WithProp.opt.mark = function(self, v)
        if v then self._mark = v else return self._mark end
    end

    local obj2 = WithProp.new()
    t0 = now()
    for i = 1, N do sink = obj2:get_val() end
    local method_prop = (now() - t0) / N * 1e6
    print(string.format("  方法调用 (函数 __index):  %.3f us/op", method_prop))
    print(string.format("      切函数 __index 台阶:  %.3f us/op", method_prop - method_time))
end

-- ============================================================
-- 3. 现行实现实测：真实属性访问（含 __index 分派帧与 getter 帧）
--    与 [4] 相减即为分派帧成本
-- ============================================================
print("\n[3] 现行实现实测（真实属性访问）")

do
    local Obj = class("OptBench")
    Obj.ctor = function(self) self._val = 42 end
    Obj.opt.val = function(self, v)
        if v then self._val = v else return self._val end
    end

    local obj = Obj.new()

    -- opt 读取
    local t0 = now()
    for i = 1, N do sink = obj.val end
    local opt_read = (now() - t0) / N * 1e6

    -- opt 写入
    t0 = now()
    for i = 1, N do obj.val = 99 end
    local opt_write = (now() - t0) / N * 1e6

    print(string.format("  opt 属性读取:            %.3f us/op", opt_read))
    print(string.format("  opt 属性写入:            %.3f us/op", opt_write))
end

-- ============================================================
-- 4. get 属性读取（简单 getter，不含 math.sqrt）
-- ============================================================

do
    local Obj = class("GetBench")
    Obj.ctor = function(self) self._val = 42 end
    Obj.get.val = function(self) return self._val end

    local obj = Obj.new()

    local t0 = now()
    for i = 1, N do sink = obj.val end
    local get_read = (now() - t0) / N * 1e6
    print(string.format("  get 属性读取:            %.3f us/op", get_read))
end

-- ============================================================
-- 5. set 属性写入（简单 setter）
-- ============================================================

do
    local Obj = class("SetBench")
    Obj.ctor = function(self) self._val = 42 end
    Obj.set.val = function(self, v) self._val = v end

    local obj = Obj.new()

    local t0 = now()
    for i = 1, N do obj.val = 99 end
    local set_write = (now() - t0) / N * 1e6
    print(string.format("  set 属性写入:            %.3f us/op", set_write))
end

-- ============================================================
-- 4. 分派内部：三种属性表表示（均含前置的 vTable 未命中）
--    (a) 历史假设  ClassesReadable[pCls][pKey] 两级哈希（pvTable 方案当时假设的对手）
--    (b) 现行实现  readable[pKey]（闭包 upvalue）+ property[1] 包装表 + 方向判断
--    (c) 扁平化    pvTable[pKey] 单级 + 直接调用（无包装表、无方向判断）
--    三者只差属性表怎么存 → (b)-(c) 即扁平化的真实净收益
-- ============================================================
print("\n[4] 分派内部：三种属性表表示（含 vTable 未命中）")

do
    local data = { _val = 42 }
    local key = "val"
    local getter = function(self) return self._val end
    local setter = function(self, v) self._val = v end

    -- 前置的 vTable 未命中：三种方案都必须付，扁平化省不掉
    -- （现行实现里 vTable / readable 都是 funcIndex 的 upvalue，此处用 local 等价替代）
    local vTable = { other = true }

    -- (a) 历史假设：穿全局表 + 类表的两级查找
    local ClassesReadable = setmetatable({}, { __mode = "k" })
    local Cls = {}
    ClassesReadable[Cls] = { [key] = { getter } }

    local t0 = now()
    for i = 1, N do
        local value = vTable[key]                       -- 三种方案共用
        if nil ~= value then
            sink = value
        else
            local property = ClassesReadable[Cls][key]  -- 两级哈希查找
            if property and not property[2] then
                sink = property[1](data)                -- 子表访问 + 方向判断 + 调用
            end
        end
    end
    local hist_read = (now() - t0) / N * 1e6

    -- (b) 现行实现：readable 是闭包 upvalue，单级哈希 + 包装表 + 方向判断
    local readable = { [key] = { getter } }

    t0 = now()
    for i = 1, N do
        local value = vTable[key]
        if nil ~= value then
            sink = value
        else
            local property = readable[key]              -- 单级哈希（upvalue 直取）
            if property and not property[2] then
                sink = property[1](data)                -- 子表访问 + 方向判断 + 调用
            end
        end
    end
    local cur_read = (now() - t0) / N * 1e6

    -- (c) 扁平化：getter 直接存表，单级哈希 + 直接调用
    local pvTable = { [key] = getter }

    t0 = now()
    for i = 1, N do
        local value = vTable[key]
        if nil ~= value then
            sink = value
        else
            local fn = pvTable[key]                     -- 单级哈希
            if fn then
                sink = fn(data)                         -- 直接调用，无包装表/无判断
            end
        end
    end
    local flat_read = (now() - t0) / N * 1e6

    print(string.format("  (a) 历史假设 两级哈希:      %.3f us/op", hist_read))
    print(string.format("  (b) 现行实现 upvalue+包装:  %.3f us/op", cur_read))
    print(string.format("  (c) 扁平化 单级+直接调用:   %.3f us/op", flat_read))
    print(string.format("      (a)-(b) upvalue 已吃掉:  %.3f us/op", hist_read - cur_read))
    print(string.format("      (b)-(c) 扁平化净收益:    %.3f us/op (%.1f%%)",
        cur_read - flat_read, (cur_read - flat_read) / cur_read * 100))

    -- 写入侧：funcNewIndex 没有前置的 vTable 未命中，直接查属性表
    local ClassesWritable = setmetatable({}, { __mode = "k" })
    ClassesWritable[Cls] = { [key] = { setter } }

    t0 = now()
    for i = 1, N do
        local property = ClassesWritable[Cls][key]
        if property and not property[2] then
            property[1](data, 99)
        end
    end
    local hist_write = (now() - t0) / N * 1e6

    local writable = { [key] = { setter } }

    t0 = now()
    for i = 1, N do
        local property = writable[key]
        if property and not property[2] then
            property[1](data, 99)
        end
    end
    local cur_write = (now() - t0) / N * 1e6

    local wvTable = { [key] = setter }

    t0 = now()
    for i = 1, N do
        local fn = wvTable[key]
        if fn then
            fn(data, 99)
        end
    end
    local flat_write = (now() - t0) / N * 1e6

    print(string.format("  (a) 历史假设 两级哈希:      %.3f us/op", hist_write))
    print(string.format("  (b) 现行实现 upvalue+包装:  %.3f us/op", cur_write))
    print(string.format("  (c) 扁平化 单级+直接调用:   %.3f us/op", flat_write))
    print(string.format("      (b)-(c) 扁平化净收益:    %.3f us/op (%.1f%%)",
        cur_write - flat_write, (cur_write - flat_write) / cur_write * 100))
end

-- ============================================================
-- 5. 继承属性（子类实例访问父类定义的属性）
-- ============================================================
print("\n[5] 继承属性性能")

do
    local Base = class("InhPropBase")
    Base.ctor = function(self) self._val = 42 end
    Base.opt.val = function(self, v)
        if v then self._val = v else return self._val end
    end
    Base.get.readonly = function(self) return self._val end

    local Child = class("InhPropChild", Base)
    Child.ctor = function(self) Base.ctor(self) end

    local obj = Child.new()

    -- 继承的 opt 属性（首次慢路径后缓存到子类 pvTable）
    local t0 = now()
    for i = 1, N do sink = obj.val end
    local inh_opt = (now() - t0) / N * 1e6

    -- 继承的 get 属性
    t0 = now()
    for i = 1, N do sink = obj.readonly end
    local inh_get = (now() - t0) / N * 1e6

    print(string.format("  继承 opt 属性读取:       %.3f us/op", inh_opt))
    print(string.format("  继承 get 属性读取:       %.3f us/op", inh_get))
end

-- ============================================================
-- 结果汇总
-- ============================================================
print("\n============================================================")
print("  优化效果分析")
print("============================================================")
print([[
  读法（已按现行实现校准）：

  [3] 真实属性读 = __index 分派帧 + getter 帧 + 查找/判断
  [4] 分派内部   = 查找/判断（不含 __index 分派帧）

  → [3] 属性读 − [4](b) ≈ __index 分派帧
  → [4](b) − [4](c)     = 扁平化相对现行实现的真实净收益
  → [4](a) − [4](b)     = 把 readable 提成闭包 upvalue 已经吃掉的收益；
                          文档里"改善 25~35%"的预测正是量在这个已过期的区间上

  为什么净收益只能是常数级：
  - 扁平化只去掉 property[1] 包装表索引 + property[2] 方向判断；
  - 查找次数降不下来：vTable 未命中 + 属性表命中都必须付 ——
    getter 若直接存进 vTable，v.x 返回的就是函数本身而非调用结果，语义会变；
    若用包装表区分"方法 / getter"，则每次方法访问都要多一次索引。
  - 还要额外维护 pvTable/wvTable 的继承解析与递归失效，
    而现行实现用 ReadableInheritMeta 元表在查找时免费完成同一件事。

  [2] 的"切函数 __index 台阶"是更大的常数成本：类一旦声明属性，
  该类所有实例的方法访问从"表 __index 一跳"变成"函数 __index + 一次 Lua 调用"。
]])

-- 防止 sink 被优化掉
if sink == 0 then end
