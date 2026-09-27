--[[
================================================================================
impls/native.lua —— 适配层：原生表 metatable（手写等价实现，下界参考）
================================================================================

角色：不是任何一个框架，而是"不存在框架时最朴素的写法"，用来给出各项测试的下界。
  它不引入任何框架能力，用 NClass / NChain / NDtor / NNew / NDelete 五个最小构件手写
  "功能等价"的实现；数值不代表某项设计优劣，只回答"这件事最少要花多少"。

接入字段的完整契约见同目录上一级的 impl_adapter.lua 头部；本文件只写本实现专有的部分。

order：10（列顺序＝order 升序，省略即 100）
================================================================================
]]

-- 建类时记录父类：原生表侧需要据此预置构造 / 析构链
local superOf = setmetatable({}, { __mode = "k" })

-- NClass 建类表：可选继承（类表挂 __index 指向父类），并预置实例元表
local function NClass(methods, base)
    local cls = methods or {}
    if base then setmetatable(cls, { __index = base }) end
    cls.__meta = { __index = cls }   -- 实例元表在类创建期一次建好，不进热路径
    return cls
end

-- NChain 预置构造链：父类链 + 本类 ctor（父类先调，与各实现口径一致）
local function NChain(cls, base)
    local ctors = {}
    if base then for i = 1, #base.__ctors do ctors[i] = base.__ctors[i] end end
    ctors[#ctors + 1] = cls.ctor
    cls.__ctors = ctors
    return cls
end

-- NDtor 预置析构链：本类 dtor + 父类链（子类先调，与各实现口径一致）
local function NDtor(cls, base)
    local dtors = { cls.__delete }
    if base then for i = 1, #base.__dtors do dtors[#dtors + 1] = base.__dtors[i] end end
    cls.__dtors = dtors
    return cls
end

-- NNew 建实例：setmetatable + 依次执行构造链
local function NNew(cls, ...)
    local obj = setmetatable({}, cls.__meta)
    local ctors = cls.__ctors
    for i = 1, #ctors do ctors[i](obj, ...) end
    return obj
end

-- NDelete 删实例：依次执行析构链
local function NDelete(obj, cls)
    local dtors = cls.__dtors
    for i = 1, #dtors do dtors[i](obj) end
end

return {
    order       = 10,
    name        = "原生表",
    lower_bound = true,

    create      = function(_, base)
        local cls = NClass(nil, base)
        superOf[cls] = base
        return cls
    end,
    -- 该实现没有"类表上的构造入口"，建实例＝本地函数
    new         = NNew,
    -- 实例上没有方法，删除＝本地函数
    delete      = NDelete,

    ctor        = function(cls, body) cls.ctor = body; NChain(cls, superOf[cls]) end,
    dtor        = function(cls, body) cls.__delete = body; NDtor(cls, superOf[cls]) end,
    -- 类表赋值即默认值；实例读穿透到类表
    set_default = true,
    -- COW 两项：实例不跑 ctor，读取时落到类表上的默认值
    new_bare    = function(cls) return setmetatable({}, cls.__meta) end,

    -- 建类两项：原生表要同步预置构造链，共享层的通用计时体表达不了
    ops = {
        class_creation = function()
            return function()
                NClass({
                    ctor  = function(self, name) self.name = name end,
                    speak = function(self) return self.name end,
                })
            end
        end,
        inherit_class_creation = function()
            return function()
                local base = NClass({
                    ctor  = function(self) self.x = 0 end,
                    get_x = function(self) return self.x end,
                })
                NClass({ ctor = function(self) self.y = 0 end }, base)
            end
        end,
    },
}