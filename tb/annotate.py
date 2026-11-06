#!/usr/bin/env python3
"""Format a retire log and add the disassembly of each instruction.

Reads the simulator's stdout on stdin, keeps only the "RETIRE ..." lines that
tb/cpu_tb.v's retire_log prints, and looks each PC up in the program's ELF.

    vvp build/cpu.vvp +trace=p_mem | python3 tb/annotate.py build/p_mem.elf

(`make trace PROG=p_mem` does exactly that.)
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
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    dis = disassembly(sys.argv[1])

    print(f"{'#':>4}  {'pc':8}  {'instr':8}  {'instruction':26}  effect")
    for line in sys.stdin:
        if not line.startswith("RETIRE "):
            continue
        fields = line.split()
        if fields[1] == "halt":
            n, cycles = int(fields[2]), int(fields[3])
            print(f"      (halted: {n} instructions in {cycles} cycles, CPI {cycles / n:.2f})")
            break
        n, pc, instr = fields[1], fields[2], fields[3]
        effect = " ".join(fields[4:])
        text = dis.get(int(pc, 16), "?")
        print(f"{n:>4}  {pc}  {instr}  {text:26}  {effect}")


if __name__ == "__main__":
    main()
