// Hand-tuned macOS ARM64 raytracer derived from raytracer_clang.s.
// The sphere tests use two float64 SIMD lanes with exact square roots.
// Rendering hoists row projection; shading avoids redundant Ray copies.
// Derived from raytracer_straight.c, copyright 2021 Andre von Houck and
// Edin Omeragic; distributed under ../LICENSE (MIT).
// See raytracer_manifest.json and ../RAY_HAND_ASM.md for provenance.
	.section	__TEXT,__text,regular,pure_instructions
	.build_version macos, 11, 0
	.globl	_vector                         ; -- Begin function vector
	.p2align	2
_vector:                                ; @vector
	.cfi_startproc
; %bb.0:
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_add                            ; -- Begin function add
	.p2align	2
_add:                                   ; @add
	.cfi_startproc
; %bb.0:
	fadd	d0, d0, d3
	fadd	d1, d1, d4
	fadd	d2, d2, d5
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_subtract                       ; -- Begin function subtract
	.p2align	2
_subtract:                              ; @subtract
	.cfi_startproc
; %bb.0:
	fsub	d0, d0, d3
	fsub	d1, d1, d4
	fsub	d2, d2, d5
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_scale                          ; -- Begin function scale
	.p2align	2
_scale:                                 ; @scale
	.cfi_startproc
; %bb.0:
	fmul	d0, d0, d3
	fmul	d1, d1, d3
	fmul	d2, d2, d3
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_multiply                       ; -- Begin function multiply
	.p2align	2
_multiply:                              ; @multiply
	.cfi_startproc
; %bb.0:
	fmul	d0, d0, d3
	fmul	d1, d1, d4
	fmul	d2, d2, d5
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_dot                            ; -- Begin function dot
	.p2align	2
_dot:                                   ; @dot
	.cfi_startproc
; %bb.0:
	fmul	d0, d0, d3
	fmul	d1, d1, d4
	fadd	d0, d0, d1
	fmul	d1, d2, d5
	fadd	d0, d1, d0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_cross                          ; -- Begin function cross
	.p2align	2
_cross:                                 ; @cross
	.cfi_startproc
; %bb.0:
	fmul	d6, d1, d5
	fmul	d7, d2, d4
	fsub	d6, d6, d7
	fmul	d2, d2, d3
	fmul	d5, d0, d5
	fsub	d5, d2, d5
	fmul	d0, d0, d4
	fmul	d1, d1, d3
	fsub	d2, d0, d1
	fmov	d0, d6
	fmov	d1, d5
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_magnitude                      ; -- Begin function magnitude
	.p2align	2
_magnitude:                             ; @magnitude
	.cfi_startproc
; %bb.0:
	fmul	d0, d0, d0
	fmul	d1, d1, d1
	fadd	d0, d0, d1
	fmul	d1, d2, d2
	fadd	d0, d1, d0
	fsqrt	d0, d0
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_normalize                      ; -- Begin function normalize
	.p2align	2
_normalize:                             ; @normalize
	.cfi_startproc
; %bb.0:
	fmul	d3, d0, d0
	fmul	d4, d1, d1
	fadd	d3, d3, d4
	fmul	d4, d2, d2
	fadd	d3, d4, d3
	fsqrt	d3, d3
	fdiv	d0, d0, d3
	fdiv	d1, d1, d3
	fdiv	d2, d2, d3
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_newCamera                      ; -- Begin function newCamera
	.p2align	2
_newCamera:                             ; @newCamera
	.cfi_startproc
; %bb.0:
	fsub	d3, d3, d0
	fsub	d4, d4, d1
	fsub	d5, d5, d2
	fmul	d6, d3, d3
	fmul	d7, d4, d4
	fadd	d6, d6, d7
	fmul	d7, d5, d5
	fadd	d6, d7, d6
	fsqrt	d6, d6
	fdiv	d3, d3, d6
	fdiv	d4, d4, d6
	fdiv	d5, d5, d6
	movi	d6, #0000000000000000
	fmul	d7, d5, d6
	fmul	d16, d3, d6
	fneg	d17, d3
	stp	d3, d4, [x8]
	fmul	d6, d4, d6
	fadd	d18, d5, d6
	fsub	d7, d7, d16
	fmul	d16, d3, d7
	fmul	d19, d4, d18
	mov.d	v17[1], v16[0]
	mov.d	v6[1], v19[0]
	fsub.2d	v6, v17, v6
	fmul	d4, d4, d6
	fmul	d16, d5, d7
	fsub	d4, d4, d16
	fmul	d16, d5, d18
	fmul	d3, d3, d6
	fsub	d3, d16, d3
	mov.16b	v16, v7
	mov.d	v16[1], v4[0]
	fmul.2d	v16, v16, v16
	mov.16b	v17, v18
	mov.d	v17[1], v3[0]
	fmul.2d	v17, v17, v17
	fadd.2d	v16, v16, v17
	fmul.2d	v17, v6, v6
	fadd.2d	v16, v17, v16
	fsqrt.2d	v16, v16
	fdiv	d17, d18, d16
	fdiv	d7, d7, d16
	fmov	d18, #1.50000000
	fmul	d17, d17, d18
	fmul	d7, d7, d18
	stp	d5, d17, [x8, #16]
	str	d7, [x8, #32]
	mov.16b	v5, v6
	mov.d	v5[1], v4[0]
	fdiv.2d	v4, v5, v16
	fmov.2d	v5, #1.50000000
	fmul.2d	v4, v4, v5
	stur	q4, [x8, #40]
	mov.d	v6[0], v3[0]
	dup.2d	v3, v16[1]
	fdiv.2d	v3, v6, v3
	fmul.2d	v3, v3, v5
	stur	q3, [x8, #56]
	stp	d0, d1, [x8, #72]
	str	d2, [x8, #88]
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_getNormal                      ; -- Begin function getNormal
	.p2align	2
_getNormal:                             ; @getNormal
	.cfi_startproc
; %bb.0:
	mov	w8, #80                         ; =0x50
Lloh0:
	adrp	x9, _things@PAGE
Lloh1:
	add	x9, x9, _things@PAGEOFF
	madd	x8, x0, x8, x9
	ldr	x9, [x8]
	cmp	x9, #1
	b.ne	LBB10_2
; %bb.1:
	ldp	d4, d3, [x8, #24]
	ldr	d5, [x8, #16]
	fsub	d0, d0, d5
	fsub	d1, d1, d4
	fsub	d2, d2, d3
	fmul	d3, d0, d0
	fmul	d4, d1, d1
	fadd	d3, d4, d3
	fmul	d4, d2, d2
	fadd	d3, d4, d3
	fsqrt	d3, d3
	fdiv	d0, d0, d3
	fdiv	d1, d1, d3
	fdiv	d2, d2, d3
	ret
LBB10_2:
	ldr	d1, [x8, #56]
	movi	d0, #0000000000000000
	movi	d2, #0000000000000000
	ret
	.loh AdrpAdd	Lloh0, Lloh1
	.cfi_endproc
                                        ; -- End function
	.globl	_objectIntersect                ; -- Begin function objectIntersect
	.p2align	2
_objectIntersect:                       ; @objectIntersect
	.cfi_startproc
; %bb.0:
	mov	w8, #80                         ; =0x50
Lloh2:
	adrp	x9, _things@PAGE
Lloh3:
	add	x9, x9, _things@PAGEOFF
	madd	x8, x0, x8, x9
	ldr	x9, [x8]
	cmp	x9, #1
	b.ne	LBB11_4
; %bb.1:
	ldr	d1, [x8, #32]
	ldr	q0, [x8, #16]
	ldr	q2, [x1]
	fsub.2d	v0, v0, v2
	ldp	d2, d3, [x1, #16]
	fsub	d1, d1, d2
	fmul	d2, d3, d0
	dup.2d	v3, v0[1]
	mov.d	v3[1], v1[0]
	ldr	q4, [x1, #32]
	fmul.2d	v3, v3, v4
	fadd	d2, d2, d3
	mov	d3, v3[1]
	fadd	d2, d3, d2
	fcmp	d2, #0.0
	b.lt	LBB11_3
; %bb.2:
	ldr	d3, [x8, #40]
	fmul.2d	v0, v0, v0
	faddp.2d	d0, v0
	fmul	d1, d1, d1
	fadd	d0, d1, d0
	fmul	d1, d2, d2
	fsub	d0, d0, d1
	fsub	d0, d3, d0
	fsqrt	d1, d0
	fsub	d1, d2, d1
	fcmp	d0, #0.0
	movi	d0, #0000000000000000
	fcsel	d0, d0, d1, lt
	fcmp	d0, #0.0
	b.ne	LBB11_7
LBB11_3:
	movi	d0, #0000000000000000
	b	LBB11_5
LBB11_4:
	ldr	d1, [x1, #24]
	movi	d0, #0000000000000000
	fmul	d2, d1, d0
	ldr	q3, [x1, #32]
	ldr	d1, [x8, #56]
	fmul.2d	v3, v3, v1
	fadd	d2, d2, d3
	mov	d3, v3[1]
	fadd	d2, d3, d2
	fcmp	d2, #0.0
	b.mi	LBB11_6
LBB11_5:
	mov	x0, #-1                         ; =0xffffffffffffffff
	fmov	x1, d0
	ret
LBB11_6:
	ldr	d0, [x1]
	movi	d3, #0000000000000000
	fmul	d0, d0, d3
	ldur	q4, [x1, #8]
	fmul.2d	v1, v1, v4
	fadd	d0, d0, d1
	mov	d1, v1[1]
	fadd	d0, d1, d0
	fadd	d0, d0, d3
	fneg	d1, d2
	fdiv	d0, d0, d1
LBB11_7:
	fmov	x1, d0
	ret
	.loh AdrpAdd	Lloh2, Lloh3
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0                          ; -- Begin function getProperties
lCPI12_0:
	.quad	0x3fb999999999999a              ; double 0.10000000000000001
	.quad	0x4062c00000000000              ; double 150
lCPI12_1:
	.quad	0x3fe6666666666666              ; double 0.69999999999999996
	.quad	0x4062c00000000000              ; double 150
lCPI12_2:
	.quad	0x3fe6666666666666              ; double 0.69999999999999996
	.quad	0x406f400000000000              ; double 250
	.section	__TEXT,__text,regular,pure_instructions
	.globl	_getProperties
	.p2align	2
_getProperties:                         ; @getProperties
	.cfi_startproc
; %bb.0:
	sub	x9, x0, #1
	cmp	x9, #1
	b.hi	LBB12_2
; %bb.1:
	mov	x9, #4607182418800017408        ; =0x3ff0000000000000
	adrp	x10, _White@PAGE
	add	x10, x10, _White@PAGEOFF
	str	x9, [x8, #16]
	ldr	q0, [x10]
	str	q0, [x8]
	mov	x9, #4602678819172646912        ; =0x3fe0000000000000
	adrp	x10, _Grey@PAGE
	add	x10, x10, _Grey@PAGEOFF
	str	x9, [x8, #40]
	ldr	q0, [x10]
	stur	q0, [x8, #24]
Lloh4:
	adrp	x9, lCPI12_2@PAGE
Lloh5:
	ldr	q0, [x9, lCPI12_2@PAGEOFF]
	str	q0, [x8, #48]
	ret
LBB12_2:
	frintm	d1, d2
	frintm	d0, d0
	fadd	d0, d1, d0
	fcvtzs	x10, d0
	add	x9, x8, #24
	tbnz	w10, #0, LBB12_4
; %bb.3:
	stp	xzr, xzr, [x8]
	str	xzr, [x8, #16]
	mov	x10, #4607182418800017408       ; =0x3ff0000000000000
	adrp	x11, _White@PAGE
	add	x11, x11, _White@PAGEOFF
	str	x10, [x9, #16]
	ldr	q0, [x11]
	str	q0, [x9]
Lloh6:
	adrp	x9, lCPI12_1@PAGE
Lloh7:
	ldr	q0, [x9, lCPI12_1@PAGEOFF]
	str	q0, [x8, #48]
	ret
LBB12_4:
	mov	x10, #4607182418800017408       ; =0x3ff0000000000000
	str	x10, [x8, #16]
Lloh8:
	adrp	x11, _White@PAGE
Lloh9:
	add	x11, x11, _White@PAGEOFF
Lloh10:
	ldr	q0, [x11]
	str	q0, [x8]
	str	x10, [x9, #16]
	str	q0, [x9]
Lloh11:
	adrp	x9, lCPI12_0@PAGE
Lloh12:
	ldr	q0, [x9, lCPI12_0@PAGEOFF]
	str	q0, [x8, #48]
	ret
	.loh AdrpLdr	Lloh4, Lloh5
	.loh AdrpLdr	Lloh6, Lloh7
	.loh AdrpLdr	Lloh11, Lloh12
	.loh AdrpAddLdr	Lloh8, Lloh9, Lloh10
	.cfi_endproc
                                        ; -- End function
	.globl	_intersections                  ; -- Begin function intersections
	.p2align	2
_intersections:                         ; @intersections
	.cfi_startproc
; %bb.0:
	ldp	d5, d4, [x0]
	ldp	d1, d2, [x0, #16]
	ldp	d3, d0, [x0, #32]
	movi	d7, #0000000000000000
	fmul	d6, d0, d7
	fmul	d16, d2, d7
	fadd	d16, d16, d3
	fadd	d6, d6, d16
	fcmp	d6, #0.0
	b.mi	LBB13_2
; %bb.1:
	mov	x1, #0                          ; =0x0
	mov	x0, #-1                         ; =0xffffffffffffffff
	mov	x8, #145685290680320            ; =0x848000000000
	movk	x8, #16686, lsl #48
	fmov	d6, x8
	b	LBB13_5
LBB13_2:
	fmul	d16, d1, d7
	fmul	d17, d5, d7
	fadd	d17, d17, d4
	fadd	d16, d16, d17
	fadd	d16, d16, d7
	fneg	d6, d6
	fdiv	d6, d16, d6
	mov	x8, #145685290680320            ; =0x848000000000
	movk	x8, #16686, lsl #48
	fmov	d16, x8
	fcmp	d6, d16
	b.pl	LBB13_4
; %bb.3:
	mov	x0, #0                          ; =0x0
	fmov	x1, d6
	b	LBB13_5
LBB13_4:
	mov	x1, #0                          ; =0x0
	mov	x0, #-1                         ; =0xffffffffffffffff
	fmov	d6, d16
LBB13_5:

 // Pair sphere coordinates across the two SIMD lanes.
 fmov d16, #-1.0
 ins v7.d[1], v16.d[0]
 dup v16.2d, v5.d[0]
 fsub v16.2d, v7.2d, v16.2d
 fmov d17, #1.0
 fmov d18, #0.5
 ins v17.d[1], v18.d[0]
 dup v18.2d, v4.d[0]
 fsub v17.2d, v17.2d, v18.2d
 fmov d18, #-0.25
 fmov d19, #1.5
 ins v18.d[1], v19.d[0]
 dup v19.2d, v1.d[0]
 fsub v18.2d, v18.2d, v19.2d
 dup v19.2d, v2.d[0]
 fmul v19.2d, v16.2d, v19.2d
 dup v20.2d, v3.d[0]
 fmul v20.2d, v17.2d, v20.2d
 fadd v19.2d, v19.2d, v20.2d
 dup v20.2d, v0.d[0]
 fmul v20.2d, v18.2d, v20.2d
 fadd v19.2d, v19.2d, v20.2d
 fcmge v21.2d, v19.2d, #0.0
 umaxp v22.4s, v21.4s, v21.4s
 fmov x8, d22
 cbz x8, Lintersections_done
 fmul v16.2d, v16.2d, v16.2d
 fmul v17.2d, v17.2d, v17.2d
 fadd v16.2d, v16.2d, v17.2d
 fmul v18.2d, v18.2d, v18.2d
 fadd v16.2d, v16.2d, v18.2d
 fmul v20.2d, v19.2d, v19.2d
 fsub v16.2d, v16.2d, v20.2d
 fmov d17, #1.0
 fmov d18, #0.25
 ins v17.d[1], v18.d[0]
 fsub v16.2d, v17.2d, v16.2d
 fcmge v17.2d, v16.2d, #0.0
 and v21.16b, v21.16b, v17.16b
 umaxp v22.4s, v21.4s, v21.4s
 fmov x8, d22
 cbz x8, Lintersections_done
 and v16.16b, v16.16b, v21.16b
 fsqrt v16.2d, v16.2d
 fsub v19.2d, v19.2d, v16.2d
 and v19.16b, v19.16b, v21.16b
 fcmp d19, #0.0
 fccmp d6, d19, #4, ne
 mov w8, #1
 fmov x9, d19
 csel x0, x8, x0, gt
 csel x1, x9, x1, gt
 fcsel d6, d19, d6, gt
 mov d19, v19.d[1]
 fcmp d19, #0.0
 fccmp d6, d19, #4, ne
 mov w8, #2
 fmov x9, d19
 csel x0, x8, x0, gt
 csel x1, x9, x1, gt
Lintersections_done:
 ret
 .cfi_endproc
                                        ; -- End function

	.globl	_traceRay                       ; -- Begin function traceRay
	.p2align	2
_traceRay:
	.cfi_startproc
	stp x20, x19, [sp, #-32]!
	stp x29, x30, [sp, #16]
	add x29, sp, #16
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	mov x19, x1
	mov x20, x0
	bl _intersections
	cmn x0, #1
	b.eq LshadeTraceMiss
	mov x2, x1
	mov x1, x0
	mov x0, x20
	mov x3, x19
	ldp x29, x30, [sp, #16]
	ldp x20, x19, [sp], #32
	b _shade
LshadeTraceMiss:
	movi d0, #0
	movi d1, #0
	movi d2, #0
	ldp x29, x30, [sp, #16]
	ldp x20, x19, [sp], #32
	ret
	.cfi_endproc
	.globl	_shade                          ; -- Begin function shade
	.p2align	2
_shade:                                 ; @shade
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #192
	stp	d15, d14, [sp, #96]             ; 16-byte Folded Spill
	stp	d13, d12, [sp, #112]            ; 16-byte Folded Spill
	stp	d11, d10, [sp, #128]            ; 16-byte Folded Spill
	stp	d9, d8, [sp, #144]              ; 16-byte Folded Spill
	stp	x20, x19, [sp, #160]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #176]            ; 16-byte Folded Spill
	add	x29, sp, #176
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset b8, -40
	.cfi_offset b9, -48
	.cfi_offset b10, -56
	.cfi_offset b11, -64
	.cfi_offset b12, -72
	.cfi_offset b13, -80
	.cfi_offset b14, -88
	.cfi_offset b15, -96
	mov	x20, x3
	mov	x19, x1
	fmov	d1, x2
	ldr	d18, [x0, #40]
	fmul	d3, d18, d1
	ldr	d4, [x0, #16]
	ldur	q2, [x0, #24]
	fmul.2d	v1, v2, v1[0]
	ldr	q5, [x0]
	fadd.2d	v0, v1, v5
	fadd	d8, d3, d4
	mov	d1, v0[1]
	mov	w8, #80                         ; =0x50
Lloh13:
	adrp	x9, _things@PAGE
Lloh14:
	add	x9, x9, _things@PAGEOFF
	madd	x8, x1, x8, x9
	ldr	x9, [x8]
	cmp	x9, #1
	b.ne	LBB15_2
; %bb.1:
	ldr	d3, [x8, #32]
	fsub	d5, d8, d3
	ldr	q3, [x8, #16]
	fsub.2d	v4, v0, v3
	fmul.2d	v3, v4, v4
	faddp.2d	d3, v3
	fmul	d6, d5, d5
	fadd	d3, d6, d3
	fsqrt	d6, d3
	fdiv	d3, d4, d6
	mov	d4, v4[1]
	fdiv	d4, d4, d6
	fdiv	d5, d5, d6
	b	LBB15_3
LBB15_2:
	ldr	d4, [x8, #56]
	movi	d3, #0000000000000000
	movi	d5, #0000000000000000
LBB15_3:
	fmul	d6, d3, d2
	mov	d7, v2[1]
	fmul.d	d16, d4, v2[1]
	fadd	d6, d6, d16
	fmul	d16, d18, d5
	fadd	d6, d16, d6
	fmul	d16, d3, d6
	fmul	d17, d4, d6
	fmul	d6, d5, d6
	fadd	d16, d16, d16
	fadd	d17, d17, d17
	fadd	d6, d6, d6
	fsub	d12, d2, d16
	fsub	d13, d7, d17
	fsub	d14, d18, d6
	stp	d13, d14, [sp, #8]
	str	d12, [sp]
	mov	x0, x19
	fmov	d2, d8
	str	q0, [sp, #32]                   ; 16-byte Folded Spill
	bl	_getNaturalColor
	fmov	d9, d0
	fmov	d10, d1
	fmov	d11, d2
	fmov	d0, #0.50000000
	fmov	d1, #0.50000000
	fmov	d2, #0.50000000
	cmp	x20, #4
	b.gt	LBB15_11
; %bb.4:
	ldr	q0, [sp, #32]                   ; 16-byte Folded Reload
	str	q0, [sp, #48]
	stp	d8, d12, [sp, #64]
	stp	d13, d14, [sp, #80]
	add	x0, sp, #48
	bl	_intersections
	cmn	x0, #1
	b.eq	LBB15_6
; %bb.5:
	mov	x8, x0
	mov	x2, x1
	add	x3, x20, #1
	add	x0, sp, #48
	mov	x1, x8
	bl	_shade
	b	LBB15_7
LBB15_6:
	movi	d0, #0000000000000000
	movi	d1, #0000000000000000
	movi	d2, #0000000000000000
LBB15_7:
	sub	x8, x19, #1
	cmp	x8, #2
	b.hs	LBB15_9
; %bb.8:
	mov	x8, #7378697629483820646        ; =0x6666666666666666
	movk	x8, #16358, lsl #48
	fmov	d3, x8
	b	LBB15_10
LBB15_9:
	frintm	d3, d8
	ldr	q4, [sp, #32]                   ; 16-byte Folded Reload
	frintm	d4, d4
	fadd	d3, d4, d3
	fcvtzs	x8, d3
	tst	x8, #0x1
	mov	x8, #-7378697629483820647       ; =0x9999999999999999
	movk	x8, #39322
	movk	x8, #16313, lsl #48
	fmov	d3, x8
	mov	x8, #7378697629483820646        ; =0x6666666666666666
	movk	x8, #16358, lsl #48
	fmov	d4, x8
	fcsel	d3, d4, d3, eq
LBB15_10:
	fmul	d0, d0, d3
	fmul	d1, d1, d3
	fmul	d2, d2, d3
LBB15_11:
	movi	d3, #0000000000000000
	fadd	d4, d11, d3
	fadd	d5, d10, d3
	fadd	d3, d9, d3
	fadd	d0, d3, d0
	fadd	d1, d5, d1
	fadd	d2, d4, d2
	ldp	x29, x30, [sp, #176]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #160]            ; 16-byte Folded Reload
	ldp	d9, d8, [sp, #144]              ; 16-byte Folded Reload
	ldp	d11, d10, [sp, #128]            ; 16-byte Folded Reload
	ldp	d13, d12, [sp, #112]            ; 16-byte Folded Reload
	ldp	d15, d14, [sp, #96]             ; 16-byte Folded Reload
	add	sp, sp, #192
	ret
	.loh AdrpAdd	Lloh13, Lloh14
	.cfi_endproc
                                        ; -- End function
	.globl	_getNaturalColor                ; -- Begin function getNaturalColor
	.p2align	2
_getNaturalColor:                       ; @getNaturalColor
	.cfi_startproc
; %bb.0:
	sub	sp, sp, #272
	stp	d15, d14, [sp, #160]            ; 16-byte Folded Spill
	stp	d13, d12, [sp, #176]            ; 16-byte Folded Spill
	stp	d11, d10, [sp, #192]            ; 16-byte Folded Spill
	stp	d9, d8, [sp, #208]              ; 16-byte Folded Spill
	stp	x20, x19, [sp, #240]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #256]            ; 16-byte Folded Spill
	add	x29, sp, #256
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	.cfi_offset w19, -24
	.cfi_offset w20, -32
	.cfi_offset b8, -56
	.cfi_offset b9, -64
	.cfi_offset b10, -72
	.cfi_offset b11, -80
	.cfi_offset b12, -88
	.cfi_offset b13, -96
	.cfi_offset b14, -104
	.cfi_offset b15, -112
	stp	d4, d5, [sp, #56]               ; 16-byte Folded Spill
	str	d3, [sp, #48]                   ; 8-byte Folded Spill
	str	d1, [sp, #80]                   ; 8-byte Folded Spill
	ldp	d6, d7, [x29, #24]
	ldr	d3, [x29, #16]
	fmul	d1, d3, d3
	fmul	d4, d6, d6
	fadd	d1, d1, d4
	fmul	d4, d7, d7
	fadd	d1, d4, d1
	fsqrt	d1, d1
	sub	x8, x0, #1
	cmp	x8, #2
	b.hs	LBB16_2
; %bb.1:
	fmov	d5, #0.50000000
	fmov	d4, #1.00000000
	stp	d4, d5, [sp, #32]               ; 16-byte Folded Spill
	mov	x8, #70368744177664             ; =0x400000000000
	movk	x8, #16495, lsl #48
	b	LBB16_3
LBB16_2:
	frintm	d4, d2
	frintm	d5, d0
	fadd	d4, d4, d5
	fcvtzs	x8, d4
	tst	x8, #0x1
	fmov	d16, #1.00000000
	movi	d4, #0000000000000000
	fmov	d5, #1.00000000
	fcsel	d4, d4, d16, eq
	stp	d4, d5, [sp, #32]               ; 16-byte Folded Spill
	mov	x8, #211106232532992            ; =0xc00000000000
	movk	x8, #16482, lsl #48
LBB16_3:
	str	x8, [sp]                        ; 8-byte Folded Spill
	mov	x19, #0                         ; =0x0
	fdiv	d4, d3, d1
	fdiv	d3, d6, d1
	stp	d3, d4, [sp, #16]               ; 16-byte Folded Spill
	movi	d3, #0000000000000000
	stp	d3, d3, [sp, #96]               ; 16-byte Folded Spill
Lloh15:
	adrp	x20, _lights@PAGE
Lloh16:
	add	x20, x20, _lights@PAGEOFF
	str	d3, [sp, #88]                   ; 8-byte Folded Spill
	fdiv	d1, d7, d1
	str	d1, [sp, #8]                    ; 8-byte Folded Spill
	str	d0, [sp, #72]                   ; 8-byte Folded Spill
	b	LBB16_6
LBB16_4:                                ;   in Loop: Header=BB16_6 Depth=1
	ldp	d5, d6, [sp, #32]               ; 16-byte Folded Reload
	fmul	d0, d5, d12
	fmul	d4, d5, d10
	fmul	d5, d5, d9
	fmul	d3, d6, d3
	fmul	d2, d6, d2
	fmul	d1, d6, d1
	ldr	d6, [sp, #104]                  ; 8-byte Folded Reload
	fadd	d0, d6, d0
	ldr	d6, [sp, #96]                   ; 8-byte Folded Reload
	fadd	d4, d6, d4
	ldr	d6, [sp, #88]                   ; 8-byte Folded Reload
	fadd	d5, d6, d5
	fadd	d6, d0, d3
	fadd	d0, d4, d2
	stp	d0, d6, [sp, #96]               ; 16-byte Folded Spill
	fadd	d0, d5, d1
	str	d0, [sp, #88]                   ; 8-byte Folded Spill
LBB16_5:                                ;   in Loop: Header=BB16_6 Depth=1
	fmov	d2, d13
	ldr	d0, [sp, #72]                   ; 8-byte Folded Reload
	add	x19, x19, #48
	cmp	x19, #192
	b.eq	LBB16_10
LBB16_6:                                ; =>This Inner Loop Header: Depth=1
	add	x8, x20, x19
	ldp	d4, d1, [x8]
	ldp	d3, d15, [x8, #16]
	ldp	d8, d14, [x8, #32]
	fsub	d7, d4, d0
	ldr	d6, [sp, #80]                   ; 8-byte Folded Reload
	fsub	d1, d1, d6
	fsub	d5, d3, d2
	fmul	d3, d7, d7
	fmul	d4, d1, d1
	fadd	d3, d3, d4
	fmul	d4, d5, d5
	fadd	d3, d4, d3
	fsqrt	d11, d3
	fdiv	d9, d7, d11
	fdiv	d10, d1, d11
	stp	d0, d6, [sp, #112]
	fmov	d13, d2
	stp	d2, d9, [sp, #128]
	fdiv	d12, d5, d11
	stp	d10, d12, [sp, #144]
	add	x0, sp, #112
	bl	_intersections
	cmn	x0, #1
	b.eq	LBB16_8
; %bb.7:                                ;   in Loop: Header=BB16_6 Depth=1
	fmov	d0, x1
	fcmp	d11, d0
	b.ge	LBB16_5
LBB16_8:                                ;   in Loop: Header=BB16_6 Depth=1
	ldp	d0, d1, [sp, #48]               ; 16-byte Folded Reload
	fmul	d0, d0, d9
	fmul	d1, d1, d10
	fadd	d0, d0, d1
	ldr	d1, [sp, #64]                   ; 8-byte Folded Reload
	fmul	d1, d1, d12
	fadd	d1, d1, d0
	ldp	d2, d0, [sp, #16]               ; 16-byte Folded Reload
	fmul	d0, d0, d9
	fmul	d2, d2, d10
	fadd	d0, d0, d2
	ldr	d2, [sp, #8]                    ; 8-byte Folded Reload
	fmul	d2, d2, d12
	fadd	d0, d2, d0
	fmul	d2, d15, d1
	fmul	d3, d8, d1
	fmul	d4, d14, d1
	fcmp	d1, #0.0
	movi	d1, #0000000000000000
	fcsel	d9, d4, d1, gt
	fcsel	d10, d3, d1, gt
	fcsel	d12, d2, d1, gt
	fcmp	d0, #0.0
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	b.le	LBB16_4
; %bb.9:                                ;   in Loop: Header=BB16_6 Depth=1
	ldr	d1, [sp]                        ; 8-byte Folded Reload
	bl	_pow
	fmul	d3, d15, d0
	fmul	d2, d8, d0
	fmul	d1, d14, d0
	b	LBB16_4
LBB16_10:
	ldp	d1, d0, [sp, #96]               ; 16-byte Folded Reload
	ldr	d2, [sp, #88]                   ; 8-byte Folded Reload
	ldp	x29, x30, [sp, #256]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #240]            ; 16-byte Folded Reload
	ldp	d9, d8, [sp, #208]              ; 16-byte Folded Reload
	ldp	d11, d10, [sp, #192]            ; 16-byte Folded Reload
	ldp	d13, d12, [sp, #176]            ; 16-byte Folded Reload
	ldp	d15, d14, [sp, #160]            ; 16-byte Folded Reload
	add	sp, sp, #272
	ret
	.loh AdrpAdd	Lloh15, Lloh16
	.cfi_endproc
                                        ; -- End function
	.globl	_getPoint                       ; -- Begin function getPoint
	.p2align	2
_getPoint:                              ; @getPoint
	.cfi_startproc
; %bb.0:
	scvtf	d0, x3
	scvtf	d1, x0
	scvtf	d2, x1
	fmov	d3, #0.50000000
	fmul	d4, d0, d3
	fsub	d1, d1, d4
	fmul	d1, d1, d3
	fdiv	d1, d1, d0
	fsub	d2, d2, d4
	fmov	d3, #-0.50000000
	fmul	d2, d2, d3
	fdiv	d0, d2, d0
	ldr	d2, [x2, #40]
	fmul	d2, d1, d2
	ldr	d3, [x2, #64]
	fmul	d3, d0, d3
	fadd	d2, d2, d3
	ldur	q3, [x2, #24]
	fmul.2d	v1, v3, v1[0]
	ldr	q3, [x2, #48]
	fmul.2d	v0, v3, v0[0]
	fadd.2d	v0, v1, v0
	ldr	q1, [x2]
	fadd.2d	v1, v0, v1
	fmul.2d	v0, v1, v1
	dup.2d	v3, v0[0]
	add	x8, x2, #16
	mov.d	v3[0], v2[0]
	ld1.d	{ v0 }[0], [x8]
	fadd.2d	v2, v3, v0
	fmul.2d	v0, v2, v2
	dup.2d	v3, v2[1]
	fadd.2d	v0, v0, v3
	fsqrt	d3, d0
	fdiv	d0, d1, d3
	mov	d1, v1[1]
	fdiv	d1, d1, d3
	fdiv	d2, d2, d3
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_channel                        ; -- Begin function channel
	.p2align	2
_channel:                               ; @channel
	.cfi_startproc
; %bb.0:
	mov	x8, #246290604621824            ; =0xe00000000000
	movk	x8, #16495, lsl #48
	fmov	d1, x8
	fmul	d0, d0, d1
	fcvtas	x8, d0
	and	x9, x8, #0xff
	negs	x8, x8
	and	x8, x8, #0xff
	csneg	x0, x9, x8, mi
	ret
	.cfi_endproc
                                        ; -- End function
	.globl	_render                         ; -- Begin function render
	.p2align	2
_render:                                ; @render
	.cfi_startproc
; %bb.0:
	cmp	x2, #1
	b.lt	LBB19_9
; %bb.1:
	sub	sp, sp, #224
	stp	d13, d12, [sp, #80]             ; 16-byte Folded Spill
	stp	d11, d10, [sp, #96]             ; 16-byte Folded Spill
	stp	d9, d8, [sp, #112]              ; 16-byte Folded Spill
	stp	x28, x27, [sp, #128]            ; 16-byte Folded Spill
	stp	x26, x25, [sp, #144]            ; 16-byte Folded Spill
	stp	x24, x23, [sp, #160]            ; 16-byte Folded Spill
	stp	x22, x21, [sp, #176]            ; 16-byte Folded Spill
	stp	x20, x19, [sp, #192]            ; 16-byte Folded Spill
	stp	x29, x30, [sp, #208]            ; 16-byte Folded Spill
	add	x29, sp, #208
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
	.cfi_offset b8, -104
	.cfi_offset b9, -112
	.cfi_offset b10, -120
	.cfi_offset b11, -128
	.cfi_offset b12, -136
	.cfi_offset b13, -144
	mov	x19, x2
	mov	x20, x1
	mov	x21, #0                         ; =0x0
	add	x22, x1, #72
	scvtf	d8, x2
	fmov	d9, #0.50000000
	fmul	d10, d8, d9
	add	x23, x0, #2
	add	x24, x2, x2, lsl #1
	fmov	d11, #-0.50000000
	mov	x25, #246290604621824           ; =0xe00000000000
	movk	x25, #16495, lsl #48
	b	LBB19_3
LBB19_2:                                ;   in Loop: Header=BB19_3 Depth=1
	add	x21, x21, #1
	add	x23, x23, x24
	cmp	x21, x19
	b.eq	LBB19_8
LBB19_3:                                ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB19_6 Depth 2
	mov	x26, #0                         ; =0x0
	scvtf	d0, x21
	fsub	d0, d0, d10
	fmul	d0, d0, d11
	fdiv	d0, d0, d8
	ldr	q1, [x20, #48]
	ldr	d2, [x20, #64]
	fmul	d13, d0, d2
	fmul.2d	v0, v1, v0[0]
	str	q0, [sp]                        ; Row vertical XY.
	mov	x27, x23
	b	LBB19_6
LBB19_4:                                ;   in Loop: Header=BB19_6 Depth=2
	mov	x8, x0
	mov	x2, x1
	ldr	q0, [x22]
	str	q0, [sp, #32]
	ldr	x9, [x22, #16]
	str	x9, [sp, #48]
	ldr	q0, [sp, #16]                   ; 16-byte Folded Reload
	stur	q0, [sp, #56]
	str	d12, [sp, #72]
	add	x0, sp, #32
	mov	x1, x8
	mov	x3, #0                          ; =0x0
	bl	_shade
LBB19_5:                                ;   in Loop: Header=BB19_6 Depth=2
	fmov	d3, x25
	fmul	d0, d0, d3
	fcvtas	x8, d0
	sturb	w8, [x27, #-2]
	fmul	d0, d1, d3
	fcvtas	x8, d0
	sturb	w8, [x27, #-1]
	fmul	d0, d2, d3
	fcvtas	x8, d0
	strb	w8, [x27], #3
	add	x26, x26, #1
	cmp	x19, x26
	b.eq	LBB19_2
LBB19_6:                                ;   Parent Loop BB19_3 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	ldr	d0, [x20, #16]
	ldr	d1, [x20, #40]
	scvtf	d2, x26
	fsub	d2, d2, d10
	fmul	d2, d2, d9
	fdiv	d2, d2, d8
	fmul	d1, d2, d1
	ldr	q6, [sp]                        ; 16-byte Folded Reload
	fadd	d1, d1, d13
	fadd	d0, d0, d1
	fmul	d1, d0, d0
	ldr	q3, [x20]
	ldur	q4, [x20, #24]
	fmul.2d	v2, v4, v2[0]
	fadd.2d	v2, v2, v6
	fadd.2d	v2, v3, v2
	fmul.2d	v3, v2, v2
	faddp.2d	d3, v3
	fadd	d1, d1, d3
	fsqrt	d1, d1
	dup.2d	v3, v1[0]
	fdiv.2d	v3, v2, v3
	ldr	q2, [x22]
	stp	q3, q2, [sp, #16]               ; 16-byte Folded Spill
	ldr	x8, [x22, #16]
	str	x8, [sp, #48]
	fdiv	d12, d0, d1
	stur	q3, [sp, #56]
	str	d12, [sp, #72]
	add	x0, sp, #32
	bl	_intersections
	cmn	x0, #1
	b.ne	LBB19_4
; %bb.7:                                ;   in Loop: Header=BB19_6 Depth=2
	movi	d0, #0000000000000000
	movi	d1, #0000000000000000
	movi	d2, #0000000000000000
	b	LBB19_5
LBB19_8:
	ldp	x29, x30, [sp, #208]            ; 16-byte Folded Reload
	ldp	x20, x19, [sp, #192]            ; 16-byte Folded Reload
	ldp	x22, x21, [sp, #176]            ; 16-byte Folded Reload
	ldp	x24, x23, [sp, #160]            ; 16-byte Folded Reload
	ldp	x26, x25, [sp, #144]            ; 16-byte Folded Reload
	ldp	x28, x27, [sp, #128]            ; 16-byte Folded Reload
	ldp	d9, d8, [sp, #112]              ; 16-byte Folded Reload
	ldp	d11, d10, [sp, #96]             ; 16-byte Folded Reload
	ldp	d13, d12, [sp, #80]             ; 16-byte Folded Reload
	add	sp, sp, #224
LBB19_9:
	ret
	.cfi_endproc
                                        ; -- End function
	.section	__TEXT,__const
	.p2align	3, 0x0                          ; @things
_things:
	.quad	0                               ; 0x0
	.quad	0                               ; 0x0
	.space	24
	.quad	0x0000000000000000              ; double 0
	.quad	0x0000000000000000              ; double 0
	.quad	0x3ff0000000000000              ; double 1
	.quad	0x0000000000000000              ; double 0
	.quad	0x0000000000000000              ; double 0
	.quad	1                               ; 0x1
	.quad	1                               ; 0x1
	.quad	0x0000000000000000              ; double 0
	.quad	0x3ff0000000000000              ; double 1
	.quad	0xbfd0000000000000              ; double -0.25
	.quad	0x3ff0000000000000              ; double 1
	.space	24
	.quad	0x0000000000000000              ; double 0
	.quad	1                               ; 0x1
	.quad	1                               ; 0x1
	.quad	0xbff0000000000000              ; double -1
	.quad	0x3fe0000000000000              ; double 0.5
	.quad	0x3ff8000000000000              ; double 1.5
	.quad	0x3fd0000000000000              ; double 0.25
	.space	24
	.quad	0x0000000000000000              ; double 0

	.p2align	3, 0x0                          ; @White
_White:
	.quad	0x3ff0000000000000              ; double 1
	.quad	0x3ff0000000000000              ; double 1
	.quad	0x3ff0000000000000              ; double 1

	.p2align	3, 0x0                          ; @Grey
_Grey:
	.quad	0x3fe0000000000000              ; double 0.5
	.quad	0x3fe0000000000000              ; double 0.5
	.quad	0x3fe0000000000000              ; double 0.5

	.p2align	3, 0x0                          ; @lights
_lights:
	.quad	0xc000000000000000              ; double -2
	.quad	0x4004000000000000              ; double 2.5
	.quad	0x0000000000000000              ; double 0
	.quad	0x3fdf5c28f5c28f5c              ; double 0.48999999999999999
	.quad	0x3fb1eb851eb851ec              ; double 0.070000000000000007
	.quad	0x3fb1eb851eb851ec              ; double 0.070000000000000007
	.quad	0x3ff8000000000000              ; double 1.5
	.quad	0x4004000000000000              ; double 2.5
	.quad	0x3ff8000000000000              ; double 1.5
	.quad	0x3fb1eb851eb851ec              ; double 0.070000000000000007
	.quad	0x3fb1eb851eb851ec              ; double 0.070000000000000007
	.quad	0x3fdf5c28f5c28f5c              ; double 0.48999999999999999
	.quad	0x3ff8000000000000              ; double 1.5
	.quad	0x4004000000000000              ; double 2.5
	.quad	0xbff8000000000000              ; double -1.5
	.quad	0x3fb1eb851eb851ec              ; double 0.070000000000000007
	.quad	0x3fdf5c28f5c28f5c              ; double 0.48999999999999999
	.quad	0x3fb22d0e56041893              ; double 0.070999999999999994
	.quad	0x0000000000000000              ; double 0
	.quad	0x400c000000000000              ; double 3.5
	.quad	0x0000000000000000              ; double 0
	.quad	0x3fcae147ae147ae1              ; double 0.20999999999999999
	.quad	0x3fcae147ae147ae1              ; double 0.20999999999999999
	.quad	0x3fd6666666666666              ; double 0.34999999999999998

.subsections_via_symbols
