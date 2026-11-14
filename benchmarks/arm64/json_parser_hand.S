// Hand-tuned macOS ARM64 JSON implementation derived from json_parser_clang.s.
// jsonString batches bounded ASCII bytes within the current allocation.
// jsonVisit reduces four checksum bytes together with exact arithmetic.
// All other parser, Unicode, ownership, and depth checks retain Clang code.
// See json_parser_manifest.json and ../HAND_ASM.md for provenance and tests.
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 11, 0
	.globl	_jsonDrop                       ; -- Begin function jsonDrop
	.p2align	2
_jsonDrop:                              ; @jsonDrop
	.cfi_startproc
; %bb.0:
	stp	x22, x21, [sp, #-48]!           ; 16-byte Folded Spill
	stp	x20, x19, [sp, #16]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #32]             ; 16-byte Folded Spill
	add	x29, sp, #32
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x19, x0
	ldr	w8, [x0]
	sub	w9, w8, #2
	cmp	w9, #2
	b.lo	LBB0_6
; %bb.1:
	cmp	w8, #4
	b.eq	LBB0_7
; %bb.2:
	cmp	w8, #5
	b.ne	LBB0_11
; %bb.3:
	add	x20, x19, #8
	ldr	x8, [x19, #16]
	cbz	x8, LBB0_10
; %bb.4:
	mov	x21, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
LBB0_5:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x19, #8]
	ldr	x0, [x8, x21]
	bl	_free
	ldr	x8, [x19, #8]
	add	x8, x8, x21
	add	x0, x8, #16
	bl	_jsonDrop
	add	x22, x22, #1
	ldr	x8, [x19, #16]
	add	x21, x21, #48
	cmp	x22, x8
	b.lo	LBB0_5
	b	LBB0_10
LBB0_6:
	add	x20, x19, #8
	b	LBB0_10
LBB0_7:
	add	x20, x19, #8
	ldr	x8, [x19, #16]
	cbz	x8, LBB0_10
; %bb.8:
	mov	x21, #0                         ; =0x0
	mov	x22, #0                         ; =0x0
LBB0_9:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x8, [x19, #8]
	add	x0, x8, x21
	bl	_jsonDrop
	add	x22, x22, #1
	ldr	x8, [x19, #16]
	add	x21, x21, #32
	cmp	x22, x8
	b.lo	LBB0_9
LBB0_10:
	ldr	x0, [x20]
	bl	_free
LBB0_11:
	movi.2d	v0, #0000000000000000
	stp	q0, q0, [x19]
	ldp	x29, x30, [sp, #32]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #16]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp], #48             ; 16-byte Folded Reload
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_jsonParse                      ; -- Begin function jsonParse
	.p2align	2
_jsonParse:                             ; @jsonParse
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #80
	stp	x22, x21, [sp, #32]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #48]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #64]             ; 16-byte Folded Spill
	add	x29, sp, #64
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	mov	x21, x3
	mov	x19, x2
	mov	x20, x1
	mov	x22, x0
	mov	x0, x2
	bl	_jsonDrop
	cbz	x21, LBB1_2
; %bb.1:
	stp	xzr, xzr, [x21]
LBB1_2:
	stp	x22, x20, [sp]
	stp	xzr, x21, [sp, #16]
	cbnz	x22, LBB1_7
; %bb.3:
	cbz	x20, LBB1_7
; %bb.4:
	cbz	x21, LBB1_19
; %bb.5:
	ldr	x8, [x21, #8]
	cbnz	x8, LBB1_19
; %bb.6:
	mov	w0, #0                          ; =0x0
Lloh0:
	adrp	x8, l_.str@PAGE
Lloh1:
	add	x8, x8, l_.str@PAGEOFF
	stp	xzr, x8, [x21]
	b	LBB1_20
LBB1_7:
	mov	x0, sp
	mov	x1, x19
	mov	w2, #0                          ; =0x0
	bl	_jsonValue
	cbz	w0, LBB1_18
; %bb.8:
	ldp	x9, x8, [sp, #8]
	cmp	x8, x9
	b.hs	LBB1_13
; %bb.9:
	ldr	x10, [sp]
	mov	w11, #1                         ; =0x1
	mov	x12, #9728                      ; =0x2600
	movk	x12, #1, lsl #32
LBB1_10:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w13, [x10, x8]
	cmp	w13, #32
	lsl	x13, x11, x13
	and	x13, x13, x12
	ccmp	x13, #0, #4, ls
	b.eq	LBB1_13
; %bb.11:                               ;   in Loop: Header=BB1_10 Depth=1
	add	x8, x8, #1
	str	x8, [sp, #16]
	cmp	x9, x8
	b.ne	LBB1_10
; %bb.12:
	mov	x8, x9
LBB1_13:
	cmp	x8, x20
	b.ne	LBB1_15
; %bb.14:
	mov	w0, #1                          ; =0x1
	b	LBB1_20
LBB1_15:
	ldr	x9, [sp, #24]
	cbz	x9, LBB1_18
; %bb.16:
	ldr	x10, [x9, #8]
	cbnz	x10, LBB1_18
; %bb.17:
	str	x8, [x9]
	ldr	x8, [sp, #24]
Lloh2:
	adrp	x9, l_.str.1@PAGE
Lloh3:
	add	x9, x9, l_.str.1@PAGEOFF
	str	x9, [x8, #8]
LBB1_18:
	mov	x0, x19
	bl	_jsonDrop
LBB1_19:
	mov	w0, #0                          ; =0x0
LBB1_20:
	ldp	x29, x30, [sp, #64]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #48]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #32]             ; 16-byte Folded Reload
	add	sp, sp, #80
	ret
	.loh AdrpAdd	Lloh0, Lloh1
	.loh AdrpAdd	Lloh2, Lloh3
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function jsonValue
_jsonValue:                             ; @jsonValue
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #144
	stp	x28, x27, [sp, #48]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #64]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #80]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #96]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #112]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #128]            ; 16-byte Folded Spill
	add	x29, sp, #128
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
	mov	x20, x1
	mov	x19, x0
	ldp	x8, x22, [x0, #8]
	cmp	x22, x8
	b.hs	LBB2_4
; %bb.1:
	ldr	x9, [x19]
	mov	w10, #1                         ; =0x1
	mov	x11, #9728                      ; =0x2600
	movk	x11, #1, lsl #32
LBB2_2:                                 ; =>This Inner Loop Header: Depth=1
	ldrb	w12, [x9, x22]
	cmp	w12, #32
	lsl	x12, x10, x12
	and	x12, x12, x11
	ccmp	x12, #0, #4, ls
	b.eq	LBB2_4
; %bb.3:                                ;   in Loop: Header=BB2_2 Depth=1
	add	x22, x22, #1
	str	x22, [x19, #16]
	cmp	x8, x22
	b.ne	LBB2_2
	b	LBB2_5
LBB2_4:
	subs	x11, x8, x22
	b.ne	LBB2_9
LBB2_5:
	ldr	x9, [x19, #24]
	cbz	x9, LBB2_7
; %bb.6:
	ldr	x10, [x9, #8]
	cbz	x10, LBB2_12
LBB2_7:
	mov	w0, #0                          ; =0x0
LBB2_8:
	ldp	x29, x30, [sp, #128]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #112]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #96]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #80]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #64]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #48]             ; 16-byte Folded Reload
	add	sp, sp, #144
	ret
LBB2_9:
	ldr	x9, [x19]
	add	x0, x9, x22
	ldrb	w23, [x0]
	cmp	w23, #45
	b.eq	LBB2_13
; %bb.10:
	cmp	w23, #34
	b.ne	LBB2_14
; %bb.11:
	mov	w8, #3                          ; =0x3
	str	w8, [x20], #8
	mov	x0, x19
	mov	x1, x20
	ldp	x29, x30, [sp, #128]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #112]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #96]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #80]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #64]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #48]             ; 16-byte Folded Reload
	add	sp, sp, #144
	b	_jsonString
LBB2_12:
	mov	w0, #0                          ; =0x0
	str	x8, [x9]
	ldr	x8, [x19, #24]
Lloh4:
	adrp	x9, l_.str.2@PAGE
Lloh5:
	add	x9, x9, l_.str.2@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_13:
	add	x10, x22, #1
	str	x10, [x19, #16]
	b	LBB2_15
LBB2_14:
	sub	w12, w23, #48
	mov	x10, x22
	cmp	w12, #10
	b.hs	LBB2_30
LBB2_15:
	cmp	x10, x8
	b.hs	LBB2_27
; %bb.16:
	ldrb	w11, [x9, x10]
	sub	w12, w11, #48
	cmp	w12, #10
	b.hs	LBB2_27
; %bb.17:
	cmp	w11, #48
	b.ne	LBB2_25
; %bb.18:
	add	x10, x10, #1
	str	x10, [x19, #16]
LBB2_19:
	cmp	x10, x8
	b.hs	LBB2_36
; %bb.20:
	ldrb	w11, [x9, x10]
	cmp	w11, #46
	b.ne	LBB2_36
; %bb.21:
	add	x10, x10, #1
	str	x10, [x19, #16]
	cmp	x10, x8
	b.hs	LBB2_65
; %bb.22:
	ldrb	w11, [x9, x10]
	sub	w11, w11, #48
	cmp	w11, #9
	b.hi	LBB2_65
LBB2_23:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w11, [x9, x10]
	sub	w11, w11, #48
	cmp	w11, #9
	b.hi	LBB2_36
; %bb.24:                               ;   in Loop: Header=BB2_23 Depth=1
	add	x10, x10, #1
	str	x10, [x19, #16]
	cmp	x8, x10
	b.ne	LBB2_23
	b	LBB2_46
LBB2_25:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w11, [x9, x10]
	sub	w11, w11, #48
	cmp	w11, #9
	b.hi	LBB2_19
; %bb.26:                               ;   in Loop: Header=BB2_25 Depth=1
	add	x10, x10, #1
	str	x10, [x19, #16]
	cmp	x8, x10
	b.ne	LBB2_25
	b	LBB2_46
LBB2_27:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.28:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.29:
	mov	w0, #0                          ; =0x0
	str	x10, [x8]
	ldr	x8, [x19, #24]
Lloh6:
	adrp	x9, l_.str.28@PAGE
Lloh7:
	add	x9, x9, l_.str.28@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_30:
	sub	w8, w23, #91
	cmp	w8, #32
	b.hi	LBB2_47
; %bb.31:
Lloh8:
	adrp	x1, l_.str.8@PAGE
Lloh9:
	add	x1, x1, l_.str.8@PAGEOFF
	mov	w21, #4                         ; =0x4
Lloh10:
	adrp	x9, lJTI2_0@PAGE
Lloh11:
	add	x9, x9, lJTI2_0@PAGEOFF
	adr	x10, LBB2_32
	ldrb	w12, [x9, x8]
	add	x10, x10, x12, lsl #2
	br	x10
LBB2_32:
	cmp	w2, #512
	b.ne	LBB2_57
; %bb.33:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.34:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.35:
	mov	w0, #0                          ; =0x0
	str	x22, [x8]
	ldr	x8, [x19, #24]
Lloh12:
	adrp	x9, l_.str.3@PAGE
Lloh13:
	add	x9, x9, l_.str.3@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_36:
	cmp	x10, x8
	b.hs	LBB2_46
; %bb.37:
	ldrb	w11, [x9, x10]
	orr	w11, w11, #0x20
	cmp	w11, #101
	b.ne	LBB2_46
; %bb.38:
	add	x11, x10, #1
	str	x11, [x19, #16]
	cmp	x11, x8
	b.hs	LBB2_42
; %bb.39:
	ldrb	w12, [x9, x11]
	cmp	w12, #45
	b.eq	LBB2_41
; %bb.40:
	cmp	w12, #43
	b.ne	LBB2_42
LBB2_41:
	add	x11, x10, #2
	str	x11, [x19, #16]
LBB2_42:
	cmp	x11, x8
	b.hs	LBB2_62
; %bb.43:
	ldrb	w10, [x9, x11]
	sub	w10, w10, #48
	cmp	w10, #9
	b.hi	LBB2_62
LBB2_44:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w10, [x9, x11]
	sub	w10, w10, #48
	cmp	w10, #9
	b.hi	LBB2_46
; %bb.45:                               ;   in Loop: Header=BB2_44 Depth=1
	add	x11, x11, #1
	str	x11, [x19, #16]
	cmp	x8, x11
	b.ne	LBB2_44
LBB2_46:
	mov	w8, #2                          ; =0x2
	str	w8, [x20], #8
	str	xzr, [sp]
	ldr	x8, [x19]
	add	x3, x8, x22
	ldr	x8, [x19, #16]
	sub	x4, x8, x22
	mov	x2, sp
	mov	x0, x19
	mov	x1, x20
	bl	_jsonBytes
	b	LBB2_8
LBB2_47:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.48:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.49:
	mov	w0, #0                          ; =0x0
	str	x22, [x8]
	ldr	x8, [x19, #24]
Lloh14:
	adrp	x9, l_.str.11@PAGE
Lloh15:
	add	x9, x9, l_.str.11@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_50:
Lloh16:
	adrp	x1, l_.str.10@PAGE
Lloh17:
	add	x1, x1, l_.str.10@PAGEOFF
	mov	w21, #5                         ; =0x5
	b	LBB2_52
LBB2_51:
Lloh18:
	adrp	x1, l_.str.9@PAGE
Lloh19:
	add	x1, x1, l_.str.9@PAGEOFF
	mov	w21, #4                         ; =0x4
LBB2_52:
	cmp	x11, x21
	b.lo	LBB2_54
; %bb.53:
	mov	x2, x21
	bl	_memcmp
	cbz	w0, LBB2_119
LBB2_54:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.55:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.56:
	mov	w0, #0                          ; =0x0
	str	x22, [x8]
	ldr	x8, [x19, #24]
Lloh20:
	adrp	x9, l_.str.12@PAGE
Lloh21:
	add	x9, x9, l_.str.12@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_57:
	cmp	w23, #123
	mov	w8, #4                          ; =0x4
	cinc	w8, w8, eq
	str	w8, [x20]
	ldp	x8, x9, [x19, #8]
	add	x9, x9, #1
	str	x9, [x19, #16]
	cmp	x9, x8
	b.hs	LBB2_68
; %bb.58:
	ldr	x10, [x19]
	mov	w11, #1                         ; =0x1
	mov	x12, #9728                      ; =0x2600
	movk	x12, #1, lsl #32
LBB2_59:                                ; =>This Inner Loop Header: Depth=1
	ldrb	w13, [x10, x9]
	cmp	w13, #32
	lsl	x13, x11, x13
	and	x13, x13, x12
	ccmp	x13, #0, #4, ls
	b.eq	LBB2_68
; %bb.60:                               ;   in Loop: Header=BB2_59 Depth=1
	add	x9, x9, #1
	str	x9, [x19, #16]
	cmp	x8, x9
	b.ne	LBB2_59
; %bb.61:
	mov	w9, #93                         ; =0x5d
	mov	w10, #125                       ; =0x7d
	cmp	w23, #123
	csel	w24, w10, w9, eq
	mov	x9, x8
	b	LBB2_71
LBB2_62:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.63:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.64:
	mov	w0, #0                          ; =0x0
	str	x11, [x8]
	ldr	x8, [x19, #24]
Lloh22:
	adrp	x9, l_.str.30@PAGE
Lloh23:
	add	x9, x9, l_.str.30@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_65:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.66:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.67:
	mov	w0, #0                          ; =0x0
	str	x10, [x8]
	ldr	x8, [x19, #24]
Lloh24:
	adrp	x9, l_.str.29@PAGE
Lloh25:
	add	x9, x9, l_.str.29@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_68:
	mov	w10, #93                        ; =0x5d
	mov	w11, #125                       ; =0x7d
	cmp	w23, #123
	csel	w24, w11, w10, eq
	cmp	x9, x8
	b.hs	LBB2_71
; %bb.69:
	ldr	x10, [x19]
	ldrb	w10, [x10, x9]
	cmp	w10, w24
	b.ne	LBB2_71
; %bb.70:
	add	x8, x9, #1
	str	x8, [x19, #16]
	mov	w0, #1                          ; =0x1
	b	LBB2_8
LBB2_71:
	mov	x10, sp
	add	x21, x10, #16
	add	w22, w2, #1
	movi.2d	v0, #0000000000000000
	mov	w25, #1                         ; =0x1
	mov	x26, #9728                      ; =0x2600
	movk	x26, #1, lsl #32
	mov	w27, #8                         ; =0x8
	mov	w28, #48                        ; =0x30
LBB2_72:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB2_83 Depth 2
                                        ;     Child Loop BB2_78 Depth 2
                                        ;     Child Loop BB2_90 Depth 2
                                        ;     Child Loop BB2_110 Depth 2
                                        ;     Child Loop BB2_116 Depth 2
	stp	q0, q0, [sp, #16]
	str	q0, [sp]
	cmp	w23, #123
	b.ne	LBB2_80
; %bb.73:                               ;   in Loop: Header=BB2_72 Depth=1
	cmp	x9, x8
	b.eq	LBB2_127
; %bb.74:                               ;   in Loop: Header=BB2_72 Depth=1
	ldr	x8, [x19]
	ldrb	w8, [x8, x9]
	cmp	w8, #34
	b.ne	LBB2_127
; %bb.75:                               ;   in Loop: Header=BB2_72 Depth=1
	mov	x1, sp
	mov	x0, x19
	bl	_jsonString
	tbz	w0, #0, LBB2_130
; %bb.76:                               ;   in Loop: Header=BB2_72 Depth=1
	ldp	x9, x8, [x19, #8]
	cmp	x8, x9
	b.hs	LBB2_85
; %bb.77:                               ;   in Loop: Header=BB2_72 Depth=1
	ldr	x10, [x19]
LBB2_78:                                ;   Parent Loop BB2_72 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w11, [x10, x8]
	cmp	w11, #32
	lsl	x11, x25, x11
	and	x11, x11, x26
	ccmp	x11, #0, #4, ls
	b.eq	LBB2_85
; %bb.79:                               ;   in Loop: Header=BB2_78 Depth=2
	add	x8, x8, #1
	str	x8, [x19, #16]
	cmp	x9, x8
	b.ne	LBB2_78
	b	LBB2_124
LBB2_80:                                ;   in Loop: Header=BB2_72 Depth=1
	mov	x0, x19
	mov	x1, x21
	mov	x2, x22
	bl	_jsonValue
	tbz	w0, #0, LBB2_149
; %bb.81:                               ;   in Loop: Header=BB2_72 Depth=1
	ldp	x0, x9, [x20, #8]
	add	x8, x9, #1
	ldr	x10, [x20, #24]
	cmp	x10, x8
	b.hs	LBB2_99
; %bb.82:                               ;   in Loop: Header=BB2_72 Depth=1
	cmp	x10, #0
	csel	x28, x27, x10, eq
	cmp	x28, x8
	b.hs	LBB2_93
LBB2_83:                                ;   Parent Loop BB2_72 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	tbnz	x28, #63, LBB2_92
; %bb.84:                               ;   in Loop: Header=BB2_83 Depth=2
	lsl	x28, x28, #1
	cmp	x28, x8
	b.lo	LBB2_83
	b	LBB2_93
LBB2_85:                                ;   in Loop: Header=BB2_72 Depth=1
	cmp	x8, x9
	b.eq	LBB2_124
; %bb.86:                               ;   in Loop: Header=BB2_72 Depth=1
	ldr	x9, [x19]
	ldrb	w9, [x9, x8]
	cmp	w9, #58
	b.ne	LBB2_124
; %bb.87:                               ;   in Loop: Header=BB2_72 Depth=1
	add	x8, x8, #1
	str	x8, [x19, #16]
	mov	x0, x19
	mov	x1, x21
	mov	x2, x22
	bl	_jsonValue
	tbz	w0, #0, LBB2_149
; %bb.88:                               ;   in Loop: Header=BB2_72 Depth=1
	ldp	x0, x9, [x20, #8]
	add	x8, x9, #1
	ldr	x10, [x20, #24]
	cmp	x10, x8
	b.hs	LBB2_107
; %bb.89:                               ;   in Loop: Header=BB2_72 Depth=1
	cmp	x10, #0
	csel	x28, x27, x10, eq
	cmp	x28, x8
	b.hs	LBB2_101
LBB2_90:                                ;   Parent Loop BB2_72 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	tbnz	x28, #63, LBB2_100
; %bb.91:                               ;   in Loop: Header=BB2_90 Depth=2
	lsl	x28, x28, #1
	cmp	x28, x8
	b.lo	LBB2_90
	b	LBB2_101
LBB2_92:                                ;   in Loop: Header=BB2_72 Depth=1
	mov	x28, x8
LBB2_93:                                ;   in Loop: Header=BB2_72 Depth=1
	lsr	x8, x28, #59
	cbnz	x8, LBB2_135
; %bb.94:                               ;   in Loop: Header=BB2_72 Depth=1
	lsl	x1, x28, #5
	cbz	x0, LBB2_96
; %bb.95:                               ;   in Loop: Header=BB2_72 Depth=1
	bl	_realloc
	b	LBB2_97
LBB2_96:                                ;   in Loop: Header=BB2_72 Depth=1
	mov	x0, x1
	bl	_malloc
LBB2_97:                                ;   in Loop: Header=BB2_72 Depth=1
	cbz	x0, LBB2_138
; %bb.98:                               ;   in Loop: Header=BB2_72 Depth=1
	str	x28, [x20, #24]
	ldr	x9, [x20, #16]
	add	x8, x9, #1
	mov	w28, #48                        ; =0x30
LBB2_99:                                ;   in Loop: Header=BB2_72 Depth=1
	stp	x0, x8, [x20, #8]
	add	x8, x0, x9, lsl #5
	ldp	q0, q1, [x21]
	b	LBB2_108
LBB2_100:                               ;   in Loop: Header=BB2_72 Depth=1
	mov	x28, x8
LBB2_101:                               ;   in Loop: Header=BB2_72 Depth=1
	mov	x8, #6148914691236517205        ; =0x5555555555555555
	movk	x8, #21846
	movk	x8, #1365, lsl #48
	cmp	x28, x8
	b.hs	LBB2_142
; %bb.102:                              ;   in Loop: Header=BB2_72 Depth=1
	add	x8, x28, x28, lsl #1
	lsl	x1, x8, #4
	cbz	x0, LBB2_104
; %bb.103:                              ;   in Loop: Header=BB2_72 Depth=1
	bl	_realloc
	b	LBB2_105
LBB2_104:                               ;   in Loop: Header=BB2_72 Depth=1
	mov	x0, x1
	bl	_malloc
LBB2_105:                               ;   in Loop: Header=BB2_72 Depth=1
	cbz	x0, LBB2_145
; %bb.106:                              ;   in Loop: Header=BB2_72 Depth=1
	str	x28, [x20, #24]
	ldr	x9, [x20, #16]
	add	x8, x9, #1
	mov	w28, #48                        ; =0x30
LBB2_107:                               ;   in Loop: Header=BB2_72 Depth=1
	stp	x0, x8, [x20, #8]
	madd	x8, x9, x28, x0
	ldp	q0, q1, [sp]
	ldr	q2, [sp, #32]
	str	q2, [x8, #32]
LBB2_108:                               ;   in Loop: Header=BB2_72 Depth=1
	stp	q0, q1, [x8]
	ldp	x8, x10, [x19, #8]
	cmp	x10, x8
	movi.2d	v0, #0000000000000000
	b.hs	LBB2_112
; %bb.109:                              ;   in Loop: Header=BB2_72 Depth=1
	ldr	x9, [x19]
LBB2_110:                               ;   Parent Loop BB2_72 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w11, [x9, x10]
	cmp	w11, #32
	lsl	x11, x25, x11
	and	x11, x11, x26
	ccmp	x11, #0, #4, ls
	b.eq	LBB2_112
; %bb.111:                              ;   in Loop: Header=BB2_110 Depth=2
	add	x10, x10, #1
	str	x10, [x19, #16]
	cmp	x8, x10
	b.ne	LBB2_110
	b	LBB2_121
LBB2_112:                               ;   in Loop: Header=BB2_72 Depth=1
	cmp	x10, x8
	b.eq	LBB2_121
; %bb.113:                              ;   in Loop: Header=BB2_72 Depth=1
	ldr	x11, [x19]
	add	x9, x10, #1
	str	x9, [x19, #16]
	ldrb	w10, [x11, x10]
	cmp	w10, w24
	b.eq	LBB2_131
; %bb.114:                              ;   in Loop: Header=BB2_72 Depth=1
	cmp	w10, #44
	b.ne	LBB2_132
; %bb.115:                              ;   in Loop: Header=BB2_72 Depth=1
	cmp	x9, x8
	b.hs	LBB2_72
LBB2_116:                               ;   Parent Loop BB2_72 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldrb	w10, [x11, x9]
	cmp	w10, #32
	lsl	x10, x25, x10
	and	x10, x10, x26
	ccmp	x10, #0, #4, ls
	b.eq	LBB2_72
; %bb.117:                              ;   in Loop: Header=BB2_116 Depth=2
	add	x9, x9, #1
	str	x9, [x19, #16]
	cmp	x8, x9
	b.ne	LBB2_116
; %bb.118:                              ;   in Loop: Header=BB2_72 Depth=1
	mov	x9, x8
	b	LBB2_72
LBB2_119:
	add	x8, x21, x22
	str	x8, [x19, #16]
	mov	w0, #1                          ; =0x1
	cmp	w23, #110
	b.eq	LBB2_8
; %bb.120:
	str	w0, [x20]
	cmp	w23, #116
	cset	w8, eq
	strb	w8, [x20, #8]
	b	LBB2_8
LBB2_121:
	ldr	x9, [x19, #24]
	cbz	x9, LBB2_7
; %bb.122:
	ldr	x10, [x9, #8]
	cbnz	x10, LBB2_7
; %bb.123:
	mov	w0, #0                          ; =0x0
	str	x8, [x9]
	ldr	x8, [x19, #24]
Lloh26:
	adrp	x9, l_.str.6@PAGE
Lloh27:
	add	x9, x9, l_.str.6@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_124:
	ldr	x0, [sp]
	bl	_free
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.125:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_7
; %bb.126:
	mov	w0, #0                          ; =0x0
	ldr	x9, [x19, #16]
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh28:
	adrp	x9, l_.str.5@PAGE
Lloh29:
	add	x9, x9, l_.str.5@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_127:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.128:
	ldr	x10, [x8, #8]
	cbnz	x10, LBB2_7
; %bb.129:
	mov	w0, #0                          ; =0x0
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh30:
	adrp	x9, l_.str.4@PAGE
Lloh31:
	add	x9, x9, l_.str.4@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_130:
	ldr	x0, [sp]
	bl	_free
	b	LBB2_7
LBB2_131:
	mov	w0, #1                          ; =0x1
	b	LBB2_8
LBB2_132:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_7
; %bb.133:
	ldr	x10, [x8, #8]
	cbnz	x10, LBB2_7
; %bb.134:
	mov	w0, #0                          ; =0x0
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh32:
	adrp	x9, l_.str.7@PAGE
Lloh33:
	add	x9, x9, l_.str.7@PAGEOFF
	str	x9, [x8, #8]
	b	LBB2_8
LBB2_135:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_150
; %bb.136:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_150
; %bb.137:
Lloh34:
	adrp	x9, l_.str.25@PAGE
Lloh35:
	add	x9, x9, l_.str.25@PAGEOFF
	b	LBB2_141
LBB2_138:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_150
; %bb.139:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_150
; %bb.140:
Lloh36:
	adrp	x9, l_.str.31@PAGE
Lloh37:
	add	x9, x9, l_.str.31@PAGEOFF
LBB2_141:
	ldr	x10, [x19, #16]
	str	x10, [x8]
	ldr	x8, [x19, #24]
	str	x9, [x8, #8]
	b	LBB2_150
LBB2_142:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_149
; %bb.143:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_149
; %bb.144:
Lloh38:
	adrp	x9, l_.str.25@PAGE
Lloh39:
	add	x9, x9, l_.str.25@PAGEOFF
	b	LBB2_148
LBB2_145:
	ldr	x8, [x19, #24]
	cbz	x8, LBB2_149
; %bb.146:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB2_149
; %bb.147:
Lloh40:
	adrp	x9, l_.str.31@PAGE
Lloh41:
	add	x9, x9, l_.str.31@PAGEOFF
LBB2_148:
	ldr	x10, [x19, #16]
	str	x10, [x8]
	ldr	x8, [x19, #24]
	str	x9, [x8, #8]
LBB2_149:
	ldr	x0, [sp]
	bl	_free
LBB2_150:
	mov	x0, x21
	bl	_jsonDrop
	b	LBB2_7
	.loh AdrpAdd	Lloh4, Lloh5
	.loh AdrpAdd	Lloh6, Lloh7
	.loh AdrpAdd	Lloh10, Lloh11
	.loh AdrpAdd	Lloh8, Lloh9
	.loh AdrpAdd	Lloh12, Lloh13
	.loh AdrpAdd	Lloh14, Lloh15
	.loh AdrpAdd	Lloh16, Lloh17
	.loh AdrpAdd	Lloh18, Lloh19
	.loh AdrpAdd	Lloh20, Lloh21
	.loh AdrpAdd	Lloh22, Lloh23
	.loh AdrpAdd	Lloh24, Lloh25
	.loh AdrpAdd	Lloh26, Lloh27
	.loh AdrpAdd	Lloh28, Lloh29
	.loh AdrpAdd	Lloh30, Lloh31
	.loh AdrpAdd	Lloh32, Lloh33
	.loh AdrpAdd	Lloh34, Lloh35
	.loh AdrpAdd	Lloh36, Lloh37
	.loh AdrpAdd	Lloh38, Lloh39
	.loh AdrpAdd	Lloh40, Lloh41
	.cfi_endproc
	.section	__TEXT,__const
lJTI2_0:
	.byte	(LBB2_32-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_50-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_52-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_51-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_47-LBB2_32)>>2
	.byte	(LBB2_32-LBB2_32)>>2
                                        ; -- End function
	.section	__TEXT,__text,regular,pure_instructions
	.globl	_jsonDigest                     ; -- Begin function jsonDigest
	.p2align	2
_jsonDigest:                            ; @jsonDigest
	.cfi_startproc
; %bb.0:
	mov	x1, #0                          ; =0x0
	b	_jsonVisit
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function jsonVisit
_jsonVisit:                             ; @jsonVisit
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	add	x29, sp, #48
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	w20, #51719                     ; =0xca07
	movk	w20, #15258, lsl #16
	mov	x24, #36837
	movk	x24, #4770, lsl #16
	movk	x24, #24369, lsl #32
	movk	x24, #35184, lsl #48
	ldr	w8, [x0]
	add	w9, w8, #1
	add	x10, x1, x1, lsl #8
	add	x9, x10, x9
	mov	x10, #36837                     ; =0x8fe5
	movk	x10, #4770, lsl #16
	movk	x10, #24369, lsl #32
	movk	x10, #35184, lsl #48
	umulh	x10, x9, x10
	lsr	x10, x10, #29
	msub	x1, x10, x20, x9
	cmp	w8, #5
	b.hi	LBB4_16
; %bb.1:
Lloh42:
	adrp	x9, lJTI4_0@PAGE
Lloh43:
	add	x9, x9, lJTI4_0@PAGEOFF
	adr	x10, LBB4_2
	ldrsw	x11, [x9, x8, lsl #2]
	add	x10, x10, x11
	br	x10
LBB4_2:
	ldr	x8, [x0, #16]
	cbz	x8, LBB4_5
; %bb.3:
	ldr	x9, [x0, #8]
LBB4_4:
	cmp x8, #4
	b.lo Ldigest_str_tail
Ldigest_str_four:
	ldrb w10, [x9]
	ldrb w11, [x9, #1]
	ldrb w12, [x9, #2]
	ldrb w13, [x9, #3]
	add x1, x1, x1, lsl #8
	add x1, x1, x10
	add x1, x1, x1, lsl #8
	add x1, x1, x11
	add x1, x1, x1, lsl #8
	add x1, x1, x12
	add x1, x1, x1, lsl #8
	add x1, x1, x13
	umulh x10, x1, x24
	lsr x10, x10, #29
	msub x1, x10, x20, x1
	add x9, x9, #4
	sub x8, x8, #4
	cmp x8, #4
	b.hs Ldigest_str_four
Ldigest_str_tail:
	cbz x8, Ldigest_str_done
Ldigest_str_one:
	ldrb w10, [x9], #1
	add x11, x1, x1, lsl #8
	add x10, x11, x10
	umulh x11, x10, x24
	lsr x11, x11, #29
	msub x1, x11, x20, x10
	subs x8, x8, #1
	b.ne Ldigest_str_one
Ldigest_str_done:
LBB4_5:
	add	x8, x1, x1, lsl #8
	b	LBB4_17
LBB4_6:
	ldrb	w8, [x0, #8]
	add	x9, x1, x1, lsl #8
	add	x8, x9, x8
	b	LBB4_17
LBB4_7:
	ldr	x21, [x0, #16]
	cbz	x21, LBB4_16
; %bb.8:
	ldr	x19, [x0, #8]
LBB4_9:                                 ; =>This Inner Loop Header: Depth=1
	mov	x0, x19
	bl	_jsonVisit
	mov	x1, x0
	add	x19, x19, #32
	subs	x21, x21, #1
	b.ne	LBB4_9
	b	LBB4_16
LBB4_10:
	ldr	x19, [x0, #16]
	cbz	x19, LBB4_16
; %bb.11:
	mov	x21, #0                         ; =0x0
	ldr	x22, [x0, #8]
	mov	w23, #48                        ; =0x30
	b	LBB4_13
LBB4_12:                                ;   in Loop: Header=BB4_13 Depth=1
	add	x8, x1, x1, lsl #8
	umulh	x9, x8, x24
	lsr	x9, x9, #29
	msub	x1, x9, x20, x8
	madd	x8, x21, x23, x22
	add	x0, x8, #16
	bl	_jsonVisit
	mov	x1, x0
	add	x21, x21, #1
	cmp	x21, x19
	b.eq	LBB4_16
LBB4_13:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB4_15 Depth 2
	madd	x9, x21, x23, x22
	ldr	x8, [x9, #8]
	cbz	x8, LBB4_12
; %bb.14:                               ;   in Loop: Header=BB4_13 Depth=1
	ldr	x9, [x9]
LBB4_15:
	cmp x8, #4
	b.lo Ldigest_key_tail
Ldigest_key_four:
	ldrb w10, [x9]
	ldrb w11, [x9, #1]
	ldrb w12, [x9, #2]
	ldrb w13, [x9, #3]
	add x1, x1, x1, lsl #8
	add x1, x1, x10
	add x1, x1, x1, lsl #8
	add x1, x1, x11
	add x1, x1, x1, lsl #8
	add x1, x1, x12
	add x1, x1, x1, lsl #8
	add x1, x1, x13
	umulh x10, x1, x24
	lsr x10, x10, #29
	msub x1, x10, x20, x1
	add x9, x9, #4
	sub x8, x8, #4
	cmp x8, #4
	b.hs Ldigest_key_four
Ldigest_key_tail:
	cbz x8, Ldigest_key_done
Ldigest_key_one:
	ldrb w10, [x9], #1
	add x11, x1, x1, lsl #8
	add x10, x11, x10
	umulh x11, x10, x24
	lsr x11, x11, #29
	msub x1, x11, x20, x10
	subs x8, x8, #1
	b.ne Ldigest_key_one
Ldigest_key_done:
	b	LBB4_12
LBB4_16:
	add	x8, x1, x1, lsl #8
	add	x8, x8, #255
LBB4_17:
	umulh	x9, x8, x24
	lsr	x9, x9, #29
	msub	x1, x9, x20, x8
LBB4_18:
	mov	x0, x1
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	ret
	.loh AdrpAdd	Lloh42, Lloh43
	.cfi_endproc
	.section	__TEXT,__const
lJTI4_0:
	.long	(LBB4_18-LBB4_2)
	.long	(LBB4_6-LBB4_2)
	.long	(LBB4_2-LBB4_2)
	.long	(LBB4_2-LBB4_2)
	.long	(LBB4_7-LBB4_2)
	.long	(LBB4_10-LBB4_2)
                                        ; -- End function
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2                               ; -- Begin function jsonString
_jsonString:                            ; @jsonString
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #128
	stp	x28, x27, [sp, #32]             ; 16-byte Folded Spill
	stp	x26, x25, [sp, #48]             ; 16-byte Folded Spill
	stp	x24, x23, [sp, #64]             ; 16-byte Folded Spill
	stp	x22, x21, [sp, #80]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #96]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #112]            ; 16-byte Folded Spill
	add	x29, sp, #112
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
	mov	x19, x0
	str	xzr, [sp, #24]
	ldp	x9, x8, [x0, #8]
	add	x8, x8, #1
	str	x8, [x0, #16]
	cmp	x8, x9
	b.hs	LBB5_52
; %bb.1:
	mov	x20, x1
	mov	w21, #8                         ; =0x8
	mov	w22, #12                        ; =0xc
	mov	w23, #10                        ; =0xa
	mov	w24, #13                        ; =0xd
	mov	w25, #9                         ; =0x9
	mov	w26, #55296                     ; =0xd800
Lloh44:
	adrp	x27, lJTI5_0@PAGE
Lloh45:
	add	x27, x27, lJTI5_0@PAGEOFF
LBB5_2:                                 ; =>This Inner Loop Header: Depth=1
	ldr	x10, [x19]
	add	x11, x8, #1
	str	x11, [x19, #16]
	add	x3, x10, x8
	ldrb	w13, [x3]
	strb	w13, [sp, #23]
	cmp	w13, #34
	b.eq	LBB5_57
; %bb.3:                                ;   in Loop: Header=BB5_2 Depth=1
	cmp	w13, #31
	b.ls	LBB5_59
; %bb.4:                                ;   in Loop: Header=BB5_2 Depth=1
	cmp	w13, #92
	b.ne	LBB5_9
; %bb.5:                                ;   in Loop: Header=BB5_2 Depth=1
	cmp	x9, x11
	b.eq	LBB5_62
; %bb.6:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x8, x8, #2
	str	x8, [x19, #16]
	ldrb	w9, [x10, x11]
	strb	w9, [sp, #23]
	sub	w9, w9, #34
	cmp	w9, #83
	b.hi	LBB5_78
; %bb.7:                                ;   in Loop: Header=BB5_2 Depth=1
	adr	x10, LBB5_8
	ldrh	w11, [x27, x9, lsl #1]
	add	x10, x10, x11, lsl #2
	br	x10
LBB5_8:                                 ;   in Loop: Header=BB5_2 Depth=1
	strb	w21, [sp, #23]
	b	LBB5_10
LBB5_9:                                 ;   in Loop: Header=BB5_2 Depth=1
	tbnz	w13, #7, LBB5_11
	// Append an ASCII run while existing capacity suffices. Never read
	// beyond the input or cross an allocation boundary speculatively.
	ldp	x12, x14, [x20]
	ldr	x15, [sp, #24]
	add	x16, x14, #1
	cmp	x16, x15
	b.hs	LBB5_10
LjsonAsciiRun:
	strb	w13, [x12, x14]
	add	x14, x14, #1
	cmp	x11, x9
	b.hs	LjsonAsciiDone
	add	x16, x14, #1
	cmp	x16, x15
	b.hs	LjsonAsciiDone
	ldrb	w13, [x10, x11]
	sub	w16, w13, #32
	cmp	w16, #95
	b.hi	LjsonAsciiDone
	cmp	w13, #34
	b.eq	LjsonAsciiDone
	cmp	w13, #92
	b.eq	LjsonAsciiDone
	add	x11, x11, #1
	b	LjsonAsciiRun
LjsonAsciiDone:
	str	x11, [x19, #16]
	str	x14, [x20, #8]
	strb	wzr, [x12, x14]
	b	LBB5_51
LBB5_10:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x2, sp, #24
	add	x3, sp, #23
	mov	x0, x19
	mov	x1, x20
	mov	w4, #1                          ; =0x1
	bl	_jsonBytes
	tbnz	w0, #0, LBB5_51
	b	LBB5_54
LBB5_11:                                ;   in Loop: Header=BB5_2 Depth=1
	add	w16, w13, #62
	and	w12, w16, #0xff
	cmp	w12, #30
	b.hs	LBB5_13
; %bb.12:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	w15, #0                         ; =0x0
	mov	w12, #128                       ; =0x80
	mov	w17, #31                        ; =0x1f
	mov	w14, #1                         ; =0x1
	b	LBB5_26
LBB5_13:                                ;   in Loop: Header=BB5_2 Depth=1
	and	w12, w13, #0xf0
	cmp	w12, #224
	b.ne	LBB5_24
; %bb.14:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	w12, #2048                      ; =0x800
	mov	w15, #1                         ; =0x1
	mov	w17, #15                        ; =0xf
	mov	w14, #2                         ; =0x2
	b	LBB5_26
LBB5_15:                                ;   in Loop: Header=BB5_2 Depth=1
	strb	w22, [sp, #23]
	b	LBB5_10
LBB5_16:                                ;   in Loop: Header=BB5_2 Depth=1
	strb	w23, [sp, #23]
	b	LBB5_10
LBB5_17:                                ;   in Loop: Header=BB5_2 Depth=1
	strb	w24, [sp, #23]
	b	LBB5_10
LBB5_18:                                ;   in Loop: Header=BB5_2 Depth=1
	strb	w25, [sp, #23]
	b	LBB5_10
LBB5_19:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x1, sp, #16
	mov	x0, x19
	bl	_jsonHex
	cbz	w0, LBB5_54
; %bb.20:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	w9, #56320                      ; =0xdc00
	mov	w21, #9216                      ; =0x2400
	movk	w21, #64672, lsl #16
	ldr	w28, [sp, #16]
	and	w8, w28, #0xfffffc00
	cmp	w8, w26
	b.eq	LBB5_38
; %bb.21:                               ;   in Loop: Header=BB5_2 Depth=1
	cmp	w8, w9
	b.eq	LBB5_84
; %bb.22:                               ;   in Loop: Header=BB5_2 Depth=1
	cmp	w28, #127
	b.hi	LBB5_45
; %bb.23:                               ;   in Loop: Header=BB5_2 Depth=1
	strb	w28, [sp, #12]
	mov	w4, #1                          ; =0x1
	mov	w21, #8                         ; =0x8
	b	LBB5_49
LBB5_24:                                ;   in Loop: Header=BB5_2 Depth=1
	add	w12, w13, #16
	and	w12, w12, #0xff
	cmp	w12, #5
	b.hs	LBB5_81
; %bb.25:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	w15, #0                         ; =0x0
	mov	w12, #65536                     ; =0x10000
	mov	w17, #7                         ; =0x7
	mov	w14, #3                         ; =0x3
LBB5_26:                                ;   in Loop: Header=BB5_2 Depth=1
	sub	x9, x9, x11
	cmp	x9, x14
	b.lo	LBB5_65
; %bb.27:                               ;   in Loop: Header=BB5_2 Depth=1
	add	x9, x8, #2
	str	x9, [x19, #16]
	ldrb	w0, [x10, x11]
	and	w11, w0, #0xc0
	cmp	w11, #128
	b.ne	LBB5_72
; %bb.28:                               ;   in Loop: Header=BB5_2 Depth=1
	and	w11, w17, w13
	and	w13, w16, #0xff
	and	w16, w0, #0x3f
	orr	w16, w16, w11, lsl #6
	cmp	w13, #30
	b.hs	LBB5_30
; %bb.29:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	x8, x16
	b	LBB5_35
LBB5_30:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x13, x8, #3
	str	x13, [x19, #16]
	ldrb	w9, [x10, x9]
	and	w11, w9, #0xc0
	cmp	w11, #128
	b.ne	LBB5_71
; %bb.31:                               ;   in Loop: Header=BB5_2 Depth=1
	and	w9, w9, #0x3f
	orr	w11, w9, w16, lsl #6
	tbz	w15, #0, LBB5_33
; %bb.32:                               ;   in Loop: Header=BB5_2 Depth=1
	mov	x8, x11
	mov	x11, x16
	mov	x9, x13
	b	LBB5_35
LBB5_33:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x9, x8, #4
	str	x9, [x19, #16]
	ldrb	w8, [x10, x13]
	and	w10, w8, #0xc0
	cmp	w10, #128
	b.ne	LBB5_72
; %bb.34:                               ;   in Loop: Header=BB5_2 Depth=1
	and	w8, w8, #0x3f
	orr	w8, w8, w11, lsl #6
LBB5_35:                                ;   in Loop: Header=BB5_2 Depth=1
	cmp	w8, w12
	lsr	w8, w8, #16
	ccmp	w8, #16, #2, hs
	b.hi	LBB5_68
; %bb.36:                               ;   in Loop: Header=BB5_2 Depth=1
	and	w8, w11, #0x1ffe0
	cmp	w8, #864
	b.eq	LBB5_68
; %bb.37:                               ;   in Loop: Header=BB5_2 Depth=1
	add	x4, x14, #1
	add	x2, sp, #24
	b	LBB5_50
LBB5_38:                                ;   in Loop: Header=BB5_2 Depth=1
	ldp	x9, x8, [x19, #8]
	sub	x9, x9, x8
	cmp	x9, #2
	b.lo	LBB5_75
; %bb.39:                               ;   in Loop: Header=BB5_2 Depth=1
	ldr	x9, [x19]
	ldrb	w10, [x9, x8]
	cmp	w10, #92
	b.ne	LBB5_75
; %bb.40:                               ;   in Loop: Header=BB5_2 Depth=1
	add	x9, x8, x9
	ldrb	w9, [x9, #1]
	cmp	w9, #117
	b.ne	LBB5_75
; %bb.41:                               ;   in Loop: Header=BB5_2 Depth=1
	add	x8, x8, #2
	str	x8, [x19, #16]
	add	x1, sp, #12
	mov	x0, x19
	bl	_jsonHex
	cbz	w0, LBB5_54
; %bb.42:                               ;   in Loop: Header=BB5_2 Depth=1
	ldr	w8, [sp, #12]
	sub	w9, w8, #14, lsl #12            ; =57344
	cmn	w9, #1025
	b.ls	LBB5_87
; %bb.43:                               ;   in Loop: Header=BB5_2 Depth=1
	add	w8, w8, w28, lsl #10
	add	w28, w8, w21
	str	w28, [sp, #16]
	mov	w21, #8                         ; =0x8
LBB5_44:                                ;   in Loop: Header=BB5_2 Depth=1
	lsr	w8, w28, #18
	orr	w8, w8, #0xf0
	strb	w8, [sp, #12]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #12, #6
	strb	w8, [sp, #13]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #6, #6
	strb	w8, [sp, #14]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #0, #6
	strb	w8, [sp, #15]
	mov	w4, #4                          ; =0x4
	b	LBB5_49
LBB5_45:                                ;   in Loop: Header=BB5_2 Depth=1
	cmp	w28, #2047
	mov	w21, #8                         ; =0x8
	b.hi	LBB5_47
; %bb.46:                               ;   in Loop: Header=BB5_2 Depth=1
	lsr	w8, w28, #6
	orr	w8, w8, #0xc0
	strb	w8, [sp, #12]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #0, #6
	strb	w8, [sp, #13]
	mov	w4, #2                          ; =0x2
	b	LBB5_49
LBB5_47:                                ;   in Loop: Header=BB5_2 Depth=1
	lsr	w8, w28, #16
	cbnz	w8, LBB5_44
; %bb.48:                               ;   in Loop: Header=BB5_2 Depth=1
	lsr	w8, w28, #12
	orr	w8, w8, #0xe0
	strb	w8, [sp, #12]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #6, #6
	strb	w8, [sp, #13]
	mov	w8, #128                        ; =0x80
	bfxil	w8, w28, #0, #6
	strb	w8, [sp, #14]
	mov	w4, #3                          ; =0x3
LBB5_49:                                ;   in Loop: Header=BB5_2 Depth=1
	add	x2, sp, #24
	add	x3, sp, #12
LBB5_50:                                ;   in Loop: Header=BB5_2 Depth=1
	mov	x0, x19
	mov	x1, x20
	bl	_jsonBytes
	tbz	w0, #0, LBB5_54
LBB5_51:                                ;   in Loop: Header=BB5_2 Depth=1
	ldp	x9, x8, [x19, #8]
	cmp	x8, x9
	b.lo	LBB5_2
LBB5_52:
	ldr	x9, [x19, #24]
	cbz	x9, LBB5_54
; %bb.53:
	ldr	x10, [x9, #8]
	cbz	x10, LBB5_55
LBB5_54:
	mov	w0, #0                          ; =0x0
	b	LBB5_58
LBB5_55:
	mov	w0, #0                          ; =0x0
	str	x8, [x9]
	ldr	x8, [x19, #24]
Lloh46:
	adrp	x9, l_.str.24@PAGE
Lloh47:
	add	x9, x9, l_.str.24@PAGEOFF
LBB5_56:
	str	x9, [x8, #8]
	b	LBB5_58
LBB5_57:
Lloh48:
	adrp	x3, l_.str.13@PAGE
Lloh49:
	add	x3, x3, l_.str.13@PAGEOFF
	add	x2, sp, #24
	mov	x0, x19
	mov	x1, x20
	mov	x4, #0                          ; =0x0
	bl	_jsonBytes
LBB5_58:
	ldp	x29, x30, [sp, #112]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #96]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #80]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #64]             ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #48]             ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #32]             ; 16-byte Folded Reload
	add	sp, sp, #128
	ret
LBB5_59:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.60:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB5_54
; %bb.61:
	mov	w0, #0                          ; =0x0
	str	x11, [x8]
	ldr	x8, [x19, #24]
Lloh50:
	adrp	x9, l_.str.14@PAGE
Lloh51:
	add	x9, x9, l_.str.14@PAGEOFF
	b	LBB5_56
LBB5_62:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.63:
	ldr	x10, [x8, #8]
	cbnz	x10, LBB5_54
; %bb.64:
	mov	w0, #0                          ; =0x0
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh52:
	adrp	x9, l_.str.15@PAGE
Lloh53:
	add	x9, x9, l_.str.15@PAGEOFF
	b	LBB5_56
LBB5_65:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.66:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB5_54
; %bb.67:
	mov	w0, #0                          ; =0x0
	str	x11, [x8]
	ldr	x8, [x19, #24]
Lloh54:
	adrp	x9, l_.str.21@PAGE
Lloh55:
	add	x9, x9, l_.str.21@PAGEOFF
	b	LBB5_56
LBB5_68:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.69:
	ldr	x10, [x8, #8]
	cbnz	x10, LBB5_54
; %bb.70:
	mov	w0, #0                          ; =0x0
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh56:
	adrp	x9, l_.str.23@PAGE
Lloh57:
	add	x9, x9, l_.str.23@PAGEOFF
	b	LBB5_56
LBB5_71:
	mov	x9, x13
LBB5_72:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.73:
	ldr	x10, [x8, #8]
	cbnz	x10, LBB5_54
; %bb.74:
	mov	w0, #0                          ; =0x0
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh58:
	adrp	x9, l_.str.22@PAGE
Lloh59:
	add	x9, x9, l_.str.22@PAGEOFF
	b	LBB5_56
LBB5_75:
	ldr	x9, [x19, #24]
	cbz	x9, LBB5_54
; %bb.76:
	ldr	x10, [x9, #8]
	cbnz	x10, LBB5_54
; %bb.77:
	str	x8, [x9]
	ldr	x8, [x19, #24]
Lloh60:
	adrp	x9, l_.str.16@PAGE
Lloh61:
	add	x9, x9, l_.str.16@PAGEOFF
	b	LBB5_90
LBB5_78:
	ldr	x9, [x19, #24]
	cbz	x9, LBB5_54
; %bb.79:
	ldr	x10, [x9, #8]
	cbnz	x10, LBB5_54
; %bb.80:
	mov	w0, #0                          ; =0x0
	str	x8, [x9]
	ldr	x8, [x19, #24]
Lloh62:
	adrp	x9, l_.str.19@PAGE
Lloh63:
	add	x9, x9, l_.str.19@PAGEOFF
	b	LBB5_56
LBB5_81:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.82:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB5_54
; %bb.83:
	mov	w0, #0                          ; =0x0
	str	x11, [x8]
	ldr	x8, [x19, #24]
Lloh64:
	adrp	x9, l_.str.20@PAGE
Lloh65:
	add	x9, x9, l_.str.20@PAGEOFF
	b	LBB5_56
LBB5_84:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.85:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB5_54
; %bb.86:
	ldr	x9, [x19, #16]
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh66:
	adrp	x9, l_.str.18@PAGE
Lloh67:
	add	x9, x9, l_.str.18@PAGEOFF
	b	LBB5_90
LBB5_87:
	ldr	x8, [x19, #24]
	cbz	x8, LBB5_54
; %bb.88:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB5_54
; %bb.89:
	ldr	x9, [x19, #16]
	str	x9, [x8]
	ldr	x8, [x19, #24]
Lloh68:
	adrp	x9, l_.str.17@PAGE
Lloh69:
	add	x9, x9, l_.str.17@PAGEOFF
LBB5_90:
	str	x9, [x8, #8]
	mov	w0, #0                          ; =0x0
	b	LBB5_58
	.loh AdrpAdd	Lloh44, Lloh45
	.loh AdrpAdd	Lloh46, Lloh47
	.loh AdrpAdd	Lloh48, Lloh49
	.loh AdrpAdd	Lloh50, Lloh51
	.loh AdrpAdd	Lloh52, Lloh53
	.loh AdrpAdd	Lloh54, Lloh55
	.loh AdrpAdd	Lloh56, Lloh57
	.loh AdrpAdd	Lloh58, Lloh59
	.loh AdrpAdd	Lloh60, Lloh61
	.loh AdrpAdd	Lloh62, Lloh63
	.loh AdrpAdd	Lloh64, Lloh65
	.loh AdrpAdd	Lloh66, Lloh67
	.loh AdrpAdd	Lloh68, Lloh69
	.cfi_endproc
	.section	__TEXT,__const
	.p2align	1, 0x0
lJTI5_0:
	.short	(LBB5_10-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_10-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_10-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_8-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_15-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_16-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_17-LBB5_8)>>2
	.short	(LBB5_78-LBB5_8)>>2
	.short	(LBB5_18-LBB5_8)>>2
	.short	(LBB5_19-LBB5_8)>>2
                                        ; -- End function
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2                               ; -- Begin function jsonBytes
_jsonBytes:                             ; @jsonBytes
	.cfi_startproc
; %bb.0:
	stp	x24, x23, [sp, #-64]!           ; 16-byte Folded Spill
	stp	x22, x21, [sp, #16]             ; 16-byte Folded Spill
	stp	x20, x19, [sp, #32]             ; 16-byte Folded Spill
	stp	x29, x30, [sp, #48]             ; 16-byte Folded Spill
	add	x29, sp, #48
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset w21, -40
	.cfi_offset w22, -48
	.cfi_offset w23, -56
	.cfi_offset w24, -64
	mov	x21, x0
	ldr	x9, [x1, #8]
	mov	x8, #-2                         ; =0xfffffffffffffffe
	sub	x8, x8, x4
	cmp	x9, x8
	b.ls	LBB6_4
; %bb.1:
	ldr	x8, [x21, #24]
	cbz	x8, LBB6_3
; %bb.2:
	ldr	x9, [x8, #8]
	cbz	x9, LBB6_12
LBB6_3:
	mov	w0, #0                          ; =0x0
	b	LBB6_14
LBB6_4:
	mov	x19, x4
	mov	x22, x3
	mov	x23, x2
	mov	x20, x1
	ldr	x0, [x1]
	add	x8, x4, x9
	add	x8, x8, #1
	ldr	x10, [x2]
	cmp	x10, x8
	b.hs	LBB6_11
; %bb.5:
	mov	w9, #8                          ; =0x8
	cmp	x10, #0
	csel	x24, x9, x10, eq
	cmp	x24, x8
	b.hs	LBB6_8
LBB6_6:                                 ; =>This Inner Loop Header: Depth=1
	tbnz	x24, #63, LBB6_15
; %bb.7:                                ;   in Loop: Header=BB6_6 Depth=1
	lsl	x24, x24, #1
	cmp	x24, x8
	b.lo	LBB6_6
LBB6_8:
	cbz	x0, LBB6_16
LBB6_9:
	mov	x1, x24
	bl	_realloc
	cbz	x0, LBB6_17
LBB6_10:
	str	x24, [x23]
	ldr	x9, [x20, #8]
LBB6_11:
	str	x0, [x20]
	add	x0, x0, x9
	mov	x1, x22
	mov	x2, x19
	bl	_memcpy
	ldp	x9, x8, [x20]
	add	x8, x8, x19
	str	x8, [x20, #8]
	strb	wzr, [x9, x8]
	mov	w0, #1                          ; =0x1
	b	LBB6_14
LBB6_12:
	mov	w0, #0                          ; =0x0
	ldr	x9, [x21, #16]
	str	x9, [x8]
	ldr	x8, [x21, #24]
Lloh70:
	adrp	x9, l_.str.25@PAGE
Lloh71:
	add	x9, x9, l_.str.25@PAGEOFF
LBB6_13:
	str	x9, [x8, #8]
LBB6_14:
	ldp	x29, x30, [sp, #48]             ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #32]             ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #16]             ; 16-byte Folded Reload
	ldp	x24, x23, [sp], #64             ; 16-byte Folded Reload
	ret
LBB6_15:
	mov	x24, x8
	cbnz	x0, LBB6_9
LBB6_16:
	mov	x0, x24
	bl	_malloc
	cbnz	x0, LBB6_10
LBB6_17:
	ldr	x8, [x21, #24]
	cbz	x8, LBB6_3
; %bb.18:
	ldr	x9, [x8, #8]
	cbnz	x9, LBB6_3
; %bb.19:
	mov	w0, #0                          ; =0x0
	ldr	x9, [x21, #16]
	str	x9, [x8]
	ldr	x8, [x21, #24]
Lloh72:
	adrp	x9, l_.str.31@PAGE
Lloh73:
	add	x9, x9, l_.str.31@PAGEOFF
	b	LBB6_13
	.loh AdrpAdd	Lloh70, Lloh71
	.loh AdrpAdd	Lloh72, Lloh73
	.cfi_endproc
                                        ; -- End function
	.p2align	2                               ; -- Begin function jsonHex
_jsonHex:                               ; @jsonHex
	.cfi_startproc
; %bb.0:
	str	wzr, [x1]
	ldp	x8, x10, [x0, #8]
	cmp	x10, x8
	b.eq	LBB7_22
; %bb.1:
	ldr	x8, [x0]
	add	x9, x10, #1
	str	x9, [x0, #16]
	ldrb	w8, [x8, x10]
	sub	w10, w8, #48
	cmp	w10, #10
	b.hs	LBB7_3
; %bb.2:
	mov	w9, #-48                        ; =0xffffffd0
	b	LBB7_7
LBB7_3:
	sub	w10, w8, #97
	cmp	w10, #6
	b.hs	LBB7_5
; %bb.4:
	mov	w9, #-87                        ; =0xffffffa9
	b	LBB7_7
LBB7_5:
	sub	w10, w8, #65
	cmp	w10, #6
	b.hs	LBB7_34
; %bb.6:
	mov	w9, #-55                        ; =0xffffffc9
LBB7_7:
	add	w8, w9, w8
	ldr	w9, [x1]
	orr	w8, w8, w9, lsl #4
	str	w8, [x1]
	ldp	x8, x10, [x0, #8]
	cmp	x10, x8
	b.eq	LBB7_22
; %bb.8:
	ldr	x8, [x0]
	add	x9, x10, #1
	str	x9, [x0, #16]
	ldrb	w8, [x8, x10]
	sub	w10, w8, #48
	cmp	w10, #10
	b.hs	LBB7_10
; %bb.9:
	mov	w9, #-48                        ; =0xffffffd0
	b	LBB7_14
LBB7_10:
	sub	w10, w8, #97
	cmp	w10, #6
	b.hs	LBB7_12
; %bb.11:
	mov	w9, #-87                        ; =0xffffffa9
	b	LBB7_14
LBB7_12:
	sub	w10, w8, #65
	cmp	w10, #5
	b.hi	LBB7_34
; %bb.13:
	mov	w9, #-55                        ; =0xffffffc9
LBB7_14:
	add	w8, w9, w8
	ldr	w9, [x1]
	orr	w8, w8, w9, lsl #4
	str	w8, [x1]
	ldp	x8, x10, [x0, #8]
	cmp	x10, x8
	b.eq	LBB7_22
; %bb.15:
	ldr	x8, [x0]
	add	x9, x10, #1
	str	x9, [x0, #16]
	ldrb	w8, [x8, x10]
	sub	w10, w8, #48
	cmp	w10, #10
	b.hs	LBB7_17
; %bb.16:
	mov	w9, #-48                        ; =0xffffffd0
	b	LBB7_21
LBB7_17:
	sub	w10, w8, #97
	cmp	w10, #6
	b.hs	LBB7_19
; %bb.18:
	mov	w9, #-87                        ; =0xffffffa9
	b	LBB7_21
LBB7_19:
	sub	w10, w8, #65
	cmp	w10, #5
	b.hi	LBB7_34
; %bb.20:
	mov	w9, #-55                        ; =0xffffffc9
LBB7_21:
	add	w8, w9, w8
	ldr	w9, [x1]
	orr	w8, w8, w9, lsl #4
	str	w8, [x1]
	ldp	x8, x10, [x0, #8]
	cmp	x10, x8
	b.ne	LBB7_27
LBB7_22:
	ldr	x9, [x0, #24]
	cbz	x9, LBB7_24
; %bb.23:
	ldr	x8, [x9, #8]
	cbz	x8, LBB7_25
LBB7_24:
	mov	w0, #0                          ; =0x0
	ret
LBB7_25:
	str	x10, [x9]
	ldr	x9, [x0, #24]
Lloh74:
	adrp	x10, l_.str.26@PAGE
Lloh75:
	add	x10, x10, l_.str.26@PAGEOFF
LBB7_26:
	str	x10, [x9, #8]
	mov	x0, x8
	ret
LBB7_27:
	ldr	x8, [x0]
	add	x9, x10, #1
	str	x9, [x0, #16]
	ldrb	w8, [x8, x10]
	sub	w10, w8, #48
	cmp	w10, #10
	b.hs	LBB7_29
; %bb.28:
	mov	w9, #-48                        ; =0xffffffd0
	b	LBB7_33
LBB7_29:
	sub	w10, w8, #97
	cmp	w10, #6
	b.hs	LBB7_31
; %bb.30:
	mov	w9, #-87                        ; =0xffffffa9
	b	LBB7_33
LBB7_31:
	sub	w10, w8, #65
	cmp	w10, #5
	b.hi	LBB7_34
; %bb.32:
	mov	w9, #-55                        ; =0xffffffc9
LBB7_33:
	add	w8, w9, w8
	ldr	w9, [x1]
	orr	w8, w8, w9, lsl #4
	str	w8, [x1]
	mov	w0, #1                          ; =0x1
	ret
LBB7_34:
	ldr	x10, [x0, #24]
	cbz	x10, LBB7_24
; %bb.35:
	ldr	x8, [x10, #8]
	cbnz	x8, LBB7_24
; %bb.36:
	str	x9, [x10]
	ldr	x9, [x0, #24]
Lloh76:
	adrp	x10, l_.str.27@PAGE
Lloh77:
	add	x10, x10, l_.str.27@PAGEOFF
	b	LBB7_26
	.loh AdrpAdd	Lloh74, Lloh75
	.loh AdrpAdd	Lloh76, Lloh77
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__cstring,cstring_literals
l_.str:                                 ; @.str
	.asciz	"Null input"

l_.str.1:                               ; @.str.1
	.asciz	"Trailing input"

l_.str.2:                               ; @.str.2
	.asciz	"Expected JSON value"

l_.str.3:                               ; @.str.3
	.asciz	"JSON nesting depth exceeded"

l_.str.4:                               ; @.str.4
	.asciz	"Expected object key"

l_.str.5:                               ; @.str.5
	.asciz	"Expected colon"

l_.str.6:                               ; @.str.6
	.asciz	"Unclosed container"

l_.str.7:                               ; @.str.7
	.asciz	"Expected comma or closing delimiter"

l_.str.8:                               ; @.str.8
	.asciz	"null"

l_.str.9:                               ; @.str.9
	.asciz	"true"

l_.str.10:                              ; @.str.10
	.asciz	"false"

l_.str.11:                              ; @.str.11
	.asciz	"Invalid JSON value"

l_.str.12:                              ; @.str.12
	.asciz	"Invalid literal"

l_.str.13:                              ; @.str.13
	.space	1

l_.str.14:                              ; @.str.14
	.asciz	"Control byte in string"

l_.str.15:                              ; @.str.15
	.asciz	"Short escape"

l_.str.16:                              ; @.str.16
	.asciz	"Missing low surrogate"

l_.str.17:                              ; @.str.17
	.asciz	"Invalid low surrogate"

l_.str.18:                              ; @.str.18
	.asciz	"Unpaired low surrogate"

l_.str.19:                              ; @.str.19
	.asciz	"Invalid escape"

l_.str.20:                              ; @.str.20
	.asciz	"Invalid UTF-8 leading byte"

l_.str.21:                              ; @.str.21
	.asciz	"Short UTF-8 sequence"

l_.str.22:                              ; @.str.22
	.asciz	"Invalid UTF-8 continuation"

l_.str.23:                              ; @.str.23
	.asciz	"Invalid UTF-8 scalar"

l_.str.24:                              ; @.str.24
	.asciz	"Unterminated string"

l_.str.25:                              ; @.str.25
	.asciz	"Allocation overflow"

l_.str.26:                              ; @.str.26
	.asciz	"Short Unicode escape"

l_.str.27:                              ; @.str.27
	.asciz	"Invalid Unicode escape"

l_.str.28:                              ; @.str.28
	.asciz	"Expected number digit"

l_.str.29:                              ; @.str.29
	.asciz	"Expected fraction digit"

l_.str.30:                              ; @.str.30
	.asciz	"Expected exponent digit"

l_.str.31:                              ; @.str.31
	.asciz	"Out of memory"

.subsections_via_symbols
