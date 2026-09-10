; Draw a box at (28, 13), then leave it on screen.
    CLS
    LD_BYTE V0, 0 ; x
    LD_BYTE V1, 0 ; y
    LD_BYTE V2, 1 ; vx
    LD_BYTE V3, 1 ; vy
    LD_BYTE V4, 0 ; always 0 for subtract
    LD_I box
    DRW V0, V1, 5

loop:
    DRW V0, V1, 5  ; erase old box
    ADD_REG V0, V2
    ADD_REG V1, V3
    DRW V0, V1, 5  ; draw new box

    SNE_BYTE V0, 0
    SUBN V2, V4
    SNE_BYTE V1, 0
    SUBN V3, V4
    SNE_BYTE V0, 56
    SUBN V2, V4
    SNE_BYTE V1, 27
    SUBN V3, V4

    LD_BYTE V5, 2   ; wait for 2 timer ticks
    SET_DT V5

wait:
    GET_DT V5
    SE_BYTE V5, 0
    JP wait

    JP loop

box:
    .byte 0b11111111
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b10000001
    .byte 0b11111111
