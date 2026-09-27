--[[
================================================================================
impls/otherclass.lua —— 适配层：OtherOOP/OtherClass.lua（2017 年的单继承 vTable 实现）
================================================================================

本实现专有的三处口径：
  1) 类表在创建时预置 __init / __delete 两个原始字段（初值 false），因此这两个键的赋值
     不过 __newindex 而直接落在类表上；普通方法赋值才走 __newindex 落进 vTable。
  2) 实例侧：New() 内部沿 super 链递归调用 __init（父类先），Delete() 沿 super 链递归调用
     __delete（子类先）；链式调用由实现自身完成，接入代码无需包装。
  3) 建类是全局函数 OtherClass，与本框架占用的 class 不是同一个名，无冲突；
     require 后立刻收敛为局部别名，避免依赖加载顺序。

接入字段的完整契约见同目录上一级的 impl_adapter.lua 头部。

order：20（列顺序＝order 升序，省略即 100）
================================================================================
]]

require("OtherOOP.OtherClass")
local otherClass = OtherClass   -- 立刻收敛为局部别名

return {
    order  = 20,
    name   = "OtherOOP",
    create = otherClass,       -- 签名已是 (name, base)
    new    = "New",            -- 建实例：C.New()
    delete = "Delete",         -- 删除：o.Delete(o)
    ctor   = "__init",
    dtor   = "__delete",
    -- 类表默认值 + 实例读穿透：类表赋值经 __newindex 落进 vTable，实例 __index 正指向 vTable，
    -- 读路径＝实例 miss → 表 __index → vTable 命中，与原生表 / 本框架同一口径。
    set_default = true,
}