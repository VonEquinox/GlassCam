
float8 method.const.IslZCnvPolyLine.ConvertInternal_double_const__unsigned_char__const
                 (double arg4,int64_t arg1,int64_t arg2,int64_t arg3)

{
    int64_t iVar1;
    int iVar2;
    uint64_t uVar3;
    int iVar4;
    int64_t iVar5;
    float8 *pfVar6;
    int iVar7;
    int iVar8;
    float8 fVar9;
    float8 fVar10;
    float8 fVar11;
    
    if (arg3 == '\0') {
        iVar7 = *(arg1 + 0x9c);
        pfVar6 = *(arg1 + 0xa0);
        fVar10 = *arg2;
        uVar3 = iVar7 - 1;
    }
    else {
        fVar10 = *arg2;
        pfVar6 = *(arg1 + 0xa0);
        if (fVar10 < *pfVar6) {
            return pfVar6[1];
        }
        iVar7 = *(arg1 + 0x9c);
        uVar3 = iVar7 - 1;
        if (pfVar6[uVar3 * 2] <= fVar10 && fVar10 != pfVar6[uVar3 * 2]) {
            return pfVar6[uVar3 * 2 + 1];
        }
    }
    iVar4 = (uVar3 >> 0x1f & 1) + uVar3 >> 1;
    iVar7 = iVar7 + -2;
    iVar8 = *(arg1 + 0x1a8);
    iVar2 = iVar8;
    if (iVar7 < iVar8) {
        iVar2 = iVar4;
    }
    if (iVar8 < 0) {
        iVar2 = iVar4;
    }
    iVar8 = 0;
    do {
        iVar5 = iVar2;
        iVar4 = iVar2;
        if (pfVar6[iVar5 * 2] <= fVar10) {
            if (iVar7 <= iVar2) goto code_r0x00804e47;
            iVar1 = iVar2 + 1;
            if (fVar10 < pfVar6[iVar1 * 2]) goto code_r0x00804e47;
            iVar8 = iVar2 + 1;
            if ((iVar7 <= iVar8) || (fVar10 < pfVar6[iVar2 * 2 + 4])) {
                iVar5 = iVar1;
                iVar4 = iVar8;
code_r0x00804e47:
                *(arg1 + 0x1a8) = iVar4;
                fVar9 = pfVar6[iVar5 * 2 + 1];
                fVar11 = pfVar6[(iVar4 + 1) * 2] - pfVar6[iVar5 * 2];
                if ((fVar11 != 0.0) || (NAN(fVar11))) {
                    fVar9 = fVar9 + ((pfVar6[(iVar4 + 1) * 2 + 1] - fVar9) * (fVar10 - pfVar6[iVar5 * 2])) / fVar11;
                }
                if (arg3 != '\0') {
                    fVar10 = *0xeba7c8;
                    if (fVar9 <= *0xeba7c8) {
                        fVar10 = fVar9;
                    }
                    fVar9 = ~-(fVar9 < 0.0) & fVar10;
                }
                return fVar9;
            }
            iVar2 = iVar2 + 2 + iVar7;
        }
        else {
            if (iVar2 <= iVar8) goto code_r0x00804e47;
            iVar7 = iVar2 + -1;
            iVar5 = iVar2 + -1;
            iVar4 = iVar7;
            if (pfVar6[(iVar2 + -1) * 2] <= fVar10) goto code_r0x00804e47;
            iVar2 = iVar7 + iVar8;
        }
        iVar2 = iVar2 / 2;
    } while( true );
}

