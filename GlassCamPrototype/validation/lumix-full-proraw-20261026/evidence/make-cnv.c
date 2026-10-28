
int method.IslVEISFilter3DLUT.MakeUpCnv_IslZCnvPolyLine__IslVEISFilter3DLUT::LUTContrast_const__double__double_
              (float8 noname_0,float8 noname_1,double arg3,int64_t arg1,int64_t arg2)

{
    int64_t iVar1;
    uchar auVar2 [16];
    uchar auVar3 [16];
    uint16_t uVar4;
    int16_t iVar5;
    uint32_t uVar6;
    uint64_t uVar7;
    uint64_t uVar8;
    int64_t iVar9;
    float8 fVar10;
    float8 fVar11;
    float8 fVar12;
    int64_t var_1e0h;
    float8 fStack_1e0;
    int64_t var_1d0h;
    float8 afStack_1d0 [56];
    int64_t var_8h;
    
    var_8h = *_reloc.__stack_chk_guard;
    fVar10 = 0.0;
    fVar11 = 0.0;
    var_1e0h = 0;
    fStack_1e0 = 0.0;
    iVar9 = 0;
    uVar8 = 0;
    do {
        uVar4 = *(arg2 + (uVar8 >> 1 & 0x7ffffffe)) >> (iVar9 & 0xc);
        if ((uVar4 & 0xf) == 0) {
            uVar6 = uVar8;
            if (0x1c < uVar6) goto code_r0x0082d6af;
            uVar7 = uVar8 & 0xffffffff;
            goto code_r0x0082d67d;
        }
        iVar1 = uVar8 * 2;
        uVar8 = uVar8 + 1;
        fVar10 = fVar10 + (1 << (uVar4 & 0xf));
        fVar11 = fVar11 + *(arg2 + 0xe + iVar1);
        *(afStack_1d0 + iVar9 * 4 + -8) = fVar10;
        *(afStack_1d0 + iVar9 * 4) = fVar11;
        iVar9 = iVar9 + 4;
    } while (uVar8 != 0x1c);
    uVar7 = 0x1c;
    uVar8 = 0x1c;
code_r0x0082d67d:
    uVar6 = uVar7;
    iVar9 = uVar8 << 4;
    do {
        fVar10 = (&fStack_1e0)[uVar7 * 2];
        *(&var_1e0h + iVar9) = (&var_1e0h)[uVar7 * 2];
        *(&fStack_1e0 + iVar9) = fVar10;
        iVar9 = iVar9 + 0x10;
    } while (iVar9 != 0x1d0);
code_r0x0082d6af:
    iVar9 = 0x10;
    do {
        fVar10 = *(afStack_1d0 + iVar9 + -8);
        fVar11 = *(&fStack_1e0 + iVar9) * noname_1;
        fVar12 = *(afStack_1d0 + iVar9) * noname_1;
        auVar3._8_4_ = SUB84(fVar11,0);
        auVar3._0_8_ = *(&var_1e0h + iVar9) * noname_0;
        auVar3._12_4_ = fVar11 >> 0x20;
        *(&var_1e0h + iVar9) = auVar3;
        auVar2._8_4_ = SUB84(fVar12,0);
        auVar2._0_8_ = fVar10 * noname_0;
        auVar2._12_4_ = fVar12 >> 0x20;
        *(afStack_1d0 + iVar9 + -8) = auVar2;
        iVar9 = iVar9 + 0x20;
    } while (iVar9 != 0x1d0);
    iVar5 = (**(*arg1 + 0x20))(arg1,&var_1e0h,uVar6 + 1,0);
    if (*_reloc.__stack_chk_guard != var_8h) {
    //WARNING: Subroutine does not return
        sym.imp.__stack_chk_fail();
    }
    return iVar5;
}

