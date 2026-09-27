--[[
================================================================================
impl_adapter.lua —— 适配层机制（oop_benchmark.lua 的配套模块）
================================================================================

职责：把"某个 OOP 实现的调用形状"收敛成基准测试定义可以直接使用的统一接口，让
  benchmarks/suite/oop_benchmark.lua 里只剩「测试定义 + 入口」，测试定义里不再出现任何
  实现专有的构造入口名、删除入口名或形状分支。

对外只暴露两类东西：
  1) 校验与归一化：M.validate / M.norm / M.caps_of / M.req_ok
     测试文件在 run() 内对每个实现表调用它们。
  2) 适配层发现：M.discover()
     扫描 benchmarks/suite/impls/*.lua，require 每个文件，按 order 升序返回实现表数组。
     **新增一个 OOP 实现＝往 impls/ 放一个适配层文件；删掉一个实现＝删掉那个文件。**
     测试文件、入口、本模块都不用改。

--------------------------------------------------------------------------------
impls/ 下一个适配层文件长什么样
--------------------------------------------------------------------------------
  纯「接入代码」，直接 return 一张实现表：

    require("Xxx.OOP")         -- 该实现自己的加载方式
    local xClass = class       -- require 之后**紧邻**捕获它占用的全局，收敛为局部别名
    return {
        order  = 30,           -- 列顺序（省略 = 100；同值按文件名升序）
        name   = "Xxx",        -- 输出表头列名（必给）
        create = xClass,       -- 建类入口（必给）
        new    = "New",        -- 建实例形状（省略 = "new"）
        delete = "Delete",     -- 删除形状（省略 = "delete"；false = 无同步删除）
    }

  "require 之后紧邻捕获全局"这一条很重要：多个实现可能占用同一个全局名（如 class），
  只要每个文件都在 require 后立刻收敛为局部别名，加载顺序就不影响结果。

--------------------------------------------------------------------------------
接入字段契约（写一个新对照实现：name / create 必给，其余按需覆盖）
--------------------------------------------------------------------------------
  必给
    name                     输出表头列名
    create(name, base) -> cls  建类入口，直接传该实现的 class 函数即可；
                             base 为 nil 表示无继承

  建/删实例形状（决定计时体内怎么建、怎么删；准备期展开，计时体内零分支）
    new                      省略 = "new"；取值见下方「字段说明 • new」
    delete                   省略 = "delete"；取值见下方「字段说明 • delete」

  能力开关（省略 = 该能力不可用 ⇒ 依赖它的测试单元格显示 n/a）
    ctor                     省略 = "ctor"       构造函数写入方式
    dtor                     省略 = "dtor"；false = 该实现无析构 ⇒ 析构 3 项 n/a
    set_method               省略 = cls[k] = fn  往类表装方法
    set_default              省略 = 无「类表默认值 + 读穿透」⇒ COW 2 项 n/a
    redefine                 省略 = cls[k] = fn；false = 无此能力 ⇒ 热更新项 n/a

  其它
    order                    列顺序（省略 = 100；同值按文件名升序）——只被 discover() 读
    new_bare(cls) -> obj     不跑 ctor 建实例（只有下界参考需要；COW 2 项用它避开 ctor）
    ops[key] -> 计时闭包      逐测试覆盖钩子（只有建类两项需要）
    reference                true = 该列是本框架侧，汇总时作为「领先/落后」基准
    lower_bound              true = 原生表下界参考，汇总时单独一行

--------------------------------------------------------------------------------
形状工厂（norm() 的返回值上挂好，测试定义只用这五个，不再感知实现形状）
--------------------------------------------------------------------------------
  A.obj(C, ...)                          立即建实例（准备期用，无热路径约束）
  A.t_new(C)                             计时闭包：只建实例
  A.t_new_delete(C)                      计时闭包：建实例 → 删除
  A.t_new_use_delete(C, 方法名, 参数)     计时闭包：建实例 → 调一次方法 → 删除
  A.t_new_call2(C, c1, c2, m1, a1, a2, m2)
                                         计时闭包：建实例(c1, c2) → 调 m1(a1, a2) → 调 m2()

  每个工厂都在**准备期**完成形状分支，返回的闭包体内没有分支。闭包体内多包一层函数
  就会给该列所有数值加一帧开销，因此这里刻意只展开形状、不做任何包装调用。
  注意 `o[方法名](o, 参数)` 与 `o:方法名(参数)` 等价（前者多一条常量索引指令）。

--------------------------------------------------------------------------------
增删一个实现要改哪几行
--------------------------------------------------------------------------------
  新增：往 impls/ 放一个文件（照抄上面骨架，多数情况 6~15 行，其余字段走默认值）。
  删除：把 impls/ 下那个文件删掉（连带依赖它的第三方目录）。
  两件事都不需要动测试文件、入口、本模块。
  临时只跑其中几个：把不需要的适配层文件移出 impls/，或把入口改成显式传表
  （Test(A1, A2)，见 oop_benchmark.lua 末尾注释）。
================================================================================
]]

--[[
--------------------------------------------------------------------------------
字段说明（每个需要适配转换的字段都写清：含义 / 必需性 / 适配层怎么用它 / 写法与反例）
--------------------------------------------------------------------------------

--- name —— 输出表头列名（必给）
--- 含义/必需性：字符串；出现在表头、"vs XXX" 倍率列与汇总分析里。
--- 适配层用法：norm() 原样搬到 label，report() 只读 label。
--- 写法：name = "OtherOOP"

--- create —— 建类入口（必给）
--- 含义/必需性：function(name, base) -> cls；base 为 nil 表示无继承。
--- 适配层用法：42 项测试全部通过 A.create(name, base) 建类，测试定义不关心内部实现。
--- 写法：
---   create = OtherClass                    → 直接传该实现的 class 函数（签名已是 (name, base)）
---   create = function(name, base) ... end  → 需要额外登记（如本框架要记 base 以串父类 ctor）
--- 反例：create = function(n) return myClass(n) end 丢掉 base——继承类测试会全错。

--- new —— 建实例入口形状（可省；省略 = "new"）
--- 含义/必需性：决定测试在计时体内如何建实例；非 "new" 口径的实现必给。
--- 适配层用法：norm() 收敛成形状枚举 call | fn | name，准备期展开成无分支闭包
---   （A.obj / A.t_new / A.t_new_delete / A.t_new_use_delete / A.t_new_call2），
---   42 项测试不再感知本字段。
--- 三种写法：
---   new = "New"                     → C.New()          （OtherOOP/OtherClass：类表上有 New）
---   new = function(C, ...) ... end  → 本地建实例函数    （原生表 NNew：类表上没有构造入口）
---   new = true                      → C()              （类表带 __call 的实现才可用）
--- 反例：new = function(C) return C.new(C) end 再在计时体内调用——多一帧会污染该列全部数值。

--- delete —— 删除形状（可省；省略 = "delete"）
--- 含义/必需性：决定测试在计时体内如何同步删除实例；无同步删除的实现给 false。
--- 适配层用法：norm() 收敛成形状枚举 fn | name（false ⇒ nil），caps_of() 据此推导 dtor 能力：
---   删除能力缺失 ⇒ 「完整生命周期 / 实例删除 / 析构函数链」3 项 n/a。
--- 三种写法：
---   delete = "Delete"                 → o.Delete(o)      （OtherOOP/OtherClass）
---   delete = function(obj, cls) ... end → DFN(obj, cls)   （原生表 NDelete：实例上没有方法）
---   delete = false                    → 无同步删除       （析构只在 GC 时由 __gc 触发的实现）
--- 反例：给 delete = false 的实现同时写 dtor——二者矛盾，validate() 会直接报错。

--- ctor —— 构造函数写入方式（可省；省略 = "ctor"）
--- 含义/必需性：构造体如何落到类上；字段名或 (cls, body) 写入函数。
--- 适配层用法：norm() 包成 A.write_ctor(cls, body)，42 项测试只调它。
--- 写法：
---   ctor = "__init"                   → cls.__init = body（OtherOOP/OtherClass 的字段名）
---   ctor = function(cls, body) ... end → 自定义；本框架用它把父类 ctor 串进 body（父类先跑）
--- 注意：本框架不自动串父类，带基类时由这条写入函数生成"先跑基类 ctor、再跑本类 body"的包装。

--- dtor —— 析构函数写入方式（可省；省略 = "dtor"；false = 无析构）
--- 含义/必需性：同 ctor；显式 false 表示该实现没有析构。
--- 适配层用法：norm() 包成 A.write_dtor(cls, body)；false ⇒ write_dtor 为 nil ⇒ 析构 3 项 n/a。
--- 写法：dtor = "__delete"（OtherOOP/OtherClass）/ dtor = false（无析构的实现）。

--- set_method —— 往类表装方法（可省；省略 = cls[k] = fn）
--- 含义/必需性：绝大多数实现直接赋值即可；只有"方法必须经专用入口注册"的实现才需要覆盖。
--- 适配层用法：42 项里所有 A.set_method(cls, k, fn) 都走这里（收敛前这一项在 norm() 里被硬编码，
---   任何实现都无法覆盖——现改为可覆盖字段）。
--- 写法：set_method = function(cls, k, fn) cls[k] = fn end

--- set_default —— 类表默认值写入（可省；省略 = 无此能力）
--- 含义/必需性：function(cls, k, v)，或 true 哨兵（等价于 cls[k] = v）。
--- 适配层用法：COW 2 项用 A.set_default(C, "hp", 100) 落默认值，再配合读穿透口径实测
---   「实例上无该字段 → 读时穿透到类表 / vTable」。
--- ⚠ 省略表示"无此能力"，COW 2 项显示 n/a。**不得改成默认值**：把 nil 静默变成
---   `cls[k] = v` 会让不具备读穿透能力的实现也参与测试，n/a 会变成一列错数据。
--- 写法：set_default = true（impls/ 下三个适配层都是这一口径）

--- redefine —— 改写类上已有成员（可省；省略 = cls[k] = fn；false = 无此能力）
--- 含义/必需性：热更新场景"同键再赋一次"；显式 false ⇒ 「热更新后方法调用」项 n/a。
--- 适配层用法：热更新项先 A.set_method 装旧方法，再 A.redefine 覆盖，然后测调用。
--- 写法：
---   redefine = function(cls, name, fn) ... end  → 重复定义会告警 / 报错的实现需在此屏蔽
---   redefine = false                            → 该实现不支持改写 ⇒ 该项 n/a

--- new_bare —— 不跑 ctor 建实例（可省；通常只有下界参考需要）
--- 含义/必需性：function(cls) -> obj。COW 2 项必须避开 ctor，否则 ctor 里落下的实例字段
---   会把"读穿透"路径掩盖成"实例自有字段直读"，四列口径就不一致了。
--- 适配层用法：COW 2 项写 `A.new_bare and A.new_bare(C) or A.obj(C)`。
--- 写法：new_bare = function(cls) return setmetatable({}, cls.__meta) end（原生表）

--- ops —— 逐测试覆盖钩子（可省）
--- 含义/必需性：表，ops[测试 key] = function(ctx) -> 计时闭包。
---   只有"建类"两项（class_creation / inherit_class_creation）需要——这两项的实现专有逻辑
---   无法用统一工厂表达（原生表要同步预置构造链、按源名缓存类模板的实现要把建类移出计时体）。
--- 适配层用法：run() 里 `local op = A.ops and A.ops[e.key]; fns[i] = op and op(ctx) or e.make(A)`。
---   ctx.uid(prefix) 生成进程内唯一的类名（实现侧类名不允许重复）。
--- 写法：ops = { class_creation = function(ctx) return function() ... end end }
---   不需要 ctx 的实现（如原生表）写成 function() ... end 即可，Lua 会忽略多余实参。

--- reference / lower_bound —— 汇总统计的角色标记（可省）
--- 含义/必需性：reference = true 标记本框架侧（作为「领先/落后」的基准列，缺省则取最后一列）；
---   lower_bound = true 标记原生表下界参考（只报不适用项数，并单独给出"相对下界"一行）。
--- 适配层用法：report() 直接读归一化表的 label / reference / lower_bound，字段名不要改。
--------------------------------------------------------------------------------
]]

-- ============================================================
-- 路径引导
-- 本模块位于 benchmarks/suite/，仓库根目录即其上方两级。
-- 自带一份（与 oop_benchmark.lua 同形），使模块可被独立 require，无须调用方先铺
-- package.path；重复追加无害。
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

local M = {}

-- ============================================================
-- 校验与归一化
-- ============================================================

local function validate(A)
    assert(type(A) == "table", "Test 的实参必须是实现表")
    assert(type(A.name) == "string", "实现表缺少 name")
    assert(type(A.create) == "function", A.name .. ": 缺少 create(name, base)")
    assert(type(A.ctor) == "string" or type(A.ctor) == "function" or A.ctor == nil,
        A.name .. ": ctor 必须是字段名或 (cls, body) 写入函数")
    assert(type(A.dtor) == "string" or type(A.dtor) == "function"
        or A.dtor == false or A.dtor == nil,
        A.name .. ": dtor 必须是字段名、(cls, body) 写入函数，或 false")
    assert(A.set_method == nil or type(A.set_method) == "function",
        A.name .. ": set_method 必须是 (cls, k, fn) 写入函数")
    assert(A.set_default == nil or A.set_default == true or type(A.set_default) == "function",
        A.name .. ": set_default 必须是 (cls, k, v) 写入函数，或 true（等价 cls[k] = v）")
    assert(A.redefine == nil or A.redefine == false or type(A.redefine) == "function",
        A.name .. ": redefine 必须是 (cls, k, fn) 写入函数，或 false")
    assert(A.new == nil or A.new == true or type(A.new) == "string" or type(A.new) == "function",
        A.name .. ': new 必须是方法名字符串、(C, ...) 建实例函数，或 true（等价 C()）')
    assert(A.delete == nil or A.delete == false
        or type(A.delete) == "string" or type(A.delete) == "function",
        A.name .. ": delete 必须是方法名字符串、(obj, cls) 删除函数，或 false")
    if A.delete ~= nil and A.delete ~= false then
        assert(A.dtor ~= false, A.name .. ": 声明了删除却没有析构，二者必须同时给出")
    end
end

-- 归一化：收敛成测试定义统一使用的形状。
-- 不具备的能力置 nil（依赖它的测试即 n/a），并在返回值上挂好五个形状工厂。
local function norm(A)
    -- ---- 1) 建实例形状：call（C(...)）/ fn（本地函数 (C, ...)）/ name（C[方法名](...)） ----
    local nk, NF, NEW
    local nv = A.new
    if nv == true then
        nk = "call"
    elseif type(nv) == "function" then
        nk, NF = "fn", nv
    elseif type(nv) == "string" then
        nk, NEW = "name", nv
    else
        nk, NEW = "name", "new"             -- 本框架口径：类表上的构造入口叫 new
    end

    -- ---- 2) 删除形状：fn（本地函数 DFN(obj, cls)）/ name（实例方法 o[DEL](o)） ----
    local dk, DEL, DFN
    local dv = A.delete
    if dv == false then
        dk = nil                            -- 显式声明"无同步删除" ⇒ 析构 3 项 n/a
    elseif type(dv) == "function" then
        dk, DFN = "fn", dv
    elseif type(dv) == "string" then
        dk, DEL = "name", dv
    else
        dk, DEL = "name", "delete"
    end

    -- ---- 3) 构造 / 析构写入：字段名 或 (cls, body) 函数；false 表示无该能力 ----
    local function write(field)
        if field == false then return nil end
        if type(field) == "function" then return field end
        return function(cls, body) cls[field] = body end
    end

    -- ---- 4) 改写已有成员：默认同键再赋一次；false 表示不支持 ----
    local redefine = A.redefine
    if redefine == false then
        redefine = nil
    elseif not redefine then
        redefine = function(cls, k, fn) cls[k] = fn end
    end

    -- ---- 5) 类表默认值：true 哨兵等价于 cls[k] = v；省略/ false 表示无此能力 ----
    local set_default = A.set_default
    if set_default == true then
        set_default = function(cls, k, v) cls[k] = v end
    elseif set_default == false then
        set_default = nil
    end

    -- ---- 6) 形状工厂：分支在这里（准备期）一次性完成，返回的闭包体内无分支、无额外函数帧 ----
    local function mk_new(C)
        if nk == "call" then return function() local o = C() end end
        if nk == "fn" then return function() local o = NF(C) end end
        return function() local o = C[NEW]() end
    end

    local function mk_new_del(C)
        if dk == "fn" then
            if nk == "call" then return function() local o = C(); DFN(o, C) end end
            if nk == "fn" then return function() local o = NF(C); DFN(o, C) end end
            return function() local o = C[NEW](); DFN(o, C) end
        end
        if nk == "call" then return function() local o = C(); o[DEL](o) end end
        if nk == "fn" then return function() local o = NF(C); o[DEL](o) end end
        return function() local o = C[NEW](); o[DEL](o) end
    end

    local function mk_new_use_del(C, m, a)
        if dk == "fn" then
            if nk == "call" then return function() local o = C(); o[m](o, a); DFN(o, C) end end
            if nk == "fn" then return function() local o = NF(C); o[m](o, a); DFN(o, C) end end
            return function() local o = C[NEW](); o[m](o, a); DFN(o, C) end
        end
        if nk == "call" then return function() local o = C(); o[m](o, a); o[DEL](o) end end
        if nk == "fn" then return function() local o = NF(C); o[m](o, a); o[DEL](o) end end
        return function() local o = C[NEW](); o[m](o, a); o[DEL](o) end
    end

    local function mk_new_call2(C, c1, c2, m1, a1, a2, m2)
        if nk == "call" then
            return function() local o = C(c1, c2); o[m1](o, a1, a2); local d = o[m2](o) end
        end
        if nk == "fn" then
            return function() local o = NF(C, c1, c2); o[m1](o, a1, a2); local d = o[m2](o) end
        end
        return function() local o = C[NEW](c1, c2); o[m1](o, a1, a2); local d = o[m2](o) end
    end

    -- 立即建实例（准备期用，无热路径约束）
    local function instantiate(C, ...)
        if nk == "call" then return C(...) end
        if nk == "fn" then return NF(C, ...) end
        return C[NEW](...)
    end

    local normed = {
        -- report() 直接读取的字段（名字不要改）
        label       = A.name,
        reference   = A.reference,
        lower_bound = A.lower_bound,
        ops         = A.ops,
        -- 测试定义使用的字段
        create      = A.create,
        write_ctor  = write(A.ctor == nil and "ctor" or A.ctor),
        write_dtor  = write(A.dtor == nil and "dtor" or A.dtor),
        set_method  = A.set_method or function(cls, k, fn) cls[k] = fn end,
        set_default = set_default,
        redefine    = redefine,
        new_bare    = A.new_bare,
        -- 形状工厂
        obj              = instantiate,
        t_new            = function(C) return mk_new(C) end,
        t_new_delete     = function(C) return mk_new_del(C) end,
        t_new_use_delete = function(C, m, a) return mk_new_use_del(C, m, a) end,
        t_new_call2      = function(C, c1, c2, m1, a1, a2, m2)
            return mk_new_call2(C, c1, c2, m1, a1, a2, m2)
        end,
        -- 内部：能力推导用（不对外）
        has_delete  = dk ~= nil,
    }
    return normed
end

-- 能力推导：可选能力缺失 ⇒ 依赖它的测试不参与（n/a）
local function caps_of(A)
    return {
        ctor      = true,
        method    = true,
        dtor      = A.write_dtor ~= nil and A.has_delete,
        default   = A.set_default ~= nil,
        redefine  = A.redefine ~= nil,
    }
end

local function req_ok(caps, requires)
    for _, r in ipairs(requires) do
        if not caps[r] then return false end
    end
    return true
end

M.validate = validate
M.norm     = norm
M.caps_of  = caps_of
M.req_ok   = req_ok

-- ============================================================
-- 适配层发现：扫描 impls/ 目录
--
-- 每个 OOP 实现的接入代码是 impls/ 下的一个独立文件（顶层 return 一张实现表）。
-- 列顺序由表里的 order 决定（省略 = 100，同值按文件名升序），与文件名无关。
-- 因此「新增一个实现＝加一个文件」「删掉一个实现＝删掉那个文件」，测试与入口都不动。
-- ============================================================

-- 列出目录下的 .lua 文件名（不含路径）；io.popen 不可用时返回空表，由 discover() 报错
local function list_impl_files()
    local dir = _dir .. "impls"
    local cmd
    if _sep == "\\" then
        cmd = 'dir /b /a-d "' .. dir .. '\\*.lua" 2>nul'
    else
        cmd = 'ls -1 "' .. dir .. '" 2>/dev/null'
    end
    local p = io.popen(cmd)
    if not p then return {} end
    local out = p:read("a")
    p:close()

    local names = {}
    for line in out:gmatch("[^\r\n]+") do
        local n = line:match("^%s*(.-)%s*$")
        if n:match("%.lua$") then names[#names + 1] = n end
    end
    table.sort(names)                       -- 同 order 时按文件名升序，保证可复现
    return names
end

local function discover()
    local found = {}
    for _, file in ipairs(list_impl_files()) do
        local mod = file:match("^(.*)%.lua$")
        local A = require("benchmarks.suite.impls." .. mod)
        assert(type(A) == "table", "impls/" .. file .. " 必须 return 一张实现表")
        found[#found + 1] = { A = A, order = A.order or 100, mod = mod }
    end
    assert(#found > 0, "impls/ 目录下没有适配层文件：至少要放一个实现才能跑基准")

    table.sort(found, function(x, y)
        if x.order ~= y.order then return x.order < y.order end
        return x.mod < y.mod
    end)

    local list = {}
    for i, f in ipairs(found) do list[i] = f.A end
    return list
end

M.discover = discover

return M

