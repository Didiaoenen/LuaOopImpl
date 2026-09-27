--[[
-- 已知问题复现验证
-- 逐条验证"高优先级逻辑问题"，确认是否为真、以及当前版本能否复现。
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

local function report(pNo, pTitle, pOk, pDetail)
    print(string.format("  [%s] %-38s %s", pOk and "PASS" or "FAIL", pTitle, pDetail or ""))
end

print("============================================================")
print("  已知问题复现验证")
print("============================================================")

-- ── 1. 属性装饰器别名 ──
print("\n[1] 装饰器别名（local get = C.get）")
do
    local C = class("RP1")
    local get = C.get
    local set = C.set

    get.x = function(self) return "GETTER" end
    set.x = function(self, pValue) self.raw = pValue end

    local obj = C.new()
    local readValue = obj.x
    report(1, "get.x 注册为 getter 而非 setter",
        readValue == "GETTER",
        "o.x = " .. tostring(readValue))
end

-- ── 2. 父类 getter 热更新被子类自有 setter 阻断 ──
print("\n[2] 父类 getter 热更新 vs 子类自有 setter")
do
    local A = class("RP2A")
    A.get.v = function(self) return "A1" end

    local B = class("RP2B", A)
    B.set.v = function(self, pValue) end

    local obj = B.new()
    local before = obj.v
    A.get.v = function(self) return "A2" end
    local after = obj.v

    report(2, "父类 getter 热更新对子类实例生效",
        after == "A2",
        "更新前=" .. tostring(before) .. " 更新后=" .. tostring(after))
end

-- ── 3. 多继承 __new 优先级 ──
print("\n[3] 多继承 __new 优先级（应先声明优先）")
do
    local X = class("RP3X")
    X.__new = function() return { from = "X" } end
    local Y = class("RP3Y")
    Y.__new = function() return { from = "Y" } end

    local Z = class("RP3Z", X, Y)
    local obj = Z.new()
    report(3, "class(Z, X, Y) 使用 X.__new",
        obj.from == "X",
        "实际来自 " .. tostring(obj.from))
end

-- ── 4. 父类 __new / __delete 热更新是否下发给已建子类 ──
print("\n[4] 父类 __new 热更新下发给已创建子类")
do
    local P = class("RP4P")
    P.__new = function() return { tag = "v1" } end

    local Q = class("RP4Q", P)
    local obj1 = Q.new()

    P.__new = function() return { tag = "v2" } end
    local obj2 = Q.new()

    report(4, "子类取到父类最新 __new",
        obj2.tag == "v2",
        "初始=" .. tostring(obj1.tag) .. " 热更新后=" .. tostring(obj2.tag))
end

-- ── 5. 缓存 obj.delete 后重复析构 ──
print("\n[5] 重复 delete（缓存 delete 方法引用）")
do
    local D = class("RP5")
    local count = 0
    D.dtor = function(self) count = count + 1 end

    local obj = D.new()
    local del = obj.delete
    del(obj)
    del(obj)

    report(5, "同一对象 dtor 只执行一次",
        count == 1,
        "dtor 执行次数 = " .. count)
end

-- ── 6. 非法参数校验 ──
print("\n[6] class() 参数合法性校验")
do
    local ok1, err1 = pcall(class, nil)
    report(6, "class(nil) 给出清晰错误",
        (not ok1) and tostring(err1):find("name", 1, true) ~= nil,
        tostring(err1):sub(1, 60))

    local ok2, err2 = pcall(class, "RP6", {})
    report(6, "class(name, 非类表) 给出清晰错误",
        (not ok2) and tostring(err2):find("base", 1, true) ~= nil,
        tostring(err2):sub(1, 60))
end

print("")
