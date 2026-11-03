/* MCU binary SHA256: f9d8d8d6782ef4bd77c028b10d15e279aa00a58f211b93328e1699e85cf731cb */
/* The assembly embeds the qualified MCU binary without recompiling its logic.
 * Flash bytes are checked after every Keil build by verify_output.ps1. */
__asm(
 ".section .qualified_image,\"ax\",%progbits\n"
 ".balign 4\n"
 ".global qualified_firmware_start\n"
 "qualified_firmware_start:\n"
 ".incbin \"../../../../bin/velocity_keyboard/velocity_keyboard.bin\"\n"
 ".global Reset_Handler\n"
 ".type Reset_Handler,%function\n"
 ".thumb_set Reset_Handler, qualified_firmware_start + 304\n"
);
