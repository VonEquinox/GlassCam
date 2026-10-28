
uint64_t method.const.IslEImageServerFilter.GetPixelFormat___const(int64_t arg1)

{
    uint64_t uVar1;
    
    if (*(arg1 + 0x5e1) == '\0') {
        if (*(arg1 + 0x5e8) != NULL) {
    //WARNING: Could not recover jumptable at 0x00adacb7. Too many branches
    //WARNING: Treating indirect jump as call
            uVar1 = (**(**(arg1 + 0x5e8) + 0xc0))();
            return uVar1;
        }
        uVar1 = 0;
    }
    else {
        uVar1 = *(arg1 + 0x59c);
    }
    return uVar1;
}

