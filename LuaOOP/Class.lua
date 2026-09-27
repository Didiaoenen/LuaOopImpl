local ClassImpl = require("LuaOOP.ClassImpl")

class = setmetatable({}, {
    __call = function(pCls, ...)
        return pCls.New(...)
    end
})

class.New = function(pName, ...)
    
    local cls = ClassImpl.CreateClass(pName)
    
    ClassImpl.CreateClassTables(cls)

    ClassImpl.MakeInternalObjectMeta(cls)

    ClassImpl.CreateClassInherit(cls, {...})

    local as = ClassImpl.CreateClassAs(cls)
    local new = ClassImpl.CreateClassNew(cls)
    local delete = ClassImpl.CreateClassDelete(cls)
    ClassImpl.AttachClassFunctions(cls, as, new, delete)

    return cls
end
