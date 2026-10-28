
int64_t method.const.IslEImageServerFilter.GetPixelWhiteValue___const
                  (ulong noname_0,double arg3,int64_t arg1,int64_t arg2)

{
    int64_t var_28h;
    ulong uStack_28;
    ulong uStack_20;
    
    *(arg1 + 0x10) = 0;
    *(arg1 + 8) = 0;
    *arg1 = 0;
    if ((*(arg2 + 0x3d8) != 0.0) || (NAN(*(arg2 + 0x3d8)))) {
        *(arg1 + 0x10) = *(arg2 + 1000);
        var_28h = *(arg2 + 0x3d8);
        uStack_28 = *(arg2 + 0x3e0);
    }
    else {
        if (*(arg2 + 0x5e8) == NULL) {
            return arg1;
        }
        (**(**(arg2 + 0x5e8) + 0xe8))(&var_28h);
        *(arg1 + 0x10) = uStack_20;
    }
    *(arg1 + 8) = uStack_28;
    *arg1 = var_28h;
    return arg1;
}

