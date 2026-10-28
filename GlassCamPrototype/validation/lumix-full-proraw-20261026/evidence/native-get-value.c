
void method.const.IslVEISFilter3DLUT::Pana_LUT.GetValue__ISLZPIXEL48_const___ISLZPIXEL48__const
               (ulong noname_0,ulong noname_1,double arg4,ulong noname_3,double arg5,ulong noname_5,double arg6,
               int64_t arg1,int64_t arg2,int64_t arg3)

{
    int64_t iVar1;
    ushort uVar2;
    int iVar3;
    int iVar4;
    int iVar5;
    int iVar6;
    int64_t iVar7;
    int iVar8;
    int64_t iVar9;
    int64_t iVar10;
    int64_t iVar11;
    int64_t iVar12;
    int iVar13;
    int64_t iVar14;
    int64_t iVar15;
    int64_t iVar16;
    float8 fVar17;
    float8 fVar18;
    float8 fVar19;
    float8 fVar20;
    float8 fVar21;
    float8 fVar22;
    float8 fVar23;
    float8 fVar24;
    float8 fVar25;
    float8 fVar26;
    int64_t var_90h;
    int64_t var_88h;
    int64_t var_80h;
    int64_t var_78h;
    int64_t var_70h;
    int64_t var_68h;
    int64_t var_60h;
    int64_t var_58h;
    int64_t var_50h;
    int64_t var_48h;
    int64_t var_40h;
    int64_t var_38h;
    int64_t var_30h;
    
    iVar6 = *(arg1 + 0x14c);
    iVar13 = *(arg1 + 0x148);
    iVar3 = *arg2 / iVar13;
    iVar8 = iVar6 + -2;
    if (iVar8 <= iVar3) {
        iVar3 = iVar8;
    }
    iVar4 = *(arg2 + 2) / iVar13;
    if (iVar8 <= iVar4) {
        iVar4 = iVar8;
    }
    iVar5 = *(arg2 + 4) / iVar13;
    if (iVar8 <= iVar5) {
        iVar5 = iVar8;
    }
    fVar17 = iVar13;
    fVar22 = (*arg2 % iVar13) / fVar17;
    fVar20 = (*(arg2 + 2) % iVar13) / fVar17;
    fVar17 = (*(arg2 + 4) % iVar13) / fVar17;
    fVar18 = fVar22 * fVar20 * fVar17;
    iVar1 = *(arg1 + 8);
    iVar13 = (iVar5 + 1) * iVar6;
    iVar8 = (iVar13 + 1 + iVar4) * iVar6;
    iVar15 = iVar8 + 1 + iVar3;
    fVar23 = fVar22 * (*0xeba7c8 - fVar20);
    fVar26 = (*0xeba7c8 - fVar20) * (*0xeba7c8 - fVar22);
    fVar21 = (*0xeba7c8 - fVar22) * fVar20;
    fVar24 = fVar21 * fVar17;
    iVar9 = iVar8 + iVar3;
    iVar13 = (iVar13 + iVar4) * iVar6;
    iVar10 = iVar13 + 1 + iVar3;
    fVar25 = fVar17 * fVar23;
    fVar19 = *0xeba7c8 - fVar17;
    fVar20 = fVar22 * fVar20 * fVar19;
    iVar8 = (iVar5 * iVar6 + 1 + iVar4) * iVar6;
    iVar16 = iVar8 + 1 + iVar3;
    fVar17 = fVar17 * fVar26;
    iVar14 = iVar13 + iVar3;
    fVar21 = fVar21 * fVar19;
    iVar11 = iVar8 + iVar3;
    fVar23 = fVar23 * fVar19;
    iVar6 = (iVar5 * iVar6 + iVar4) * iVar6;
    iVar12 = iVar6 + 1 + iVar3;
    fVar26 = fVar26 * fVar19;
    iVar7 = iVar6 + iVar3;
    fVar19 = sym.imp.floor(*(iVar1 + 4 + iVar7 * 6) * fVar26 +
                           *(iVar1 + 4 + iVar12 * 6) * fVar23 +
                           *(iVar1 + 4 + iVar11 * 6) * fVar21 +
                           *(iVar1 + 4 + iVar14 * 6) * fVar17 +
                           *(iVar1 + 4 + iVar16 * 6) * fVar20 +
                           *(iVar1 + 4 + iVar10 * 6) * fVar25 +
                           *(iVar1 + 4 + iVar9 * 6) * fVar24 + *(iVar1 + 4 + iVar15 * 6) * fVar18 + *0xeba7e0);
    if (0.0 <= fVar19) {
        uVar2 = 0xffff;
        if (fVar19 <= *0xeba7b8) {
            uVar2 = fVar19;
        }
    }
    else {
        uVar2 = 0;
    }
    *arg3 = uVar2;
    fVar19 = sym.imp.floor(*(iVar1 + 2 + iVar7 * 6) * fVar26 +
                           *(iVar1 + 2 + iVar12 * 6) * fVar23 +
                           *(iVar1 + 2 + iVar11 * 6) * fVar21 +
                           *(iVar1 + 2 + iVar14 * 6) * fVar17 +
                           *(iVar1 + 2 + iVar16 * 6) * fVar20 +
                           *(iVar1 + 2 + iVar10 * 6) * fVar25 +
                           *(iVar1 + 2 + iVar9 * 6) * fVar24 + *(iVar1 + 2 + iVar15 * 6) * fVar18 + *0xeba7e0);
    if (0.0 <= fVar19) {
        uVar2 = 0xffff;
        if (fVar19 <= *0xeba7b8) {
            uVar2 = fVar19;
        }
    }
    else {
        uVar2 = 0;
    }
    *(arg3 + 2) = uVar2;
    fVar17 = sym.imp.floor(fVar26 * *(iVar1 + iVar7 * 6) +
                           fVar23 * *(iVar1 + iVar12 * 6) +
                           fVar21 * *(iVar1 + iVar11 * 6) +
                           fVar17 * *(iVar1 + iVar14 * 6) +
                           fVar20 * *(iVar1 + iVar16 * 6) +
                           fVar25 * *(iVar1 + iVar10 * 6) +
                           fVar24 * *(iVar1 + iVar9 * 6) + fVar18 * *(iVar1 + iVar15 * 6) + *0xeba7e0);
    if (0.0 <= fVar17) {
        uVar2 = 0xffff;
        if (fVar17 <= *0xeba7b8) {
            uVar2 = fVar17;
        }
    }
    else {
        uVar2 = 0;
    }
    *(arg3 + 4) = uVar2;
    return;
}

