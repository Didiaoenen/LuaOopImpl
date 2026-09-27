local Config = require("LuaOOP.Config")

local Field       = Config.Field
local Tables      = Config.Tables
local BitMap      = Config.BitMap
local OwnBit      = Config.OwnBit

local as          = Field.as
local new         = Field.new
local delete      = Field.delete

local ctor        = Field.ctor
local dtor        = Field.dtor

local get         = Field.get
local set         = Field.set
local opt         = Field.opt

local __cls       = Field.__cls
local __bit       = Field.__bit

local __new       = Field.__new
local __delete    = Field.__delete
local __singleton = Field.__singleton

local __internal  = Field.__internal

local ClassesNamed       = Tables.ClassesNamed

local ClassesDeathMark   = Tables.ClassesDeathMark

local ClassesMembers     = Tables.ClassesMembers
local ClassesMetaFunc    = Tables.ClassesMetaFunc

local ClassesBases       = Tables.ClassesBases
local ClassesChild       = Tables.ClassesChild
local ClassesWritable    = Tables.ClassesWritable
local ClassesReadable    = Tables.ClassesReadable

local ClassesSingleton   = Tables.ClassesSingleton

local ClassesRouter      = Tables.ClassesRouter

local ClassesOwn         = Tables.ClassesOwn
local ClassesVTable      = Tables.ClassesVTable
local ClassesDtorChain   = Tables.ClassesDtorChain
local ClassesAncestors   = Tables.ClassesAncestors

local ClassesFuncIndex     = Tables.ClassesFuncIndex
local ClassesFuncNewIndex  = Tables.ClassesFuncNewIndex

local mGet = BitMap.get
local mSet = BitMap.set
local mOpt = BitMap.opt
local mGS = mGet | mSet

local mMember = OwnBit.member
local mMethod = OwnBit.method

local mReader = mMember | mMethod | mGet | mOpt
local mWriter = mMember | mMethod | mSet | mOpt

local ClassImpl = {}

local EmptyList = {}

function ClassImpl.EnsureList(pTable, pCls)
    if nil == pTable[pCls] or pTable[pCls] == EmptyList then
        pTable[pCls] = {}
    end
    return pTable[pCls]
end

function ClassImpl.MarkOwn(pCls, pKey, pBit)
    if nil == ClassesOwn[pCls] then
        ClassesOwn[pCls] = {}
    end
    ClassesOwn[pCls][pKey] = (ClassesOwn[pCls][pKey] or 0) | pBit
end

function ClassImpl.SearchBaseMethod(pCls, pKey)
    for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
        local value = rawget(ClassesVTable[base], pKey)
        if nil ~= value then
            return value
        end

        value = ClassImpl.SearchBaseMethod(base, pKey)
        if nil ~= value then
            return value
        end
    end
    return nil
end

function ClassImpl.ResolveMember(pCls, pKey)
    for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
        local value = (ClassesMembers[base] or EmptyList)[pKey]
        if nil ~= value then
            return value
        end
    end
    return nil
end

local VTableInheritMeta =
{
    __index = function (pTable, pKey)
        local pCls = rawget(pTable, __cls)
        if nil == pCls then
            return nil
        end
        local found = ClassImpl.SearchBaseMethod(pCls, pKey)
        if nil ~= found then
            pTable[pKey] = found
            return found
        end
    end
}

function ClassImpl.InstallVTableInherit(pCls)
    local vTable = ClassesVTable[pCls]
    if getmetatable(vTable) or ClassesFuncIndex[pCls] then
        return
    end

    vTable[__cls] = pCls
    setmetatable(vTable, VTableInheritMeta)
end

function ClassImpl.SwitchToFuncIndex(pCls)
    if ClassesFuncIndex[pCls] then
        return
    end

    local vTable = ClassesVTable[pCls]
    local readable = ClassImpl.EnsureClassProperty(pCls)
    local writable = ClassesWritable[pCls]

    local funcIndex = function (pTable, pKey)
        local value = vTable[pKey]
        if nil ~= value then
            return value
        end

        local property = readable[pKey]
        if property and not property[2] then
            return property[1](pTable)
        end

        value = ClassImpl.SearchBaseMethod(pCls, pKey)
        if nil ~= value then
            vTable[pKey] = value
            return value
        end
    end
    ClassesFuncIndex[pCls] = funcIndex

    local funcNewIndex = function (pTable, pKey, pValue)
        local property = writable[pKey]
        if property and not property[2] then
            property[1](pTable, pValue)
            return
        end
        rawset(pTable, pKey, pValue)
    end
    ClassesFuncNewIndex[pCls] = funcNewIndex

    vTable[__cls] = nil
    setmetatable(vTable, nil)

    local metaFunc = ClassesMetaFunc[pCls]
    metaFunc.__index = funcIndex
    metaFunc.__newindex = funcNewIndex

    for _, child in ipairs(ClassesChild[pCls] or EmptyList) do
        ClassImpl.SwitchToFuncIndex(child)
    end
end

function ClassImpl.Null(pObj)
    if "table" == type(pObj) then
        return ClassesDeathMark[pObj] == true
    end
    return not pObj
end

function ClassImpl.GetSingleton(pObj, pCall)
    local singleCls = ClassesSingleton[pObj]
    if ClassImpl.Null(singleCls) then
        singleCls = pCall(pObj)
        ClassesSingleton[pObj] = singleCls
    end
    return singleCls
end

function ClassImpl.DestroySingleton(pObj, pValue)
    if nil == pValue then
        local singleCls = ClassesSingleton[pObj]
        if not ClassImpl.Null(singleCls) then
            singleCls:delete()
            ClassesSingleton[pObj] = nil
        end
    end
end

function ClassImpl.CreateClass(pName)

    if "string" ~= type(pName) then
        error("class name must be a string, got " .. type(pName))
    end

    local cls = { [Field.__name] = pName }

    if ClassesNamed[pName] then
        error(("You cannot use this name \"%s\", which is already used by other class.").format(pName))
    else
        ClassesNamed[pName] = cls
    end

    return cls
end

function ClassImpl.PushBase(pCls, pBase)

    -- 基类必须是 class() 创建出来的类（有 VTable 即视为框架类）
    if nil == ClassesVTable[pBase] then
        error("base must be a class created by class(), got " .. type(pBase))
    end

    local baseMembers = ClassesMembers[pBase] or EmptyList
    local vTable = ClassesVTable[pCls]

    local members
    for key, value in pairs(baseMembers) do
        members = members or ClassImpl.EnsureList(ClassesMembers, pCls)
        if nil == members[key] then
            members[key] = value
            vTable[key] = value
        end
    end

    table.insert(ClassImpl.EnsureList(ClassesBases, pCls), pBase)
    table.insert(ClassImpl.EnsureList(ClassesChild, pBase), pCls)

    if ClassesFuncIndex[pBase] then
        ClassImpl.SwitchToFuncIndex(pCls)
    else
        ClassImpl.InstallVTableInherit(pCls)
    end

    local baseChain = ClassesDtorChain[pBase]
    if baseChain and #baseChain > 0 then
        ClassImpl.RefreshDtorChain(pCls)
    end
end

function ClassImpl.CollectAncestors(pCls, pSet)
    for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
        if nil == pSet[base] then
            pSet[base] = true
            ClassImpl.CollectAncestors(base, pSet)
        end
    end
end

function ClassImpl.ClassAs(pCls, pBase)
    if nil == pBase then
        return false
    elseif pBase == pCls then
        return true
    end

    if nil == ClassesAncestors[pCls] then
        ClassesAncestors[pCls] = {}
        ClassImpl.CollectAncestors(pCls, ClassesAncestors[pCls])
    end

    return ClassesAncestors[pCls][pBase] == true
end

function ClassImpl.CreateClassAs(pCls)
    return function (pSelf, pBase)
        if nil == pBase then
            return ClassImpl.ClassAs(pCls, pSelf)
        end
        return ClassImpl.ClassAs(pCls, pBase)
    end
end

function ClassImpl.CreateClassObject(pCls, ...)

    local vTable = ClassesVTable[pCls]

    if nil == vTable[__new] then
        vTable[__new] = ClassImpl.SearchBaseMethod(pCls, __new) or false
    end

    local newCls = vTable[__new]
    local obj = newCls and newCls(...) or {}

    local tempObj = nil
    if "table" == type(obj) then
        tempObj = obj
    end
    return tempObj
end

function ClassImpl.CascadeGet(pCls, pKey, pCalled)

    if pCalled[pCls] then
        return
    end

    pCalled[pCls] = true

    local ret = ClassesVTable[pCls][pKey]
    if nil ~= ret then
        return ret
    end

    ret = rawget(pCls, pKey)
    if nil ~= ret then
        return ret
    end

    for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
        ret = ClassImpl.CascadeGet(base, pKey, pCalled)
        if nil ~= ret then
            return ret
        end
    end
end

function ClassImpl.ClassGet(pCls, pKey)

    local decorBit = BitMap[pKey]
    if decorBit then
        return ClassImpl.EnsureClassRouter(pCls, decorBit)
    end

    local readable = ClassesReadable[pCls]
    if readable then
        local property = readable[pKey]
        if property and property[2] then
            return property[1](pCls)
        end
    end

    local ret = ClassesVTable[pCls][pKey]
    if nil ~= ret then
        return ret
    end

    ret = (ClassesMembers[pCls] or EmptyList)[pKey]
    if nil ~= ret then
        return ret
    end

    for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
        ret = ClassImpl.CascadeGet(base, pKey, {})
        if nil ~= ret then
            return ret
        end
    end
end

function ClassImpl.ClassSet(pCls, pKey, pValue)
    if pKey == __new then

        ClassesVTable[pCls][__new] = pValue
        ClassImpl.MarkOwn(pCls, pKey, mMethod)
        ClassImpl.InvalidateCache(pCls, pKey)

    elseif pKey == __delete then

        ClassesVTable[pCls][__delete] = pValue
        ClassImpl.MarkOwn(pCls, pKey, mMethod)
        ClassImpl.InvalidateCache(pCls, pKey)

    elseif pKey == __singleton then

        local readable = ClassImpl.EnsureClassProperty(pCls)
        local writable = ClassesWritable[pCls]

        readable[Field.Instance] = { function () return ClassImpl.GetSingleton(pCls, pValue) end, true }
        writable[Field.Instance] = { function () ClassImpl.DestroySingleton(pCls) end, true }

        ClassImpl.MarkOwn(pCls, Field.Instance, mGet | mSet)

    else

        local writable = ClassesWritable[pCls]
        local property = writable and writable[pKey]
        if property and property[2] then
            property[1](pCls, pValue)
            return
        end

        local metaValue = BitMap[pKey]
        if metaValue then
            ClassesMetaFunc[pCls][metaValue] = pValue
            ClassImpl.Update2ChildrenWithKey(pCls, ClassesMetaFunc, metaValue, pValue)
            return
        end

        local vTable = ClassesVTable[pCls]
        if "function" == type(pValue) then
            local members = ClassesMembers[pCls] or EmptyList
            if nil ~= members[pKey] then
                members[pKey] = nil
                ClassImpl.Update2ChildrenMember(pCls, pKey, nil)
            end

            vTable[pKey] = pValue
            ClassImpl.MarkOwn(pCls, pKey, mMethod)
            ClassImpl.InvalidateCache(pCls, pKey)

            if pKey == dtor then
                ClassImpl.RefreshDtorChain(pCls)
            end
        else
            if nil == rawget(pCls, pKey) then
                ClassImpl.EnsureList(ClassesMembers, pCls)[pKey] = pValue
                ClassImpl.Update2ChildrenMember(pCls, pKey, pValue)
            end
            
            vTable[pKey] = pValue
            ClassImpl.MarkOwn(pCls, pKey, mMember)
            ClassImpl.InvalidateCache(pCls, pKey)

            if pKey == dtor then
                ClassImpl.RefreshDtorChain(pCls)
            end
        end
    end
end

local ClassMeta =
{
    __index = ClassImpl.ClassGet,
    __newindex = ClassImpl.ClassSet,
}

function ClassImpl.MakeInternalObjectMeta(pCls)

    local metaFunc = ClassesMetaFunc[pCls]

    local vTable = {}
    ClassesVTable[pCls] = vTable

    vTable[Field.__name] = pCls[Field.__name]

    metaFunc.__index = vTable

    setmetatable(pCls, ClassMeta)
end

function ClassImpl.FillDtorChain(pChain, pCls, pVisited, pBases)

    if pVisited[pCls] then
        return
    end
    pVisited[pCls] = true

    local ownDtor = rawget(ClassesVTable[pCls], dtor)
    if ownDtor then
        pChain[#pChain + 1] = ownDtor
    end

    for _, base in ipairs(pBases[pCls] or EmptyList) do
        ClassImpl.FillDtorChain(pChain, base, pVisited, pBases)
    end
end

function ClassImpl.RefreshDtorChain(pCls)

    local chain = ClassesDtorChain[pCls]
    if nil == chain then
        ClassesDtorChain[pCls] = {}
        chain = ClassesDtorChain[pCls]
    else
        for i = #chain, 1, -1 do
            chain[i] = nil
        end
    end

    if #(ClassesBases[pCls] or EmptyList) > 0 then
        ClassImpl.FillDtorChain(chain, pCls, {}, ClassesBases)
    else
        local ownDtor = rawget(ClassesVTable[pCls], dtor)
        if ownDtor then
            chain[1] = ownDtor
        end
    end

    for _, child in ipairs(ClassesChild[pCls] or EmptyList) do
        ClassImpl.RefreshDtorChain(child)
    end
end

function ClassImpl.CreateClassDelete(pCls)

    local chain = ClassesDtorChain[pCls]
    if nil == chain and not Config.LazyDtorChain then
        ClassImpl.RefreshDtorChain(pCls)
        chain = ClassesDtorChain[pCls]
    end

    local vTable = ClassesVTable[pCls]

    return function (pObj)

        if ClassesDeathMark[pObj] then
            return
        end
        ClassesDeathMark[pObj] = true

        local dtorChains = chain or ClassesDtorChain[pCls]
        if nil ~= dtorChains then
            for i = 1, #dtorChains do
                dtorChains[i](pObj)
            end
        end

        if nil == vTable[__delete] then
            vTable[__delete] = ClassImpl.SearchBaseMethod(pCls, __delete) or false
        end

        if vTable[__delete] then
            vTable[__delete](pObj)
        else
            setmetatable(pObj, nil)
            if Config.ClearMembersInRelease then
                for key, value in pairs(pObj) do
                    pObj[key] = nil
                end
            end
        end
    end
end

local ReadableInheritMeta =
{
    __index = function (pTable, pKey)
        local pCls = rawget(pTable, __cls)
        if nil == pCls then
            return nil
        end
        for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
            local baseProps = ClassesReadable[base]
            if baseProps then
                local entry = baseProps[pKey]
                if entry then
                    pTable[pKey] = entry
                    return entry
                end
            end
        end
    end
}

local WritableInheritMeta =
{
    __index = function (pTable, pKey)
        local pCls = rawget(pTable, __cls)
        if nil == pCls then
            return nil
        end
        for _, base in ipairs(ClassesBases[pCls] or EmptyList) do
            local baseProps = ClassesWritable[base]
            if baseProps then
                local entry = baseProps[pKey]
                if entry then
                    pTable[pKey] = entry
                    return entry
                end
            end
        end
    end
}

function ClassImpl.EnsureClassProperty(pCls)
    local readable = ClassesReadable[pCls]
    if readable then
        return readable
    end

    ClassesReadable[pCls] = setmetatable({ [__cls] = pCls }, ReadableInheritMeta)
    ClassesWritable[pCls] = setmetatable({ [__cls] = pCls }, WritableInheritMeta)
    return ClassesReadable[pCls]
end

local RouterMeta =
{
    __index = function (t, pKey)
        local pCls = rawget(t, __cls)
        if nil == pCls then
            return nil
        end
        return ClassImpl.RouterGet(pCls, t, pKey)
    end,
    __newindex = function (t, pKey, pValue)
        local pCls = rawget(t, __cls)
        if pCls then
            ClassImpl.RouterSet(pCls, t, pKey, pValue)
        end
    end
}

function ClassImpl.EnsureClassRouter(pCls, pBit)
    if nil == ClassesRouter[pCls] then
        ClassesRouter[pCls] = {}
    end

    local routers = ClassesRouter[pCls]
    if nil == routers[pBit] then
        routers[pBit] = setmetatable({ decor = pBit, [__cls] = pCls }, RouterMeta)
    end

    return routers[pBit]
end

function ClassImpl.CreateClassTables(pCls)
    ClassesMetaFunc[pCls] = { [Field.__internal] = true }
end

function ClassImpl.AttachClassFunctions(pCls, pAs, pNew, pDelete)
    
    local vTable = ClassesVTable[pCls]
    
    vTable[as] = pAs
    vTable[new] = pNew
    vTable[delete] = pDelete
end

function ClassImpl.CreateClassInherit(pCls, args)
    for _, base in ipairs(args) do
        ClassImpl.PushBase(pCls, base)
    end
end

function ClassImpl.Update2ChildrenWithKey(pCls, pKeyTable, pKey, pValue, pForce)
    local children = ClassesChild[pCls]
    if nil == children or #children == 0 then
        return
    end

    for _, child in ipairs(children) do
        local temp = pKeyTable[child]
        if pForce and temp or not temp[pKey] then
            temp[pKey] = pValue
        end
        ClassImpl.Update2ChildrenWithKey(child, pKeyTable, pKey, pValue, pForce)
    end
end

function ClassImpl.Update2ChildrenMember(pCls, pKey, pValue)
    for _, child in ipairs(ClassesChild[pCls] or EmptyList) do
        local own = ClassesOwn[child]
        if nil == own or not own[pKey] then
            local resolved = ClassImpl.ResolveMember(child, pKey)
            ClassImpl.EnsureList(ClassesMembers, child)[pKey] = resolved
            ClassImpl.Update2ChildrenMember(child, pKey, resolved)
        end
    end
end

function ClassImpl.InvalidateCache(pCls, pKey)
    local children = ClassesChild[pCls]
    if nil == children or 0 == #children then
        return
    end

    for _, child in ipairs(children) do
        local own = ClassesOwn[child]
        local ownBits = (own and own[pKey]) or 0

        local childReadable = ClassesReadable[child]

        if (ownBits & mReader) == 0 then
            ClassesVTable[child][pKey] = (ClassesMembers[child] or EmptyList)[pKey]

            if childReadable then
                childReadable[pKey] = nil
            end
        end

        if (ownBits & mWriter) == 0 and childReadable then
            ClassesWritable[child][pKey] = nil
        end

        ClassImpl.InvalidateCache(child, pKey)
    end
end

function ClassImpl.RouterGet(pCls, pRouter, pKey)

    local bit = BitMap[pKey]

    if bit then
        return pRouter
    else

        local gs = pRouter.decor & mGS
        if gs ~= 0 then
            local keyTable = (gs == mGet) and ClassesReadable or ClassesWritable
            local propTable = keyTable[pCls]
            local property = propTable and propTable[pKey]
            return property and property[1] or nil
        end

        local opt = pRouter.decor & mOpt
        if opt ~= 0 then
            local propTable = ClassesWritable[pCls]
            local property = propTable and propTable[pKey]
            return property and property[1] or nil
        end
    end

    return pRouter
end

function ClassImpl.RouterSet(pCls, pRouter, pKey, pValue)

    if BitMap[pKey] then
        return
    end

    local gs = pRouter.decor & mGS
    local opt = pRouter.decor & mOpt

    if gs ~= 0 or opt ~= 0 then

        local members = ClassesMembers[pCls] or EmptyList
        if nil ~= members[pKey] then
            members[pKey] = nil
            ClassImpl.Update2ChildrenMember(pCls, pKey, nil)
        end

        ClassesVTable[pCls][pKey] = nil
        ClassImpl.InvalidateCache(pCls, pKey)

        if gs ~= 0 then
            ClassImpl.EnsureClassProperty(pCls)
            local keyTable = (gs == mGet) and ClassesReadable or ClassesWritable
            keyTable[pCls][pKey] = { pValue }
            ClassImpl.MarkOwn(pCls, pKey, (gs == mGet) and mGet or mSet)
            ClassImpl.SwitchToFuncIndex(pCls)
        else
            ClassImpl.EnsureClassProperty(pCls)
            ClassesReadable[pCls][pKey] = { pValue }
            ClassesWritable[pCls][pKey] = { pValue }
            ClassImpl.MarkOwn(pCls, pKey, mOpt)
            ClassImpl.SwitchToFuncIndex(pCls)
        end
    else

        local readable = ClassesReadable[pCls]
        if readable then
            readable[pKey] = nil
            ClassesWritable[pCls][pKey] = nil
        end

        local vTable = ClassesVTable[pCls]
        
        local ownBit
        if "function" == type(pValue) then
            vTable[pKey] = pValue
            ownBit = mMethod
        else
            ClassImpl.EnsureList(ClassesMembers, pCls)[pKey] = pValue
            ClassImpl.Update2ChildrenMember(pCls, pKey, pValue)
            vTable[pKey] = pValue
            ownBit = mMember
        end
        
        ClassImpl.MarkOwn(pCls, pKey, ownBit)
        ClassImpl.InvalidateCache(pCls, pKey)
    end
end

local ClassCreateLayer = 0

function ClassImpl.ObjectInit(pObj, pCls, ...)

    local vTable = ClassesVTable[pCls]
    local init = vTable[ctor]
    if nil == init then
        init = ClassImpl.SearchBaseMethod(pCls, ctor) or false
        vTable[ctor] = init
    end
    
    if init then
        local temp = ClassCreateLayer

        ClassCreateLayer = 0
        if Config.SafeCreate then
            local ok, msg = pcall(init, pObj, ...)
            ClassCreateLayer = ClassCreateLayer + temp - 1
            if not ok then
                error(msg)
            end
        else
            init(pObj, ...)
            ClassCreateLayer = ClassCreateLayer + temp - 1
        end
    else
        ClassCreateLayer = ClassCreateLayer - 1
    end
end

function ClassImpl.CreateClassNew(pCls)

    local vTable = ClassesVTable[pCls]
    local metaFunc = ClassesMetaFunc[pCls]
    local safeCreate = Config.SafeCreate

    if nil == vTable[__new] then
        vTable[__new] = ClassImpl.SearchBaseMethod(pCls, __new) or false
    end

    local function slowNew(...)

        ClassCreateLayer = ClassCreateLayer + 1
        local obj
        if safeCreate then
            local ok, res = pcall(ClassImpl.CreateClassObject, pCls, ...)
            if not ok or not res then
                if res then
                    print("An error occurred when creating the object -", res)
                end
                ClassCreateLayer = ClassCreateLayer - 1
                if not ok then
                    error(res)
                end
                return nil
            end
            obj = res
        else
            obj = ClassImpl.CreateClassObject(pCls, ...)
            if not obj then
                ClassCreateLayer = ClassCreateLayer - 1
                return nil
            end
        end

        if ClassCreateLayer == 1 then
            local currentMeta = getmetatable(obj)
            if nil == currentMeta or rawget(currentMeta, __internal) then
                setmetatable(obj, metaFunc)
            end
            ClassImpl.ObjectInit(obj, pCls, ...)
        else
            ClassCreateLayer = ClassCreateLayer - 1
        end

        return obj
    end

    -- 有 __new：必须走慢路径，且此后固定为慢路径
    if vTable[__new] ~= false then
        return slowNew
    end

    -- 快路径：无 __new。省去 ClassCreateLayer 计数、__new 分支与多余元表检查
    return function(...)

        if vTable[__new] ~= false then
            return slowNew(...)
        end

        local obj = setmetatable({}, metaFunc)

        local init = vTable[ctor]
        if nil == init then
            init = ClassImpl.SearchBaseMethod(pCls, ctor) or false
            vTable[ctor] = init
        end

        if init then
            if safeCreate then
                local ok, msg = pcall(init, obj, ...)
                if not ok then
                    print("An error occurred when creating the object -", msg)
                    error(msg)
                end
            else
                init(obj, ...)
            end
        end

        return obj
    end
end

return ClassImpl
