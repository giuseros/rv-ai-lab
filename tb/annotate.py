#!/usr/bin/env python3
"""Format a retire log and add the disassembly of each instruction.

Reads the simulator's stdout on stdin, keeps only the "RETIRE ..." lines that
retire_log (tb/tb_lib.v) prints, and looks each PC up in the program's ELF.

    vvp build/soc.vvp +trace=p_mem | python3 tb/annotate.py build/p_mem.elf

(`make trace PROG=p_mem` does exactly that.)

With --all, lines that are not retire records (the program's console output,
the simulation's summary) are passed through unchanged.
"""
import re
import subprocess
import sys


def disassembly(elf):
    """Map pc -> 'mnemonic operands' using objdump."""
    out = subprocess.run(
        ["riscv64-unknown-elf-objdump", "-d", "-M", "numeric", elf],
        capture_output=True, text=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)$", line)
        if m:
            text = m.group(2).split("#")[0].strip()      # drop objdump's comments
            table[int(m.group(1), 16)] = re.sub(r"\s+", " ", text)
    return table


def main():
    args = sys.argv[1:]
    passthrough = "--all" in args
    args = [a for a in args if a != "--all"]
    if len(args) != 1:
        sys.exit(__doc__)
    dis = disassembly(args[0])

    print(f"{'#':>4}  {'pc':8}  {'instr':8}  {'instruction':26}  effect")
    for line in sys.stdin:
        # A record can share a line with console output that the simulation
        # echoes (e.g. "hRETIRE 5 ..."), so look for it anywhere in the line.
        pos = line.find("RETIRE ")
        if pos < 0:
            if passthrough and "VCD info" not in line:
                print(line, end="")
            continue
        fields = line[pos:].split()
        if fields[1] == "halt":
            n, cycles = int(fields[2]), int(fields[3])
            print(f"      (halted: {n} instructions in {cycles} cycles, CPI {cycles / n:.2f})")
            break
        n, pc, instr = fields[1], fields[2], fields[3]
        effect = " ".join(fields[4:])
        # a byte stored to CONSOLE_ADDR (rtl/soc_map.vh) is a printed character
        m = re.fullmatch(r"mem8\[10000000\] <- ([0-9a-f]{2})", effect)
        if m:
            effect += "   console " + repr(chr(int(m.group(1), 16)))
        text = dis.get(int(pc, 16), "?")
        print(f"{n:>4}  {pc}  {instr}  {text:26}  {effect}")


if __name__ == "__main__":
    main()
