
uint64_t method.const.IslEImageServerFilter.GetPixelMaxValue___const(int64_t arg1)

{
    uint64_t uVar1;
    uint16_t uVar2;
    uint16_t uVar3;
    uint16_t uVar4;
    
    if (*(arg1 + 0x5e1) == '\0') {
        if (*(arg1 + 0x5e8) == NULL) {
            uVar2 = 0;
            uVar1 = 0;
            uVar3 = 0;
            uVar4 = 0;
        }
        else {
            uVar1 = (**(**(arg1 + 0x5e8) + 0xe0))();
            uVar2 = uVar1 >> 0x10;
            uVar3 = uVar1 >> 0x20;
            uVar4 = uVar1 >> 0x30;
        }
    }
    else {
        uVar1 = *(arg1 + 0x5a0);
        uVar2 = *(arg1 + 0x5a2);
        uVar3 = *(arg1 + 0x5a4);
        uVar4 = *(arg1 + 0x5a6);
    }
    return uVar1 & 0xffff | uVar2 << 0x10 | uVar3 << 0x20 | uVar4 << 0x30;
}

