
int method.IslVEISFilter3DLUT.MakeUpCnvPreLUT_IslZCnvPolyLine__IslVEISFilter3DLUT::LowISOCorrectLUT_const__double__double_
              (float8 noname_0,int64_t arg1,int64_t arg2)

{
    int16_t iVar1;
    int64_t iVar2;
    float8 in_XMM1_Qa;
    uchar auStack_360 [8];
    float8 fStack_358;
    float8 fStack_350;
    int64_t var_320h;
    int64_t var_318h;
    int64_t var_8h;
    
    var_8h = *_reloc.__stack_chk_guard;
    iVar2 = 0;
    do {
        (&var_320h)[iVar2] = *(arg2 + iVar2) * noname_0;
        (&var_318h)[iVar2] = *(arg2 + 0x62 + iVar2) * in_XMM1_Qa;
        iVar2 = iVar2 + 2;
    } while (iVar2 != 0x62);
    (**(*arg1 + 0x20))(arg1,&var_320h,0x31,0);
    if (*_reloc.__stack_chk_guard == var_8h) {
        return 0;
    }
    sym.imp.__stack_chk_fail();
    iVar1 = sym.IslEISFilterNxNBase.__ZN19IslEISFilterNxNBase18OpenSequentialReadEPK9_ISLZRECTP12IslZProgress();
    if (iVar1 == 0) {
        sym.IslEImageServerFilter.__ZNK21IslEImageServerFilter18GetPixelWhiteValueEv(auStack_360,arg1);
        iVar1 = sym.IslVEISFilter3DLUT.__ZN18IslVEISFilter3DLUT9MakeUpCnvEP15IslZCnvPolyLineRKNS_11LUTContrastEdd
                          (*0xed87a8 * fStack_350,fStack_350 * *0xf82d70,arg1 + 0x32a0,arg1 + 0x3250);
        if (iVar1 == 0) {
            if ((*(arg1 + 0x3580) == -1) && (*(arg1 + 0x35e2) == -1)) {
                sym.IslEImageServerFilter.__ZNK21IslEImageServerFilter17GetPixelDefWValueEv(auStack_360,arg1);
                method.IslVEISFilter3DLUT.MakeUpCnvPreLUT_IslZCnvPolyLine__IslVEISFilter3DLUT::LowISOCorrectLUT_const__double__double_
                          (fStack_358 / *0xeba7b8,arg1 + 0x35e8,arg1 + 0x3520);
            }
            iVar1 = 0;
        }
        else {
            sym.IslEISFilterNxNBase.__ZN19IslEISFilterNxNBase19CloseSequentialReadEv(arg1);
        }
    }
    return iVar1;
}

