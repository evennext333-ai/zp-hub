-- 不启用 VM 和反调试，保留异步任务及执行器兼容性。
return {
    LuaVersion = "LuaU",
    NameGenerator = "MangledShuffled",
    PrettyPrint = false,
    Seed = 20261121,
    Steps = {
        { Name = "EncryptStrings", Settings = {} },
        { Name = "ConstantArray", Settings = { Threshold = 1, StringsOnly = true, Shuffle = true, Rotate = true } },
        { Name = "WrapInFunction", Settings = {} },
    },
}
