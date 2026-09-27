# LuaOOP 框架

面向 Lua 5.4 的轻量面向对象框架：单/多继承、属性（get/set/opt）、单例、成员默认值、热更新、析构链、Null 检查。

零第三方依赖，核心实现只有 3 个源文件（合计约 1300 行，含注释）。仓库同时提供正确性测试（89 项断言）、两组性能基准，以及 `OtherOOP/` 目录下最基础的对照实现 `OtherClass.lua` 作为性能对照基线。

## 环境要求

- Lua 5.3 及以上（实测环境为 Lua 5.4 / Windows 64 位）。框架使用了位运算符，5.3 以下不可用。

## 目录结构

```
.
├── LuaOOP/                    # 框架本体
│   ├── Class.lua.txt          # 入口：只做编排，定义 class() 与 class.New
│   ├── Config.lua.txt         # 配置：字段名、通道位、全部共享弱表
│   └── ClassImpl.lua.txt      # 实现：34 个公开函数，框架全部逻辑
├── tests/
│   ├── oop_correctness.lua    # 正确性测试：89 项断言，退出码可用作 CI 门禁
│   └── README.md              # 测试数据与实测结果
├── benchmarks/
│   ├── run_benchmark.bat      # 统一运行入口
│   ├── suite/                 # 常规套件：结果用于对外说明
│   │   ├── oop_benchmark.lua  #   42 项共有功能 N 列并排（测试定义 + 入口）
│   │   ├── impl_adapter.lua   #   适配层机制：字段契约 / 归一化 / 形状工厂 / impls 扫描
│   │   └── impls/             #   适配层实例：一个 OOP 实现一个文件（增删文件即增删列）
│   ├── investigations/        # 专项排查：为定位某一项开销而写，按需运行
│   ├── pending/               # 待优化项：属性等后续优化的常驻工作台
│   └── README.md              # 基准脚本索引与计时口径
└── OtherOOP/                  # 对照实现：仅用于基准对比，不属于框架本体
    └── OtherClass.lua         # 单继承 vTable 实现
```

> 源文件以 `*.lua.txt` 命名，因此 `package.path` 需要同时覆盖 `?.lua.txt` 形式（详见下方加载示例）。

## 快速开始

```lua
-- 1. 配置搜索路径：仓库根目录加入 ?.lua 与 ?.lua.txt 两种形式
package.path = table.concat({
    "./?.lua",
    "./?.lua.txt",
    "./LuaOOP/?.lua.txt",
    package.path,
}, ";")

-- 2. 引入框架，require 后全局 class 即可用
require("LuaOOP.Class")

-- 3. 定义一个类
local Vec2 = class("Vec2")

Vec2.hp = 100                                   -- 成员默认值（copy-on-write）

Vec2.ctor = function(self, x, y)                -- 构造函数
    self.x = x or 0
    self.y = y or 0
end

Vec2.dtor = function(self)                      -- 析构函数
    print("Vec2 destroyed")
end

Vec2.len = function(self)                       -- 普通方法
    return math.sqrt(self.x * self.x + self.y * self.y)
end

Vec2.get.norm = function(self)                  -- 只读属性：obj.norm 触发
    return self:len()
end

Vec2.set.pair = function(self, v)               -- 只写属性：obj.pair = v 触发
    self.x, self.y = v[1], v[2]
end

Vec2.opt.label = function(self, v)              -- 读写属性：共用同一函数
    if nil == v then
        return self._label
    end
    self._label = v
end

-- 4. 使用
local v = Vec2.new(3, 4)
print(v.norm)          --> 5.0       读取属性走 getter

v.pair = { 1, 1 }                    写入属性走 setter
v.label = "unit"                     读写属性：写
print(v.label)         --> unit      读写属性：读

print(v:as(Vec2))      --> true      类型判断（也支持 Vec2.as(Vec2) 点语法）
print(v.hp)            --> 100       读成员默认值；一旦写入即落在实例上

v:delete()                           析构：跑析构链并打上死亡标记
```

### 单例

```lua
local Cfg = class("Cfg")
Cfg.ctor = function(self) self.value = 42 end
Cfg.__singleton = function() return Cfg.new() end

local a = Cfg.Instance
local b = Cfg.Instance
print(a == b)   --> true   多次获取同一实例

Cfg.Instance = nil          -- 赋 nil 销毁单例（内部调用其 :delete()）
```

### 判空与自定义创建

```lua
local ClassImpl = require("LuaOOP.ClassImpl")

print(ClassImpl.Null(v))     -- true：已 delete 的实例、nil、false 均视为"空"

-- __new 可替换实例工厂（返回值必须是 table，否则创建失败返回 nil）
local Pooled = class("Pooled")
Pooled.__new = function(...) return { pooled = true } end

-- __delete 做实例级清理，与 dtor 共用同一套继承解析缓存
Pooled.__delete = function(self) print("cleaned") end
```

## 特性一览

| 特性 | 用法 | 说明 |
|------|------|------|
| 单 / 多继承 | `class("C", A, B)` | 多继承**先声明优先**，方法 / 属性 / 成员默认值口径一致 |
| 构造函数 | `cls.ctor` | 沿继承链向上逐层执行（父类构造需显式调用，如 `A.ctor(self)`） |
| 析构函数 | `cls.dtor` | 子类先、父类后，菱形继承自动去重；重复 `delete` 不会重跑 |
| 成员默认值 | `cls.hp = 100` | 实例第一次写入才拷贝到自身（copy-on-write），读路径零拷贝 |
| 方法 | `cls.fn = function(self, ...)` | 支持多继承解析并缓存 |
| 只读属性 | `cls.get.x = function(self)` | 读 `obj.x` 触发 getter |
| 只写属性 | `cls.set.x = function(self, v)` | 写 `obj.x = v` 触发 setter |
| 读写属性 | `cls.opt.x = function(self, v)` | `v == nil` 视为读，其余视为写；读写共用一个属性项（单次访问开销与 `get` 持平，省的是定义面） |
| 单例 | `cls.__singleton` + `cls.Instance` | 类级静态属性，读取即惰性创建并缓存 |
| 自定义工厂 | `cls.__new` | 返回 table 作为实例，随后框架为其装元表并跑构造链 |
| 实例清理 | `cls.__delete` | 析构链之后执行 |
| 类型判断 | `obj:as(B)` / `cls.as(B)` | 基于每类预建祖先集合，一次哈希查询 |
| 判空 | `ClassImpl.Null(obj)` | 覆盖 `nil` / `false` / 已删除实例 |
| 热更新 | 对类重新赋值 | 已创建实例与子类立即读到新值；属性与方法可互相改写 |

### 热更新

在类定义之后随时重新赋值，已存在的实例与子类都会立即生效：

```lua
local A = class("A")
A.fn = function(self) return 1 end

local B = class("B", A)
local b = B.new()
print(b:fn())            --> 1

A.fn = function(self) return 2 end
print(b:fn())            --> 2   已存在实例同样读到新方法

A.get.val = function(self) return 42 end
print(b.val)             --> 42  方法可原地改写为属性，反之亦然
```

## 运行测试与基准

```bat
:: 正确性测试（89 项断言；退出码 0 = 全通过，1 = 有失败）
lua54 tests\oop_correctness.lua

:: 性能基准（跑 benchmarks\suite\ 全部脚本）
benchmarks\run_benchmark.bat

:: 单个基准脚本
lua54 benchmarks\suite\oop_benchmark.lua
```

所有脚本均按自身位置解析仓库根目录，从任意工作目录运行结果一致。

`benchmarks/suite/oop_benchmark.lua` 的参与实现由 `benchmarks/suite/impls/` 决定：**每个 OOP 实现对应
该目录下的一个适配层文件**，入口一行 `Test(table.unpack(Adapter.discover()))` 自动扫描收集，扫到几个就有几列。
新增一个实现＝往 `impls/` 放一个文件；删掉一个实现＝删掉那个文件——测试文件、入口与 42 项测试定义
都不用改（列顺序由适配层里的 `order` 决定，省略 = 100）。也可以临时改成显式传表——
`Adapter.discover()` 返回的就是按列顺序排好的实现表数组，挑其中几个即可：

```lua
local impls = Adapter.discover()
Test(impls[1], impls[3])   -- 只跑第 1、3 列
```

接入字段的逐字段契约、校验归一化、建删实例的形状工厂与目录扫描
统一收在 `benchmarks/suite/impl_adapter.lua`，测试文件本身只剩「测试定义 + 入口」
（实现表接口见 [benchmarks/README.md](benchmarks/README.md)）。

- 测试数据与分组明细见 [tests/README.md](tests/README.md)
- 基准脚本索引与计时口径见 [benchmarks/README.md](benchmarks/README.md)

### 性能摘要

`benchmarks/suite/oop_benchmark.lua` 对 42 项共有功能做 N 列并排（默认：原生表 metatable / `OtherOOP/OtherClass.lua` / 本框架）：

| 项目 | 相对 OtherOOP |
|------|----------|
| 实例创建 / 继承实例创建 | 2.00x / 1.72x 快 |
| 完整生命周期（创建+使用+删除） | 1.47x 快 |
| 构造链（3 层） | 1.49x 快 |
| 继承方法调用（1 层） | 1.69x 快 |
| 继承方法调用（10 层） | 11.04x 快（方法查找与继承深度解耦） |
| 混合操作（创建 + 读写 + 方法） | 1.95x 快 |
| 字段读写 / 方法调用 | 基本持平（±10% 内） |
| COW 成员默认值读取 | 略慢（0.030 vs 0.029，1.05x） |
| 类创建 / 单继承子类创建 | 2.55x / 2.95x 慢（多继承 / 属性 / 单例等能力的元数据构造成本，只在类定义期付出一次，不进热路径） |

其中原生表 metatable 为手写等价实现，作为"无框架"的下界参考：可比 42 项中本框架 13 项更快、17 项更慢、12 项持平；更快项集中在方法调用与深层继承方法调用，更慢项集中在类 / 实例创建与析构链（元数据构造与析构链开销）。

实现不具备的能力不参与测试、该单元格记 `n/a`（由适配层声明的能力决定）。默认集合（原生表 / OtherOOP / LuaOOP）都提供同步删除与析构，无 `n/a`。可比项统计：OtherOOP 对照 42 项中 LuaOOP 领先 29 项、落后 8 项、持平 5 项。

LuaOOP 独有特性的开销（`benchmarks/suite/oop_features_profile.lua`，以字段读取为基准 1.0x）：

- 属性单次访问 14.0x~14.4x（get / opt 读，get / set / opt 三行同档，0.066~0.072 us/op）—— 三行的属性函数体统一为"读写一个实例字段"后，开销只由"元表拦截 + 一次属性函数调用"决定，与读写方向无关；`opt` 省的是定义面（读写共用一个属性项），不是单次访问
- 继承深度从 3 层到 20 层，方法调用开销基本不变（0.051 → 0.054 us/op），与深度解耦
- 热更新后（稳态）方法调用与常态一致（均 0.058 us/op）：失效重建只发生在首次访问、不进热路径

数值为相对指标，受机器性能与 GC 时机影响，请关注倍率而非绝对值。表内为 2026-09-27 单次运行实测值（`Config.SafeCreate = true` 默认配置，best-of-3 + 每次 GC）；领先 / 落后 / 持平的判定阈值为 ±0.5%，创建 / 构造类测试项的 run-to-run 波动可达 ±20%，计数会有 ±3 项波动。

## 实现速览

建议阅读顺序：`Class.lua.txt`（整体流程）→ `Config.lua.txt`（常量与弱表）→ `ClassImpl.lua.txt`（实现）。

几处决定性设计：

- **VTable 方法虚表**：方法与成员默认值写入每类一张的 VTable，而非 `rawset` 到类表。实例 `__index` 第一级即单次哈希命中本类 VTable，继承项首次访问时沿基类链解析（`SearchBaseMethod`）并缓存。
- **双模式 `__index`**：未声明属性的类直接把 VTable 当实例 `__index`（纯表查找，零函数调用开销）；一旦声明 get/set/opt，经 `SwitchToFuncIndex` 切换为函数闭包以拦截属性读写，并递归下发给所有后代。
- **自有 / 继承分离**：`ClassesOwn` 记录每类"自己声明过的通道"，缓存失效只清子类中"继承来的"项，避免父类热更新击穿子类覆盖。
- **析构链预计算**：`ClassesDtorChain` 在"类定义 dtor / 继承基类 / dtor 热更新"时算好"子类先、父类后、菱形去重"的调用链，`delete` 只做一次数组遍历；`ClassesDeathMark` 在调用 dtor 前置位以实现重入保护。
- **惰性建表**：`Bases` / `Child` / `Members` 默认共享一张只读空表（`EmptyList`），首次写入才经 `EnsureList` 换成私有表，省掉绝大多数类终其一生都空着的若干张表。

## 仓库其他内容

- [`OtherOOP/OtherClass.lua`](OtherOOP/OtherClass.lua) —— 单继承 vTable 实现，无属性 / 多继承 / 热更新能力。放在 `OtherOOP/` 下，仅作为性能对照基线，不属于框架本体；基准侧对应的适配层是 [`benchmarks/suite/impls/otherclass.lua`](benchmarks/suite/impls/otherclass.lua)。