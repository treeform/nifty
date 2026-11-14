// Derived from snappy_straight.c (Supersnappy MIT; see lib/SNAPPY_LICENSE).
// Manual changes and frozen compiler baseline: snappy_manifest.json.
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 11, 0	sdk_version 15, 1
	.globl	_snappyCompress                 ; -- Begin function snappyCompress
	.p2align	2
_snappyCompress:                        ; @snappyCompress
	.cfi_startproc
; %bb.0:
	stp	x28, x27, [sp, #-96]!           ; 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	add	x29, sp, #80
	mov	w9, #32896                      ; =0x8080
Lloh0:
	adrp	x16, ___chkstk_darwin@GOTPAGE
Lloh1:
	ldr	x16, [x16, ___chkstk_darwin@GOTPAGEOFF]
	blr	x16
	sub	sp, sp, #8, lsl #12             ; =32768
	sub	sp, sp, #128
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
Lloh2:
	adrp	x8, ___stack_chk_guard@GOTPAGE
Lloh3:
	ldr	x8, [x8, ___stack_chk_guard@GOTPAGEOFF]
Lloh4:
	ldr	x8, [x8]
	stur	x8, [x29, #-96]
	str	xzr, [x2, #8]
	lsr	x8, x1, #32
	cbz	x8, LBB0_2
; %bb.1:
	mov	w0, #3                          ; =0x3
	b	LBB0_76
LBB0_2:
	mov	x19, x2
	mov	x20, x1
	mov	x24, x0
	mov	w8, #43691                      ; =0xaaab
	movk	w8, #43690, lsl #16
	and	x9, x1, #0xffffffff
	umull	x8, w9, w8
	add	x8, x1, x8, lsr #34
	add	x23, x8, #32
	ldr	x8, [x2, #16]
	ldr	x22, [x2]
	cmp	x8, x23
	b.hs	LBB0_5
; %bb.3:
	mov	x0, x22
	mov	x1, x23
	bl	_realloc
	cbz	x0, LBB0_78
; %bb.4:
	mov	x22, x0
	str	x0, [x19]
	str	x23, [x19, #16]
LBB0_5:
	cmp	x20, #128
	b.lo	LBB0_8
; %bb.6:
	mov	x8, x20
LBB0_7:                                 ; =>This Inner Loop Header: Depth=1
	orr	w9, w8, #0x80
	strb	w9, [x22], #1
	lsr	x9, x8, #7
	lsr	x10, x8, #14
	mov	x8, x9
	cbnz	x10, LBB0_7
	b	LBB0_9
LBB0_8:
	mov	x9, x20
LBB0_9:
	str	x19, [sp, #8]                   ; 8-byte Folded Spill
	strb	w9, [x22], #1
	cbz	x20, LBB0_75
; %bb.10:
	mov	x23, #0                         ; =0x0
	mov	w25, #42941                     ; =0xa7bd
	movk	w25, #7733, lsl #16
	add	x28, sp, #112
	mov	w19, #254                       ; =0xfe
	movi.16b	v2, #254
	stp	x24, x20, [sp, #40]             ; 16-byte Folded Spill
	b	LBB0_13
LBB0_11:                                ;   in Loop: Header=BB0_13 Depth=1
	ldr	x20, [sp, #48]                  ; 8-byte Folded Reload
LBB0_12:                                ;   in Loop: Header=BB0_13 Depth=1
	ldr	x23, [sp, #56]                  ; 8-byte Folded Reload
	add	x23, x27, x23
	cmp	x23, x20
	b.hs	LBB0_75
LBB0_13:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_15 Depth 2
                                        ;     Child Loop BB0_20 Depth 2
                                        ;       Child Loop BB0_21 Depth 3
                                        ;       Child Loop BB0_28 Depth 3
                                        ;       Child Loop BB0_33 Depth 3
                                        ;         Child Loop BB0_35 Depth 4
                                        ;         Child Loop BB0_40 Depth 4
                                        ;         Child Loop BB0_50 Depth 4
                                        ;         Child Loop BB0_53 Depth 4
                                        ;     Child Loop BB0_70 Depth 2
	sub	x8, x20, x23
	cmp	x8, #16, lsl #12                ; =65536
	mov	w9, #65536                      ; =0x10000
	csel	x27, x8, x9, lo
	cmp	x8, #4, lsl #12                 ; =16384
	mov	w9, #16384                      ; =0x4000
	csel	x8, x8, x9, lo
	cmp	x8, #257
	add	x9, sp, #64
	st1.2d	{ v2, v3, v4 }, [x9]            ; 48-byte Folded Spill
	mov	w26, #24                        ; =0x18
	b.lo	LBB0_17
; %bb.14:                               ;   in Loop: Header=BB0_13 Depth=1
	mov	w9, #256                        ; =0x100
LBB0_15:                                ;   Parent Loop BB0_13 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov	x10, x9
	lsl	x9, x9, #1
	sub	w26, w26, #1
	cmp	x9, x8
	b.lo	LBB0_15
; %bb.16:                               ;   in Loop: Header=BB0_13 Depth=1
	lsl	x2, x10, #2
	b	LBB0_18
LBB0_17:                                ;   in Loop: Header=BB0_13 Depth=1
	mov	w2, #512                        ; =0x200
LBB0_18:                                ;   in Loop: Header=BB0_13 Depth=1
	add	x21, x24, x23
	add	x0, sp, #112
	mov	w1, #0                          ; =0x0
	mov	w3, #32768                      ; =0x8000
	bl	___memset_chk
	subs	x20, x27, #15
	str	x23, [sp, #56]                  ; 8-byte Folded Spill
	mov	x8, #0                          ; =0x0
	b.lo	LBB0_63
; %bb.19:                               ;   in Loop: Header=BB0_13 Depth=1
	add	x4, x21, #4
	add	x3, x24, x23
	mov	x10, x21
	mov	w9, #1                          ; =0x1
	add	x11, sp, #64
	ld1.2d	{ v2, v3, v4 }, [x11]           ; 48-byte Folded Reload
LBB0_20:                                ;   Parent Loop BB0_13 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB0_21 Depth 3
                                        ;       Child Loop BB0_28 Depth 3
                                        ;       Child Loop BB0_33 Depth 3
                                        ;         Child Loop BB0_35 Depth 4
                                        ;         Child Loop BB0_40 Depth 4
                                        ;         Child Loop BB0_50 Depth 4
                                        ;         Child Loop BB0_53 Depth 4
	ldur	w10, [x10, #1]
	mov	w11, #32                        ; =0x20
LBB0_21:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	mov	x23, x9
	add	x9, x9, x11, lsr #5
	cmp	x9, x20
	b.hi	LBB0_65
; %bb.22:                               ;   in Loop: Header=BB0_21 Depth=3
	mul	w12, w10, w25
	ldr	w10, [x21, x9]
	lsr	w12, w12, w26
	ldrh	w24, [x28, w12, uxtw #1]
	strh	w23, [x28, w12, uxtw #1]
	add	x11, x11, #1
	ldr	w12, [x21, x23]
	ldr	w13, [x21, x24]
	cmp	w12, w13
	b.ne	LBB0_21
; %bb.23:                               ;   in Loop: Header=BB0_20 Depth=2
	add	x1, x21, x8
	sub	x2, x23, x8
	sub	x9, x2, #1
	cmp	x9, #59
	b.hi	LBB0_27
; %bb.24:                               ;   in Loop: Header=BB0_20 Depth=2
	sub	x8, x27, x8
	lsl	w9, w9, #2
	strb	w9, [x22], #1
	cmp	x8, #16
	b.lo	LBB0_30
; %bb.25:                               ;   in Loop: Header=BB0_20 Depth=2
	cmp	x2, #16
	b.hi	LBB0_30
; %bb.26:                               ;   in Loop: Header=BB0_20 Depth=2
	ldr	q0, [x1]
	str	q0, [x22]
	b	LBB0_32
LBB0_27:                                ;   in Loop: Header=BB0_20 Depth=2
	stp	x3, x4, [sp, #24]               ; 16-byte Folded Spill
	mov	w8, #1                          ; =0x1
LBB0_28:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	strb	w9, [x22, x8]
	lsr	x10, x9, #8
	add	x8, x8, #1
	cmp	x9, #255
	mov	x9, x10
	b.hi	LBB0_28
; %bb.29:                               ;   in Loop: Header=BB0_20 Depth=2
	str	x27, [sp, #16]                  ; 8-byte Folded Spill
	add	x9, sp, #64
	st1.2d	{ v2, v3, v4 }, [x9]            ; 48-byte Folded Spill
	lsl	w9, w8, #2
	sub	w9, w9, #24
	strb	w9, [x22]
	add	x22, x22, x8
	b	LBB0_31
LBB0_30:                                ;   in Loop: Header=BB0_20 Depth=2
	stp	x27, x3, [sp, #16]              ; 16-byte Folded Spill
	str	x4, [sp, #32]                   ; 8-byte Folded Spill
	add	x8, sp, #64
	st1.2d	{ v2, v3, v4 }, [x8]            ; 48-byte Folded Spill
LBB0_31:                                ;   in Loop: Header=BB0_20 Depth=2
	mov	x0, x22
	mov	x27, x2
	bl	_memcpy
	mov	x2, x27
	add	x8, sp, #64
	ld1.2d	{ v2, v3, v4 }, [x8]            ; 48-byte Folded Reload
	ldp	x3, x4, [sp, #24]               ; 16-byte Folded Reload
	ldr	x27, [sp, #16]                  ; 8-byte Folded Reload
LBB0_32:                                ;   in Loop: Header=BB0_20 Depth=2
	add	x22, x22, x2
LBB0_33:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ; =>    This Loop Header: Depth=3
                                        ;         Child Loop BB0_35 Depth 4
                                        ;         Child Loop BB0_40 Depth 4
                                        ;         Child Loop BB0_50 Depth 4
                                        ;         Child Loop BB0_53 Depth 4
	sub	x9, x27, x23
	sub	x8, x9, #4
	cmp	x8, #8
	b.lo	LBB0_38
; %bb.34:                               ;   in Loop: Header=BB0_33 Depth=3
	mov	x10, #0                         ; =0x0
	add	x12, x4, x24
	add	x13, x4, x23
	and	x11, x8, #0xfffffffffffffff8
LBB0_35:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ;       Parent Loop BB0_33 Depth=3
                                        ; =>      This Inner Loop Header: Depth=4
	ldr	x15, [x12, x10]
	ldr	x16, [x13, x10]
	cmp	x15, x16
	b.ne	LBB0_43
; %bb.36:                               ;   in Loop: Header=BB0_35 Depth=4
	add	x10, x10, #8
	cmp	x10, x11
	b.lo	LBB0_35
; %bb.37:                               ;   in Loop: Header=BB0_33 Depth=3
	cmp	x11, x8
	b.lo	LBB0_39
	b	LBB0_45
LBB0_38:                                ;   in Loop: Header=BB0_33 Depth=3
	mov	x11, #0                         ; =0x0
	cmp	x11, x8
	b.hs	LBB0_45
LBB0_39:                                ;   in Loop: Header=BB0_33 Depth=3
	add	x10, x11, #4
	add	x11, x3, x23
	add	x12, x3, x24
LBB0_40:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ;       Parent Loop BB0_33 Depth=3
                                        ; =>      This Inner Loop Header: Depth=4
	ldrb	w13, [x12, x10]
	ldrb	w14, [x11, x10]
	cmp	w13, w14
	b.ne	LBB0_44
; %bb.41:                               ;   in Loop: Header=BB0_40 Depth=4
	add	x10, x10, #1
	cmp	x9, x10
	b.ne	LBB0_40
; %bb.42:                               ;   in Loop: Header=BB0_33 Depth=3
	mov	x11, x8
	b	LBB0_45
LBB0_43:                                ;   in Loop: Header=BB0_33 Depth=3
	eor	x8, x16, x15
	rbit	x8, x8
	clz	x8, x8
	add	x11, x10, x8, lsr #3
	b	LBB0_45
LBB0_44:                                ;   in Loop: Header=BB0_33 Depth=3
	sub	x11, x10, #4
LBB0_45:                                ;   in Loop: Header=BB0_33 Depth=3
	add	x8, x11, #4
	sub	x9, x23, x24
	lsr	x10, x9, #8
	cmp	x8, #68
	b.lo	LBB0_48
; %bb.46:                               ;   in Loop: Header=BB0_33 Depth=3
	sub	x11, x11, #64
	cmp	x11, #4032
	b.hs	LBB0_49
; %bb.47:                               ;   in Loop: Header=BB0_33 Depth=3
	mov	x12, x8
	mov	x11, x22
	b	LBB0_52
LBB0_48:                                ;   in Loop: Header=BB0_33 Depth=3
	mov	x11, x22
	mov	x12, x8
	b	LBB0_54
LBB0_49:                                ;   in Loop: Header=BB0_33 Depth=3
	lsr	x11, x11, #6
	add	x13, x11, #1
	and	x14, x13, #0x7ffffffffffffc0
	sub	x12, x8, x14, lsl #6
	add	x11, x14, x14, lsl #1
	add	x11, x22, x11
	dup.16b	v0, w9
	dup.16b	v1, w10
	add	x16, x22, #96
	mov	x15, x14
	mov.16b	v3, v0
	mov.16b	v4, v1
LBB0_50:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ;       Parent Loop BB0_33 Depth=3
                                        ; =>      This Inner Loop Header: Depth=4
	sub	x17, x16, #96
	sub	x0, x16, #48
	st3.16b	{ v2, v3, v4 }, [x17]
	st3.16b	{ v2, v3, v4 }, [x0]
	add	x17, x16, #192
	st3.16b	{ v2, v3, v4 }, [x16], #48
	st3.16b	{ v2, v3, v4 }, [x16]
	mov	x16, x17
	subs	x15, x15, #64
	b.ne	LBB0_50
; %bb.51:                               ;   in Loop: Header=BB0_33 Depth=3
	cmp	x13, x14
	b.eq	LBB0_54
LBB0_52:                                ;   in Loop: Header=BB0_33 Depth=3
	mov	x13, x11
LBB0_53:                                ;   Parent Loop BB0_13 Depth=1
                                        ;     Parent Loop BB0_20 Depth=2
                                        ;       Parent Loop BB0_33 Depth=3
                                        ; =>      This Inner Loop Header: Depth=4
	add	x11, x13, #3
	strb	w10, [x13, #2]
	strb	w19, [x13]
	strb	w9, [x13, #1]
	sub	x12, x12, #64
	mov	x13, x11
	cmp	x12, #67
	b.hi	LBB0_53
LBB0_54:                                ;   in Loop: Header=BB0_33 Depth=3
	cmp	x12, #65
	b.lo	LBB0_56
; %bb.55:                               ;   in Loop: Header=BB0_33 Depth=3
	strb	w10, [x11, #2]
	mov	w13, #238                       ; =0xee
	strb	w13, [x11]
	strb	w9, [x11, #1]
	add	x11, x11, #3
	sub	x12, x12, #60
LBB0_56:                                ;   in Loop: Header=BB0_33 Depth=3
	cmp	x9, #2047
	b.hi	LBB0_59
; %bb.57:                               ;   in Loop: Header=BB0_33 Depth=3
	cmp	x12, #11
	b.hi	LBB0_59
; %bb.58:                               ;   in Loop: Header=BB0_33 Depth=3
	ubfx	x10, x9, #3, #29
	and	w10, w10, #0xe0
	add	w10, w10, w12, lsl #2
	add	w12, w10, #241
	add	x22, x11, #2
	b	LBB0_60
LBB0_59:                                ;   in Loop: Header=BB0_33 Depth=3
	lsl	w12, w12, #2
	sub	w12, w12, #2
	add	x22, x11, #3
	strb	w10, [x11, #2]
LBB0_60:                                ;   in Loop: Header=BB0_33 Depth=3
	strb	w12, [x11]
	strb	w9, [x11, #1]
	add	x23, x8, x23
	cmp	x23, x20
	b.hs	LBB0_64
; %bb.61:                               ;   in Loop: Header=BB0_33 Depth=3
	add	x10, x21, x23
	ldur	w8, [x10, #-1]
	mul	w8, w8, w25
	lsr	w8, w8, w26
	ldr	w9, [x10]
	mul	w11, w9, w25
	lsr	w11, w11, w26
	sub	w12, w23, #1
	strh	w12, [x28, w8, uxtw #1]
	ldrh	w24, [x28, w11, uxtw #1]
	strh	w23, [x28, w11, uxtw #1]
	ldr	w8, [x21, x24]
	cmp	w9, w8
	b.eq	LBB0_33
; %bb.62:                               ;   in Loop: Header=BB0_20 Depth=2
	add	x9, x23, #1
	mov	x8, x23
	b	LBB0_20
LBB0_63:                                ;   in Loop: Header=BB0_13 Depth=1
	add	x9, sp, #64
	ld1.2d	{ v2, v3, v4 }, [x9]            ; 48-byte Folded Reload
	subs	x23, x27, x8
	b.ls	LBB0_11
	b	LBB0_66
LBB0_64:                                ;   in Loop: Header=BB0_13 Depth=1
	mov	x8, x23
LBB0_65:                                ;   in Loop: Header=BB0_13 Depth=1
	ldr	x24, [sp, #40]                  ; 8-byte Folded Reload
	subs	x23, x27, x8
	b.ls	LBB0_11
LBB0_66:                                ;   in Loop: Header=BB0_13 Depth=1
	add	x1, x21, x8
	sub	x8, x23, #1
	cmp	x8, #59
	b.hi	LBB0_69
; %bb.67:                               ;   in Loop: Header=BB0_13 Depth=1
	lsl	w8, w8, #2
	strb	w8, [x22], #1
	cmp	x23, #16
	b.ne	LBB0_72
; %bb.68:                               ;   in Loop: Header=BB0_13 Depth=1
	ldr	q0, [x1]
	str	q0, [x22]
	ldr	x20, [sp, #48]                  ; 8-byte Folded Reload
	b	LBB0_74
LBB0_69:                                ;   in Loop: Header=BB0_13 Depth=1
	mov	w9, #1                          ; =0x1
LBB0_70:                                ;   Parent Loop BB0_13 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	strb	w8, [x22, x9]
	lsr	x10, x8, #8
	add	x9, x9, #1
	cmp	x8, #255
	mov	x8, x10
	b.hi	LBB0_70
; %bb.71:                               ;   in Loop: Header=BB0_13 Depth=1
	add	x8, sp, #64
	st1.2d	{ v2, v3, v4 }, [x8]            ; 48-byte Folded Spill
	lsl	w8, w9, #2
	sub	w8, w8, #24
	strb	w8, [x22]
	add	x22, x22, x9
	b	LBB0_73
LBB0_72:                                ;   in Loop: Header=BB0_13 Depth=1
	add	x8, sp, #64
	st1.2d	{ v2, v3, v4 }, [x8]            ; 48-byte Folded Spill
LBB0_73:                                ;   in Loop: Header=BB0_13 Depth=1
	ldr	x20, [sp, #48]                  ; 8-byte Folded Reload
	mov	x0, x22
	mov	x2, x23
	bl	_memcpy
	add	x8, sp, #64
	ld1.2d	{ v2, v3, v4 }, [x8]            ; 48-byte Folded Reload
LBB0_74:                                ;   in Loop: Header=BB0_13 Depth=1
	add	x22, x22, x23
	b	LBB0_12
LBB0_75:
	mov	w0, #0                          ; =0x0
	ldr	x9, [sp, #8]                    ; 8-byte Folded Reload
	ldr	x8, [x9]
	sub	x8, x22, x8
	str	x8, [x9, #8]
LBB0_76:
	ldur	x8, [x29, #-96]
Lloh5:
	adrp	x9, ___stack_chk_guard@GOTPAGE
Lloh6:
	ldr	x9, [x9, ___stack_chk_guard@GOTPAGEOFF]
Lloh7:
	ldr	x9, [x9]
	cmp	x9, x8
	b.ne	LBB0_79
; %bb.77:
	add	sp, sp, #8, lsl #12             ; =32768
	add	sp, sp, #128
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
LBB0_78:
	mov	w0, #2                          ; =0x2
	b	LBB0_76
LBB0_79:
	bl	___stack_chk_fail
	.loh AdrpLdrGotLdr	Lloh2, Lloh3, Lloh4
	.loh AdrpLdrGot	Lloh0, Lloh1
	.loh AdrpLdrGotLdr	Lloh5, Lloh6, Lloh7
	.cfi_endproc
                                        ; -- End function
	.globl	_snappyUncompress               ; -- Begin function snappyUncompress
	.p2align	2
_snappyUncompress:                      ; @snappyUncompress
	.cfi_startproc
; %bb.0:
	stp	x28, x27, [sp, #-96]!           ; 16-byte Folded Spill
	stp	x26, x25, [sp, #16]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #32]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #48]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #64]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #80]             ; 16-byte Folded Spill
	add	x29, sp, #80
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	.cfi_offset w25, -72
	.cfi_offset w26, -80
	.cfi_offset w27, -88
	.cfi_offset w28, -96
	str	xzr, [x2, #8]
	cbz	x1, LBB1_43
; %bb.1:
	mov	x19, x2
	mov	x20, x1
	mov	x21, x0
	ldrb	w9, [x0]
	and	w8, w9, #0x7f
	tbnz	w9, #7, LBB1_10
; %bb.2:
	mov	w23, #1                         ; =0x1
LBB1_3:
	mov	w22, w8
	cmp	x22, x3
	b.ls	LBB1_5
; %bb.4:
	mov	w0, #3                          ; =0x3
	b	LBB1_44
LBB1_5:
	ldr	x8, [x19, #16]
	cmp	x8, x22
	b.hs	LBB1_8
; %bb.6:
	ldr	x0, [x19]
	mov	x1, x22
	bl	_realloc
	cbz	x0, LBB1_41
; %bb.7:
	str	x0, [x19]
	str	x22, [x19, #16]
LBB1_8:
	cmp	x23, x20
	b.hs	LBB1_38
; %bb.9:
	mov	x26, #0                         ; =0x0
	mov	w27, #4                         ; =0x4
	b	LBB1_15
LBB1_10:
	cmp	x20, #1
	b.eq	LBB1_43
; %bb.11:
	ldrsb	w9, [x21, #1]
	bfi	w8, w9, #7, #7
	tbnz	w9, #31, LBB1_42
; %bb.12:
	mov	w23, #2                         ; =0x2
	b	LBB1_3
LBB1_13:                                ;   in Loop: Header=BB1_15 Depth=1
	ldr	x8, [x19]
	add	x0, x8, x26
	ldurb	w1, [x0, #-1]
	mov	x2, x23
	bl	LhandBoundedFill
LBB1_14:                                ;   in Loop: Header=BB1_15 Depth=1
	add	x26, x23, x26
	mov	x23, x28
	cmp	x28, x20
	b.hs	LBB1_39
LBB1_15:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_18 Depth 2
                                        ;     Child Loop BB1_35 Depth 2
	add	x28, x23, #1
	ldrb	w9, [x21, x23]
	ands	w8, w9, #0x3
	b.eq	LBB1_20
; %bb.16:                               ;   in Loop: Header=BB1_15 Depth=1
	cmp	w8, #2
	csel	w10, w8, w27, eq
	cmp	w8, #1
	csinc	w10, w10, wzr, ne
	lsr	w11, w9, #2
	ubfx	w12, w9, #2, #3
	add	w12, w12, #4
	csinc	w23, w12, w11, eq
	sub	x11, x20, x28
	cmp	x11, x10
	b.lo	LBB1_43
; %bb.17:                               ;   in Loop: Header=BB1_15 Depth=1
	add x12, x21, x28
	cmp w8, #2
	b.eq LhandOffsetTwo
	cmp w8, #3
	b.eq LhandOffsetFour
	ldrb w11, [x12]
	add x28, x28, #1
	b LBB1_19
LhandOffsetTwo:
	ldrh w11, [x12]
	add x28, x28, #2
	b LBB1_19
LhandOffsetFour:
	ldr w11, [x12]
	add x28, x28, #4
LBB1_19:
; %bb.19:                               ;   in Loop: Header=BB1_15 Depth=1
	lsl	w9, w9, #3
	and	w9, w9, #0x700
	cmp	w8, #1
	csel	w9, w9, wzr, eq
	add	w10, w11, w9
	cmp	w10, #0
	ccmp	x26, x10, #0, ne
	b.hs	LBB1_31
	b	LBB1_43
LBB1_20:                                ;   in Loop: Header=BB1_15 Depth=1
	lsr	x10, x9, #2
	cmp	w9, #240
	b.lo	LBB1_28
; %bb.21:                               ;   in Loop: Header=BB1_15 Depth=1
	sub	w11, w10, #59
	sub	x9, x20, x28
	cmp	x9, x11
	b.lo	LBB1_43
; %bb.22:                               ;   in Loop: Header=BB1_15 Depth=1
	cbz	w11, LBB1_29
; %bb.23:                               ;   in Loop: Header=BB1_15 Depth=1
	ldrb	w9, [x21, x28]
	cmp	w11, #1
	b.eq	LBB1_27
; %bb.24:                               ;   in Loop: Header=BB1_15 Depth=1
	add	x12, x23, x21
	ldrb	w13, [x12, #2]
	orr	x9, x9, x13, lsl #8
	cmp	w11, #2
	b.eq	LBB1_27
; %bb.25:                               ;   in Loop: Header=BB1_15 Depth=1
	ldrb	w12, [x12, #3]
	orr	x9, x9, x12, lsl #16
	cmp	w11, #3
	b.eq	LBB1_27
; %bb.26:                               ;   in Loop: Header=BB1_15 Depth=1
	add	x11, x23, x21
	ldrb	w11, [x11, #4]
	orr	x9, x9, x11, lsl #24
LBB1_27:                                ;   in Loop: Header=BB1_15 Depth=1
	sub	w10, w10, #60
	add	x10, x23, x10
	add	x28, x10, #2
	b	LBB1_30
LBB1_28:                                ;   in Loop: Header=BB1_15 Depth=1
	add	x23, x10, #1
	sub	x8, x22, x26
	cmp	x8, x23
	b.hs	LBB1_36
	b	LBB1_43
LBB1_29:                                ;   in Loop: Header=BB1_15 Depth=1
	mov	x9, #0                          ; =0x0
LBB1_30:                                ;   in Loop: Header=BB1_15 Depth=1
	mov	w10, #0                         ; =0x0
	add	x23, x9, #1
LBB1_31:                                ;   in Loop: Header=BB1_15 Depth=1
	sub	x9, x22, x26
	cmp	x23, x9
	b.hi	LBB1_43
; %bb.32:                               ;   in Loop: Header=BB1_15 Depth=1
	cbz	w8, LBB1_36
; %bb.33:                               ;   in Loop: Header=BB1_15 Depth=1
	cmp	w10, #1
	b.eq	LBB1_13
; %bb.34:                               ;   in Loop: Header=BB1_15 Depth=1
	mov	w25, w10
	cmp	x23, x25
	csel	x24, x23, x25, lo
	ldr	x8, [x19]
	add	x0, x8, x26
	sub	x1, x0, x25
	mov	x2, x24
	bl	LhandBoundedCopy
	cmp	x23, x25
	b.ls	LBB1_14
LBB1_35:                                ;   Parent Loop BB1_15 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	sub	x8, x23, x24
	cmp	x8, x24
	csel	x25, x8, x24, lo
	ldr	x8, [x19]
	add	x1, x8, x26
	add	x0, x1, x24
	mov	x2, x25
	bl	LhandBoundedCopy
	add	x24, x25, x24
	cmp	x24, x23
	b.lo	LBB1_35
	b	LBB1_14
LBB1_36:                                ;   in Loop: Header=BB1_15 Depth=1
	sub	x8, x20, x28
	cmp	x23, x8
	b.hi	LBB1_43
; %bb.37:                               ;   in Loop: Header=BB1_15 Depth=1
	ldr	x8, [x19]
	add	x0, x8, x26
	add	x1, x21, x28
	mov	x2, x23
	bl	LhandBoundedCopy
	add	x28, x28, x23
	b	LBB1_14
LBB1_38:
	mov	x26, #0                         ; =0x0
LBB1_39:
	cmp	x26, x22
	b.ne	LBB1_43
; %bb.40:
	mov	w0, #0                          ; =0x0
	str	x22, [x19, #8]
	b	LBB1_44
LBB1_41:
	mov	w0, #2                          ; =0x2
	b	LBB1_44
LBB1_42:
	cmp	x20, #2
	b.ne	LBB1_45
LBB1_43:
	mov	w0, #1                          ; =0x1
LBB1_44:
	ldp	x29, x30, [sp, #80]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #64]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #48]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #32]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #16]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp], #96             ; 16-byte Folded Reload
	ret
LBB1_45:
	ldrsb	w9, [x21, #2]
	bfi	w8, w9, #14, #7
	tbnz	w9, #31, LBB1_47
; %bb.46:
	mov	w23, #3                         ; =0x3
	b	LBB1_3
LBB1_47:
	cmp	x20, #3
	b.eq	LBB1_43
; %bb.48:
	ldrsb	w9, [x21, #3]
	bfi	w8, w9, #21, #7
	tbnz	w9, #31, LBB1_50
; %bb.49:
	mov	w23, #4                         ; =0x4
	b	LBB1_3
LBB1_50:
	cmp	x20, #4
	b.eq	LBB1_43
; %bb.51:
	ldrb	w9, [x21, #4]
	cmp	w9, #15
	b.hi	LBB1_43
; %bb.52:
	orr	w8, w8, w9, lsl #28
	mov	w23, #5                         ; =0x5
	b	LBB1_3
	.cfi_endproc
                                        ; -- End function

// Copy exactly x2 bytes between proven nonoverlapping initialized ranges.
.p2align 2
LhandBoundedCopy:
 cmp x2, #64
 b.ls LhandCopySmall
 b _memcpy
LhandCopySmall:
 cmp x2, #16
 b.lo LhandCopyTail
LhandCopyVectors:
 ldr q0, [x1], #16
 str q0, [x0], #16
 sub x2, x2, #16
 cmp x2, #16
 b.hs LhandCopyVectors
LhandCopyTail:
 tbz x2, #3, LhandCopyFour
 ldr x8, [x1], #8
 str x8, [x0], #8
LhandCopyFour:
 tbz x2, #2, LhandCopyTwo
 ldr w8, [x1], #4
 str w8, [x0], #4
LhandCopyTwo:
 tbz x2, #1, LhandCopyOne
 ldrh w8, [x1], #2
 strh w8, [x0], #2
LhandCopyOne:
 tbz x2, #0, LhandCopyReturn
 ldrb w8, [x1]
 strb w8, [x0]
LhandCopyReturn:
 ret
// Fill exactly x2 bytes with the initialized preceding output byte.
.p2align 2
LhandBoundedFill:
 dup v0.16b, w1
 cmp x2, #16
 b.lo LhandFillTail
LhandFillVectors:
 str q0, [x0], #16
 sub x2, x2, #16
 cmp x2, #16
 b.hs LhandFillVectors
LhandFillTail:
 fmov x8, d0
 tbz x2, #3, LhandFillFour
 str x8, [x0], #8
LhandFillFour:
 tbz x2, #2, LhandFillTwo
 str w8, [x0], #4
LhandFillTwo:
 tbz x2, #1, LhandFillOne
 strh w8, [x0], #2
LhandFillOne:
 tbz x2, #0, LhandFillReturn
 strb w8, [x0]
LhandFillReturn:
 ret

.subsections_via_symbols
