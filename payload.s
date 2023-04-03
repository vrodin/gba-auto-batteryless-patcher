.arm
.balign 4

# the following values are exposed for the benefit of the patcher program.
# The named constants are expected to be changed by the patcher.
original_entrypoint_addr:
    .word 0x080000c0
flush_mode:
    .word 0
save_size:
    .word 0x20000
    .word patched_entrypoint
    .word write_sram_patched + 1
	.word write_eeprom_patched + 1
	.word write_flash_patched + 1

patched_entrypoint:
    mov r0, # 0x04000000
    adr r1, idle_irq_handler
    str r1, [r0, # -4]

    adrl r0, flash_save_sector
    mov r1, # 0x0e000000
    ldr r2, save_size
    add r2, r1
    mov r3, # 0x09000000
sram_init_loop:
    lsr r4, r1, # 16
    and r4, # 1
    strh r4, [r3]
    nop
    ldrb r4, [r0], # 1
    strb r4, [r1], # 1
    cmp r1, r2
    blo sram_init_loop

    ldr pc, original_entrypoint_addr


.thumb
# r0 = sector number, # r1 = source data 0x1000 bytes
write_flash_patched:
    lsl r0, # 12
	mov r2, # 0x0e
	lsl r2, # 24
	orr r0, r2
	mov r2, # 0x1
	lsl r2, # 12
	mov r3, r0
	mov r0, r1
	mov r1, r3
	
	b write_sram_patched


# r0 = src, r1 = dst, r2 = size. Check if change before writing, only install irq if change
# unoptimised as hell, but I don't care for now.
write_sram_patched:
    push {r4, r5, r6, r7}

    # Writes will never span both SRAM banks, so only needed to write once.
    mov r4, # 0x09
    lsl r4, # 24
    lsr r5, r1, # 16
    mov r6, # 1
    and r5, r6
    strh r5, [r4]

    # Disable interrupts while writing - just in case
    ldr r6, =0x04000208
    ldrh r7, [r6]
    mov r3, # 0
    strh r3, [r6]
    add r2, r0
write_sram_patched_loop:
    # Check if the each byte to write to sram is different - if it is, write it then set a flag
    ldrb r4, [r0]
    ldrb r5, [r1]
    cmp r4, r5
    beq (.+6)
    mov r3, # 1
    strb r4, [r1]
    add r0, # 1
    add r1, # 1
    cmp r0, r2
    blo write_sram_patched_loop

    # If the flag was not set, the function had no effect. Short circuit
    cmp r3, # 0
    beq write_sram_patched_exit

    # Install the chosen irq handler and initialise countdown value if needed.
    mov r1, # 0x04
    lsl r1, # 24
    sub r1, # 0x10
    mov r0, pc
    sub r0, # . + 2 - flush_mode
    ldrh r0, [r0]
    cmp r0, # 0
    bne install_keypad_irq_handler
    
    adr r0, countdown_irq_handler
    mov r2, # 101
    strh r2, [r1, # 0x0a]
    str r0, [r1, # 0x0c]
    # Set green swap as a visual indicator that the countdown has begun
    strh r2, [r1, # 0x12]
    
    b write_sram_patched_exit
    
install_keypad_irq_handler:
    adr r0, keypad_irq_handler
    strh r0, [r1, # 0x0c]

write_sram_patched_exit:
    strh r7, [r6]
    mov r0, # 0
    pop {r4, r5, r6, r7}
    bx lr

    .ltorg

# r0 = eeprom address, r1 = src data (needs byte swapping, 8 bytes)
write_eeprom_patched:
    push {r4, lr}
	mov r2, r1
	add r2, # 8
	mov r3, sp
write_eeprom_patched_byte_swap_loop:
    ldrb r4, [r1]
	add r1, # 1
	sub r3, # 1
	strb r4, [r3]
	cmp r1, r2
	bne write_eeprom_patched_byte_swap_loop
	
	mov r1, # 0x0e
	lsl r1, # 24
	lsl r0, # 3
	add r1, r0
	mov r2, # 8
	mov r0, r3
	mov sp, r3
	bl write_sram_patched
	
	add sp, # 8
	pop {r4, pc}
	

.arm
# IRQ handlers are called with 0x04000000 in r0 which is handy!
keypad_irq_handler:
    # May need to be changed to ldrh
    ldr r3, [r0, # 0x130]
    teq r3, # 0xf3
    ldrne pc, [r0, # - 12]
    b flush_during_irq

countdown_irq_handler:
    # if not vblank IF then user handler
    ldr r1, [r0, # 0x200]
    tst r1, # 0x00010000
    ldreq pc, [r0, # -12]

    # if (--counter) then user handler
    ldrh r1, [r0, # - 6]
    subs r1, # 1
    strh r1, [r0, # - 6]
    ldrne pc, [r0, # -12]

flush_during_irq:
    # countdown expired.
    # first switch back into user mode to regain significant stack space
    mov r3, # 0x9f
    msr cpsr, r3

    # save sound state then disable it
    ldrh r2, [r0, # 0x0080]
    ldrh r3, [r0, # 0x0084]
    push {r2, r3}
    strh r0, [r0, # 0x0084]

    # save DMAs state then disable them
    ldrh r3, [r0, # 0x00BA]
    push {r3}
    strh r0, [r0, # 0x00BA]
    ldrh r3, [r0, # 0x00C6]
    push {r3}
    strh r0, [r0, # 0x00C6]
    ldrh r3, [r0, # 0x00d2]
    push {r3}
    strh r0, [r0, # 0x00d2]
    ldrh r3, [r0, # 0x00de]
    push {r3}
    strh r0, [r0, # 0x00de]

    push {lr}
    
    # Try flushing for various flash chips
    adr r0, flash_save_sector
    ldr r1, save_size
    adr r2, try_22xx
    adr r3, try_22xx_end
    bl run_from_ram
    
    adr r0, flash_save_sector
    ldr r1, save_size
    adr r2, try_intel
    adr r3, try_intel_end
    bl run_from_ram

flush_sram_done:
    pop {lr}
    mov r0, #0x04000000

    # restore DMAs state
    pop {r3}
    strh r3, [r0, # 0x00de]
    pop {r3}
    strh r3, [r0, # 0x00d2]
    pop {r3}
    strh r3, [r0, # 0x00c6]
    pop {r3}
    strh r3, [r0, # 0x00ba]


    # restore sound state
    pop {r2, r3}
    strh r3, [r0, # 0x0084]
    strh r2, [r0, # 0x0080]

    # restore previous irq mode
    mov r3, # 0x92
    msr cpsr, r3

    # Disable green swap
    strh r0, [r0, # 0x02]
    adr r1, idle_irq_handler
    str r1, [r0, # - 4]

idle_irq_handler:
    ldr pc, [r0, # -12]

run_from_ram:
    push {r4, r5, lr}
    mov r4, sp
    
run_from_ram_loop:    
    ldr r5, [r3, # -4]!
    push {r5}
    cmp r2, r3
    bne run_from_ram_loop
    
    mov lr, pc
    bx sp
    
    mov sp, r4
    pop {r4, r5, lr}
    bx lr

try_22xx:
    push {r4, r5, r6, r7, r8, r9}
    mov r8, r1
    mov r1, # 0x08000000
    add r2, r1, # 0x00000aa
    add r2, # 0x00000a00
    add r3, r1, # 0x00000055
    add r3, # 0x00000500
    
    mov r4, # 0x00a9
    strh r4, [r2]
    mov r4, # 0x0056
    strh r4, [r3]
    mov r4, # 0x0090
    strh r4, [r2]
    nop
    ldrh r4, [r1, # 2]
    lsr r4, # 8
    cmp r4, # 0x22
    mov r4, # 0xf0
    strh r4, [r1]
    
    popne {r4, r5, r6, r7, r8, r9}
    bxne lr
    
    mov r4, # 0x00a9
    strh r4, [r2]
    mov r4, # 0x0056
    strh r4, [r3]
    mov r4, # 0x0080
    strh r4, [r2]
    mov r4, # 0x00a9
    strh r4, [r2]
    mov r4, # 0x0056
    strh r4, [r3]
    mov r4, # 0x0030
    strh r4, [r0]
    
    ldrsh r4, [r0]
    cmp r4, # -1
    beq (.-8)
    
    ldrsh r4, [r0]
    cmp r4, # -1
    bne (.-8)
    
    mov r4, # 0x000f0
    strh r4, [r1]
 
    mov r5, # 0x0e000000
    add r6, r5, r8
    mov r9, # 0x09000000
try_22xx_write_all_loop:
    lsr r7, r5, # 16
    and r7, # 1
    strh r7, [r9]
    ldrb r7, [r5], # 1
    ldrb r4, [r5], # 1
    orr r7, r4, LSL # 8

    mov r4, # 0x00a9
    strh r4, [r2]
    mov r4, # 0x0056
    strh r4, [r3]
    mov r4, # 0x00a0
    strh r4, [r2] 
    nop
    strh r7, [r0], # 2
    nop
    
    ldrh r4, [r0, # -2]
    cmp r4, r7
    bne (.-8)
    
    mov r4, # 0x00f0
    strh r4, [r1]
    
    cmp r5, r6
    bne try_22xx_write_all_loop
    
    mov r4, # 0x00f0
    strh r4, [r1]
    
    pop {r4, r5, r6, r7, r8, r9}
    bx lr
try_22xx_end:

try_intel:
    mov r3, r1
    mov r1, # 0x08000000
    mov r2, # 0x00FF
    strh r2, [r1]
    mov r2, #0x0090
    strh r2, [r1]
    nop
    ldrh r2, [r1, # 2]
    lsr r2, # 8
    cmp r2, # 0x0088
    mov r2, # 0x00FF
    strh r2, [r1]
    bxne lr
    
    mov r2, # 0x00ff
    strh r2, [r0]
    mov r2, # 0x0060
    strh r2, [r0]
    mov r2, # 0x00d0
    strh r2, [r0]
    mov r2, # 0x0020
    strh r2, [r0]
    mov r2, # 0x00d0
    strh r2, [r0]
    nop
    
    ldrh r2, [r0]
    tst r2, # 0x0080
    beq (.-8)
    
    mov r2, # 0x00ff
    strh r2, [r0]
    
    push {r4, r5, r6}
    mov r4, # 0x0e000000
    add r5, r4, r3
    mov r6, # 0x09000000
try_intel_write_all_loop:
    lsr r3, r4, # 16
    and r3, # 1
    strh r3, [r6]
    ldrb r3, [r4], # 1
    ldrb r2, [r4], # 1
    orr r3, r2, LSL # 8
    mov r2, # 0x0040
    strh r2, [r0]
    nop
    strh r3, [r0]
    nop
    
    ldrh r2, [r0]
    tst r2, # 0x0080
    beq (.-8)
    
    mov r2, # 0x00ff
    strh r2, [r0], # 2
    cmp r4, r5
    blo try_intel_write_all_loop
    
    pop {r4, r5, r6}
    
    bx lr
try_intel_end:

.ascii "<3 from Maniac"

# patcher program will have to ensure this is actually aligned enough
# This alignment was chosen so the assembler? linker? doesn't pad more than needed.
.balign 4
    flash_save_sector:
