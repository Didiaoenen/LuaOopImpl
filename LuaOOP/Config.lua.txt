local Config = {}

Config.LuaVersion = tonumber(_VERSION:sub(5))

Config.Field =
{
    set = "set",
    get = "get",
    opt = "opt",

    ctor = "ctor",
    dtor = "dtor",

    as = "as",
    new = "new",
    delete = "delete",

    Instance = "Instance",

    __cls = "__cls",
    __bit = "__bit",

    __new = "__new",
    __delete = "__delete",
    __singleton = "__singleton",

    __internal = "__internal",

    __name = "__name",
};

Config.BitMap =
{
    get = 1 << 1,
    set = 1 << 2,
    opt = 1 << 3,
}

Config.OwnBit =
{
    member = 1 << 16,
    method = 1 << 17,
}

local WeakTable = {__mode = "k"}

Config.Tables =
{
    ClassesNamed     = {},

    ClassesDeathMark = setmetatable({}, WeakTable),

    ClassesMembers   = setmetatable({}, WeakTable),
    ClassesMetaFunc  = setmetatable({}, WeakTable),

    ClassesBases     = setmetatable({}, WeakTable),
    ClassesChild     = setmetatable({}, WeakTable),

    ClassesWritable  = setmetatable({}, WeakTable),
    ClassesReadable  = setmetatable({}, WeakTable),

    ClassesSingleton = setmetatable({}, WeakTable),

    ClassesRouter    = setmetatable({}, WeakTable),

    ClassesOwn       = setmetatable({}, WeakTable),

    ClassesVTable    = setmetatable({}, WeakTable),

    ClassesDtorChain = setmetatable({}, WeakTable),
    ClassesAncestors = setmetatable({}, WeakTable),

    ClassesFuncIndex     = setmetatable({}, WeakTable),
    ClassesFuncNewIndex  = setmetatable({}, WeakTable),
}

Config.LazyDtorChain = false

Config.SafeCreate = true

Config.MetaFunc =
{
    __call = "__call",
    __tostring = "__tostring",
}

return Config