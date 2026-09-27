--[[
================================================================================
impls/luaoop.lua —— 适配层：本框架 LuaOOP/
================================================================================

本实现专有的两处口径：
  1) 类成员默认值 cls.hp = 100 为 copy-on-write（读路径不复制到实例）。
     注意：落默认值不得用属性装饰器——那会把字段读切成函数 __index，破坏字段访问口径。
  2) 构造函数不自动串父类（其它实现都是父类先跑），故 ctor 写入时生成"先跑基类 ctor、
     再跑本类 body"的包装，写法与仓库既有脚本一致。
  3) 建类是全局函数 class，与 OtherOOP.OtherClass 不同名；require 后立刻收敛为局部别名，
     避免依赖加载顺序。

接入字段的完整契约见同目录上一级的 impl_adapter.lua 头部。

order：90（列顺序＝order 升序，省略即 100）；reference = true 表示汇总时以本列为参照。
================================================================================
]]

require("LuaOOP.Class")
local myClass = class   -- 立刻收敛为局部别名

-- 记下每个类的基类，供 ctor 包装显式串父类
local baseOf = setmetatable({}, { __mode = "k" })

local function luaoop_create(name, base)
    local cls = myClass(name, base)
    baseOf[cls] = base
    return cls
end

return {
    order       = 90,
    name        = "LuaOOP",
    reference   = true,
    create      = luaoop_create,
    set_default = true,
    ctor        = function(cls, body)
        local base = baseOf[cls]
        if base then
            cls.ctor = function(self) base.ctor(self); body(self) end
        else
            cls.ctor = body
        end
    end,

    -- 建类两项按仓库既有脚本的直接赋值写（不走上面的 ctor 包装）
    ops = {
        class_creation = function(ctx)
            return function()
                local c = myClass(ctx.uid("m_cc"))
                c.ctor = function(self, name) self.name = name end
                c.speak = function(self) return self.name end
            end
        end,
        inherit_class_creation = function(ctx)
            return function()
                local base = myClass(ctx.uid("m_pc"))
                base.ctor = function(self) self.x = 0 end
                base.get_x = function(self) return self.x end
                local child = myClass(ctx.uid("m_ci"), base)
                child.ctor = function(self) base.ctor(self); self.y = 0 end
            end
        end,
    },
}