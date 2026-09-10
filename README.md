# CHIP-8 emulator, assembler, and disassembler

A Zig 0.16.0 CHIP-8 toolkit with an SDL3 emulator, an assembler for writing `.ch8` ROMs,
and a disassembler for inspecting them.

## Build and run

Install SDL3 development headers and libraries (SDL 3.2 or newer). On macOS with Homebrew:

```sh
brew install sdl3
zig build emulate -- path/to/rom.ch8
```

On systems with SDL3 in the standard compiler/pkg-config search paths:

```sh
zig build emulate -- path/to/rom.ch8
```

Native macOS builds automatically detect SDL3 in the standard Apple Silicon or Intel Homebrew location.
For a custom SDL installation, pass `-Dsdl-prefix=/path/to/installation`.
Each named build step installs its executable in `zig-out/bin`. Arguments after `--` also run it:

```text
Build step                Installed executable
zig build emulate         zig-out/bin/emulate
zig build asm             zig-out/bin/chip8-asm
zig build disasm          zig-out/bin/chip8-disasm
```

After building, the executables can also be run directly:

```sh
./zig-out/bin/emulate path/to/rom.ch8
./zig-out/bin/chip8-asm programs/hello.asm
./zig-out/bin/chip8-disasm roms/hello.ch8
```

ROMs are not bundled. ROMs must be nonempty and fit in the 3,584 bytes available at address `0x200`.

## Controls

The physical keyboard layout maps to the CHIP-8 hexadecimal keypad:

```text
Keyboard       CHIP-8
1 2 3 4        1 2 3 C
Q W E R        4 5 6 D
A S D F        7 8 9 E
Z X C V        A 0 B F
```

This represents the original 16-button hexadecimal keypad: the digits `0` through `9` plus
`A` through `F`. A game reads one of these CHIP-8 key values; the host key at the left sends that
value to the game.

- Space: pause/resume.
- Backspace: reload the ROM and reset the machine.
- Escape or close window: quit.

Held keys stay pressed until released. Losing focus suspends execution and clears input;
regaining focus resumes unless manually paused. The window is resizable, with integer-scaled pixels
and letterboxing. The CPU runs at 700 instructions/second; timers tick at 60 Hz independently
of rendering, including while a ROM waits for a key. Pausing also pauses timers and silences audio.
`FX0A` ignores keys held before its wait begins and resumes on a new key-down event. A quick tap is
therefore registered even when it is released before the next screen refresh.
If no audio device can be opened, the emulator logs a warning and continues without sound.

## Code layout

- `src/main.zig`: command-line arguments and ROM file loading.
- `src/chip8.zig`: machine state, instructions, fonts, and core tests.
- `src/runtime.zig`: CPU/timer scheduling and timing tests.
- `src/frontend.zig`: SDL lifecycle, events, display, and audio.
- `src/asm.zig`: assembly parsing, label resolution, instruction encoding, and tests.
- `src/disasm.zig`: ROM disassembly.
- `programs/`: assembly source programs.
- `roms/`: CHIP-8 ROM binaries that can be loaded by the emulator.

## Assemble a program

Write assembly in `programs/`, then assemble and run it:

```sh
zig build asm -- programs/hello.asm
zig build emulate -- roms/hello.ch8
```

The assembler writes `roms/<source-name>.ch8`, creating `roms` if needed and replacing an existing
ROM with the same name. Paths are relative to the working directory when running the assembler
directly. Assembly errors include the source path and line number and leave existing output alone.
The assembler does not require SDL.

```asm
    CLS
    LD_BYTE V0, 28
    LD_BYTE V1, 13
    LD_I sprite
    DRW V0, V1, 3
loop:
    JP loop
sprite:
    .byte 0b11111111, 0b10000001, 0b11111111
```

- One instruction per line, with comma-separated operands. Mnemonics and registers are case-insensitive.
- Every opcode has one distinct mnemonic; operand types do not change which opcode a mnemonic means.
- Labels use `name:` and resolve to addresses starting at `0x200`. Forward references work. Label names
  are case-sensitive and use letters, digits, and underscores, starting with a letter or underscore.
- Numbers are decimal, hexadecimal (`0xFF`), or binary (`0b10000000`).
- `;` starts a comment. Blank lines are ignored.
- `.byte` emits one or more bytes for sprite data; `DATA` emits a raw 16-bit word, high byte first.
- Instructions must start on even addresses. Add a padding `.byte 0` if code follows an odd number
  of data bytes. Programs must contain 1–3,584 bytes.

The syntax follows the mnemonics in `disasm.zig` (without its address and raw-opcode columns):

| Instruction | Opcode | Operands |
| --- | --- | --- |
| `CLS`, `RET` | `00E0`, `00EE` | None |
| `SYS`, `JP`, `CALL` | `0NNN`, `1NNN`, `2NNN` | Address or label |
| `SE_BYTE`, `SNE_BYTE` | `3XNN`, `4XNN` | `Vx, byte` |
| `SE_REG` | `5XY0` | `Vx, Vy` |
| `LD_BYTE`, `ADD_BYTE` | `6XNN`, `7XNN` | `Vx, byte` |
| `LD_REG`, `OR`, `AND`, `XOR` | `8XY0`–`8XY3` | `Vx, Vy` |
| `ADD_REG`, `SUB` | `8XY4`, `8XY5` | `Vx, Vy` |
| `SHR` | `8XY6` | `Vx` |
| `SUBN` | `8XY7` | `Vx, Vy` |
| `SHL` | `8XYE` | `Vx` |
| `SNE_REG` | `9XY0` | `Vx, Vy` |
| `LD_I`, `JP_V0` | `ANNN`, `BNNN` | Address or label |
| `RND` | `CXNN` | `Vx, mask` |
| `DRW` | `DXYN` | `Vx, Vy, height` (0–15) |
| `SKP`, `SKNP` | `EX9E`, `EXA1` | `Vx` |
| `GET_DT`, `WAIT_KEY` | `FX07`, `FX0A` | `Vx` |
| `SET_DT`, `SET_ST` | `FX15`, `FX18` | `Vx` |
| `ADD_I`, `LD_FONT`, `BCD` | `FX1E`, `FX29`, `FX33` | `Vx` |
| `STORE`, `LOAD` | `FX55`, `FX65` | `Vx` (registers V0 through Vx) |

## Disassemble a ROM

Print the ROM as CHIP-8 assembly-style instructions. File offset `0` is displayed as CHIP-8 address
`0x200`, the address where ROMs are loaded:

```sh
zig build disasm -- roms/6-keypad.ch8
```

The output includes the address, raw opcode, and decoded mnemonic. It traces code reachable from
`0x200`; unreachable words, such as sprite data stored after the program, are shown as `DATA`.
Computed jumps through `Bnnn` cannot be resolved statically, so code reachable only through one of
those jumps is also shown as `DATA`.

The core retains its existing CHIP-8 opcode behavior and compatibility quirks; this is not a
Super-CHIP/XO-CHIP emulator. Malformed ROM instructions can still trigger core bounds checks.
