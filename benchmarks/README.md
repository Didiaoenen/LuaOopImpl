# 基准测试目录

本目录收录 LuaOOP 框架（`LuaOOP/`）与对照实现（`OtherOOP/`）的性能基准脚本。`OtherOOP/` 下提供最基础的对照实现：

- `OtherClass.lua` —— 单继承 vTable 实现（输出列名 `OtherOOP`）

```
benchmarks/
├── run_benchmark.bat      # 统一运行入口（默认跑 suite/）
├── suite/                 # 常规套件：长期可复现，结果用于对外说明
│   ├── oop_benchmark.lua  # 42 项共有功能 N 列并排（只放「测试定义 + 入口」）
│   ├── oop_features_profile.lua # 本框架独有特性单侧测量（属性 / 单例 / 多继承 / COW / 热更新 …）
│   ├── impl_adapter.lua   # 适配层机制：接入字段契约 + 校验归一化 + 形状工厂 + impls/ 目录扫描
│   └── impls/             # 适配层实例：一个 OOP 实现一个文件（增删文件即增删列）
│       ├── native.lua     #   原生表 metatable（手写等价实现，下界参考）
│       ├── otherclass.lua #   OtherOOP/OtherClass.lua
│       └── luaoop.lua     #   本框架 LuaOOP/
├── investigations/        # 专项排查：为定位本框架某个具体开销而写，按需运行
└── pending/               # 待优化项：留待继续改进的常驻工作台
```

## 对比写法（实现无关）

跨实现的对比脚本**只把每项测试写一次**；实现特有的东西（多继承、属性、单例等）一概不进共享基准。
参与对比的实现在 `suite/impls/` 下各占**一个适配层文件**，入口一行自动收集：

```lua
Test(table.unpack(Adapter.discover()))
```

- **新增一个 OOP 实现＝往 `impls/` 放一个文件；删掉一个实现＝删掉那个文件。**
  测试文件、入口、`impl_adapter.lua` 都不用改（连第三方目录一起删即可）。
- **列顺序**由适配层里的 `order` 字段决定（省略 = 100，同值按文件名升序）。默认：
  `native` 10 / `otherclass` 20 / `luaoop` 90。
- **想临时只跑其中几个**：把不需要的适配层文件移出 `impls/`，或把入口改成显式传表——
  `Adapter.discover()` 返回的就是按列顺序排好的实现表数组，直接挑：

  ```lua
  local impls = Adapter.discover()
  Test(impls[1], impls[3])           -- 只跑第 1、3 列
  ```

  （"相对原生表下界"汇总行只在传入的实现里带 `lower_bound = true` 时才出现。）
- **适配层机制单独放在 `suite/impl_adapter.lua`**：接入字段逐字段说明、`validate`/`norm`/
  `caps_of`/`req_ok`、建删实例的形状工厂、`impls/` 扫描（`M.discover`）都在那里；
  `suite/oop_benchmark.lua` 只留「42 项测试定义 + 入口」。
- 实现不具备的能力**不参与测试**，该单元格显示 `n/a`（适配层给 `delete = false` 即视为无同步删除）。
  默认集合（原生表 / OtherOOP / LuaOOP）都提供同步删除与析构，因此没有 `n/a`。
- 加载顺序：多个实现可能占用同一个全局名（如 `class`）。适配层在每个文件里 `require` 之后**紧邻**
  捕获并收敛为局部别名，因此扫描顺序不影响结果。
- `investigations/` 与 `pending/` 只测本框架自身，不引入对照实现；跨实现的对比一律放在 `suite/`。

## 实现表接口（新增对照实现的方式）

新增实现：在 `suite/impls/` 下建一个文件，顶层 `return` 一张实现表即可——`M.discover()` 会自动收集它。
最简骨架（照抄一份现有文件通常更快，三个现成例子见 `suite/impls/`）：

```lua
-- suite/impls/xxx.lua
require("Xxx.OOP")          -- 该实现自己的加载方式
local xClass = class        -- require 之后**紧邻**捕获它占用的全局，收敛为局部别名
return {
    order  = 50,            -- 列顺序（省略 = 100，同值按文件名升序）
    name   = "Xxx",         -- 输出表头列名（必给）
    create = xClass,        -- 建类入口（必给）
}
-- 其余字段全部走默认值：new = "new"、delete = "delete"、ctor = "ctor"、dtor = "dtor"、
-- set_method = cls[k] = fn、redefine = cls[k] = fn；set_default 缺省 ⇒ COW 两项 n/a。
```

字段的完整语义（含三种建实例形状、反例、缺省后果）写在 `suite/impl_adapter.lua` 头部；
`norm()` 归一化后，测试定义只使用形状工厂 `A.obj` / `A.t_new` / `A.t_new_delete` /
`A.t_new_use_delete` / `A.t_new_call2`，不再感知实现形状。
**最少只要两项**（`name` / `create`），其余按本框架口径取默认值。
原语**只在准备阶段调用，绝不进入计时闭包**（形状分支也在准备期展开）。

| 字段 | 必需性 | 签名 | 说明 |
|------|--------|------|------|
| `name` | 必给 | string | 输出列名 |
| `create` | 必给 | `(name, base) -> cls` | 建类；直接写该实现的 class 函数即可；`base = nil` 表示无继承 |
| `new` | 可省 | `true` / string / `(C, ...) -> obj` | 建实例形状；省略 = `"new"`。`true` ⇒ `C(...)`（类表带 `__call`）；string ⇒ `C[名字](...)`（如 `"New"`）；函数 ⇒ 本地建实例函数（类表上没有构造入口时，如原生表 `NNew`） |
| `delete` | 可省 | string / `(obj, cls)` / `false` | 删除形状；省略 = `"delete"`；`false` = 该实现无同步删除 |
| `ctor` / `dtor` | 可省 | string 或 `(cls, body)` | 构造／析构写入方式；默认 `"ctor"` / `"dtor"`；`dtor = false` 表示无析构 |
| `set_method` | 可省 | `(cls, k, fn)` | 往类表装方法；默认 `cls[k] = fn` |
| `set_default` | 可省 | `(cls, k, v)` 或 `true` | 类表默认值写入；`true` 等价 `cls[k] = v`；缺 ⇒ 无"类表默认值 + 读穿透"，COW 两项 `n/a` |
| `redefine` | 可省 | `(cls, k, fn)` 或 `false` | 改写已有成员；默认 `cls[k] = fn`；`false` ⇒ 热更新项 `n/a` |
| `order` | 可省 | number | 列顺序；省略 = 100，同值按文件名升序（只被 `discover()` 读） |
| `new_bare` | 可省 | `(cls) -> obj` | 不跑 ctor 建实例（原生表下界用） |
| `ops[key]` | 可省 | `(ctx) -> 计时闭包` | 逐测试覆盖钩子，仅当该项的计时体无法在共享层统一时才需要；`ctx.uid(prefix)` 生成唯一类名 |
| `reference` / `lower_bound` | 可省 | bool | 标记本框架侧（倍率基准）／原生表下界（驱动"相对原生表下界"汇总行） |

缺省后果：

| 字段 | 缺省后果 |
|------|----------|
| `ctor` / `dtor` 之一给 `false` | 完整生命周期 / 实例删除 / 析构函数链 3 项 `n/a` |
| `set_default` | COW 两项 `n/a`（**刻意如此**：不能把"无此能力"静默变成 `cls[k] = v`，否则 `n/a` 会变成一列错数据） |
| `ops[key]` | 退到共享层的通用计时体（两项类创建＝"create + 写 ctor + 写一个方法"） |

`ops` 目前只有两类用法：`class_creation` / `inherit_class_creation`（实现在建类期需要额外动作时才给，
如原生表要同步预置构造链、本框架的 ctor 写入要包装基类构造；
没有额外动作的实现（如 `otherclass.lua`）退到共享层的通用计时体）。

## 统一约定

- **路径引导**：所有脚本按自身位置解析仓库根目录（本文件所在目录的上两级），
  因此从任意工作目录运行结果一致，不再依赖 CWD 的 `./?.lua`。
- **计时口径**：脚本内注明单位（`us/op` 或 `ns/op`）。对稳定性要求高的场景采用
  "预热 + best-of-N + 每次 `collectgarbage`"，避免顺序偏置与 GC 抖动。
- **命名**：统一为 `<对象>[_<限定>]_<手段>.lua`，全小写蛇形命名。
  对象写"测什么"，手段写"怎么测"，取自固定词表：

  | 手段后缀 | 含义 |
  |----------|------|
  | `_compare` | 多组对照（2 组以上、或开关开/关） |
  | `_profile` | 单侧测量：只报原始数字，无对照 |
  | `_breakdown` | 成本逐层拆解，定位开销落在哪一步 |
  | `_check` | 功能自检（顺序 / 去重 / 热更新等语义验证） |
  | `_repro` | 已知问题复现验证 |

  对照直接写成 `<A>_vs_<B>.lua`，不再追加 `_compare`。
  例：`class_create_breakdown.lua`、`class_create_profile.lua`。
  例外：`suite/oop_benchmark.lua` 是"实现由 `impls/` 决定"的通用 N 列对比，不写成 `_vs_`。

## 运行方式

```bat
:: 入口（跑 suite/ 全部脚本）
benchmarks\run_benchmark.bat

:: 单个脚本，在仓库根目录执行即可
lua54 benchmarks\suite\oop_benchmark.lua
```

`investigations/index_mode_compare.lua` 支持环境变量调参：

| 环境变量 | 含义 | 默认值 |
|----------|------|--------|
| `BENCH_N` | 热路径迭代次数 | 1000000 |
| `BENCH_CREATE_N` | 创建类/实例迭代次数 | 100000 |
| `BENCH_RUNS` | best-of-N 重复轮数 | 3 |

## suite/ — 常规套件

| 脚本 | 覆盖内容 | 计时口径 | 说明 |
|------|----------|----------|------|
| `oop_benchmark.lua` | 42 项共有功能 N 列并排（默认：原生表 metatable / OtherOOP / LuaOOP）；参与实现在 `suite/impls/` 下各占一个适配层文件，入口 `Test(table.unpack(Adapter.discover()))` 自动收集，增删文件即增删列 | best-of-3 + 每次 GC | 覆盖所有共有能力，含继承深度趋势与热路径专项；实现不具备的能力显示 `n/a`。多继承等实现特有功能不在这里，见 `oop_features_profile.lua` |
| `oop_features_profile.lua` | 本框架独有：属性(get/set/opt)、单例、多继承、菱形继承、COW 成员、Null 检查、热更新缓存失效、深层继承、SafeCreate 开关、大规模场景 | 预热后单轮均值 | 只测本框架，无对照（对照实现不具备这些能力） |

## investigations/ — 专项排查

只测本框架自身。按"本框架的哪项实现 / 机制"分组：

**类与继承构建**

| 脚本 | 回答的问题 |
|------|-----------|
| `class_create_profile.lua` | 类创建专项（根类 / 带方法 / 单继承 / 带属性），best-of-3 |
| `class_create_breakdown.lua` | `class(name)` 的完整路径手工展开成累加步骤，成本落在哪一步 |
| `pushbase_breakdown.lua` | `PushBase` 5 个步骤各自的成本 |
| `subclass_compare.lua` | 根类 vs 单继承 vs 双继承的差值（即 PushBase 全链路） |
| `inherit_skip_compare.lua` | 开关对照：根类是否调用 `CreateClassInherit(cls, {})` |
| `lazy_tables_compare.lua` | 开关对照：`CreateClassTables` 向 Bases/Child/Members 三张弱表写共享空表的成本 |

**析构链**

| 脚本 | 回答的问题 |
|------|-----------|
| `dtor_chain_profile.lua` | 预创建对象、只对 `delete` 计时，把 `new` 与 `delete` 分离；含菱形去重语义与 dtor 热更新 |
| `lazy_dtor_compare.lua` | 开关对照：`Config.LazyDtorChain` false（预建链）vs true（惰性） |
| `lazy_dtor_check.lua` | `LazyDtorChain = true` 模式的功能自检（顺序 / 去重 / 热更新 / 重入 / 置空） |

**方法查找与属性（双模式 `__index`）**

| 脚本 | 回答的问题 |
|------|-----------|
| `method_call_breakdown.lua` | 本类方法 / 继承方法 / 混合调用，并拆出"只查不调"与"纯调用"定位开销来源 |
| `property_vs_field.lua` | 属性 vs 字段逐环节成本分离，区分框架可优化项与 Lua 元方法固有开销 |
| `index_mode_compare.lua` | 表 `__index`（无属性类）vs 函数 `__index`（有属性类）两态对比 |
| `cow_read_breakdown.lua` | COW 类表默认值读的穿透开销分解：实例自有字段 / 表 `__index` / 函数 `__index` 三档，并与原生表同形状下界对照 |

**问题复现**

| 脚本 | 说明 |
|------|------|
| `issue_repro.lua` | 已知问题复现验证（属性装饰器别名、缓存失效等逐条确认） |

## pending/ — 后续优化工作台

与 `investigations/` 的区别：那里是"查清即完结"的一问一答，这里存放**准备继续改进**的常驻脚本与基线。

| 脚本 | 用途 | 现状 |
|------|------|------|
| `property_optimization.lua` | 属性（get/set/opt）访问开销的逐层拆解：区分框架可优化项与 Lua 元方法固有开销 | 已按现行实现校准：`[4]` 为同口径三行（历史假设 / 现行实现 / 扁平化），实测扁平化净收益读取 0.007~0.010、写入 0.008~0.010 us/op（读 14%~18%、写 19%~25%）；当前属性数据见 `suite/oop_features_profile.lua` |