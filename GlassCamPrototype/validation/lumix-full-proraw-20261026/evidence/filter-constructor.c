
void class.IslVEISFilter3DLUT(int64_t arg1)

{
    int64_t var_30h;
    
    class.IslEISFilterNxNBase();
    *arg1 = 0x130bb08;
    *(arg1 + 0x15f0) = 0x130be30;
    method.constructor.IslVEISFilter3DLUT::Pana_LUT.Pana_LUT__(arg1 + 0x2fa0);
    method.constructor.IslVEISFilter3DLUT::Pana_LUT.Pana_LUT__(arg1 + 0x30f8);
    *(arg1 + 0x328e) = 0;
    *(arg1 + 0x3288) = 0;
    *(arg1 + 0x3280) = 0;
    *(arg1 + 0x3278) = 0;
    *(arg1 + 0x3270) = 0;
    *(arg1 + 0x3268) = 0;
    *(arg1 + 0x3260) = 0;
    *(arg1 + 0x3258) = 0;
    *(arg1 + 0x3250) = 0;
    *(arg1 + 0x3298) = 0;
    *(arg1 + 0x329a) = 0;
    method.constructor.IslZCnvPolyLine.IslZCnvPolyLine__(arg1 + 0x32a0);
    sym.imp.__bzero(arg1 + 0x3520,0xc4);
    method.constructor.IslZCnvPolyLine.IslZCnvPolyLine__(arg1 + 0x35e8);
    *(arg1 + 0x3880) = 0;
    *(arg1 + 0x38a0) = 0;
    *(arg1 + 0x38d8) = 0;
    *(arg1 + 0x38a8) = 0;
    *(arg1 + 0x38b0) = 0;
    *(arg1 + 0x38b8) = 0;
    *(arg1 + 0x38c0) = 0;
    *(arg1 + 0x38c4) = 0;
    *(arg1 + 0x3898) = "(NEW)";
    *(arg1 + 0x3888) = 0;
    *(arg1 + 0x3890) = 0x876543200000000;
    if (sym.__ZN14IslZSemaphoreX7m_bInitE_1 == 0x0) {
        method.IslZSemaphoreX.Init__();
    }
    *(arg1 + 0x38c8) = _sym.__ZN14IslZSemaphoreX23m_nSpinLoopCountDefaultE;
    *(arg1 + 0x38cc) = _sym.__ZN14IslZSemaphoreX23m_nZeroLoopCountDefaultE;
    *(arg1 + 0x38d0) = _sym.__ZN14IslZSemaphoreX9m_MainTIDE_1;
    *(arg1 + 0x38e0) = arg1 + 0x3880;
    *(arg1 + 0x38e8) = arg1 + 0x3880;
    *(arg1 + 0x38f0) = 0;
    *(arg1 + 0x38f8) = 0;
    *(arg1 + 0x3296) = 0x80;
    *(arg1 + 0x3870) = 0;
    *(arg1 + 0x3878) = 0;
    return;
}

