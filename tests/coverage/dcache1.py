####################
# dcache1.py
#
# Written: avercruysse@hmc.edu 18 April 2023
#
# Purpose: Test Coverage for D$
#          (For each way, trigger a CacheDataMem write enable while chip enable is low)
#
# A component of the CORE-V-WALLY configurable RISC-V project.
#
# Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
#
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
# except in compliance with the License, or, at your option, the Apache License version 2.0. You
# may obtain a copy of the License at
#
# https://solderpad.org/licenses/SHL-2.1/
#
# Unless required by applicable law or agreed to in writing, any work distributed under the
# License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing permissions
# and limitations under the License.
################################################

import os

test_name = "dcache1.S"
dcache_num_ways = 4
dcache_way_size_in_bytes = 4096
# warning i$ line size is not currently parameterized.

# arbitrary start location of where I send stores to.
mem_start_addr = 0x80100000

# pointer to the start of unused memory (strictly increasing)
mem_addr = mem_start_addr


def wl(line="", comment=None, fname=test_name):
    with open(fname, "a") as f:
        instr = False if (":" in line or
                          ".align" in line or
                          "# include" in line) else True
        indent = 6 if instr else 0
        comment = "// " + comment if comment is not None else ""
        to_write = " " * indent + line + comment + "\n"
        f.write(to_write)


def write_repro_instrs():
    """
    Assumes that the store location has been fetched to d$, and is in t0.
    """
    for i in range(16): # write a whole cache set.
        if i == 12:
            wl('sd zero, 0(t0)') # D$ write to set PCM = PCF + 8 for proper alignment (stallD will happen).
        elif i == 13:
            # the store in question happens here, at adresses 0x34, 0x74
            wl('sd zero, 0(t0)') # it should hit this time
        else:
            # can't be a NOP or anything else that is encoded as compressed.
            # this is because the branch predictor will use the wrong address
            # so the IFU cache miss will come late.
            wl('.word 0x00000013') # addi x0, x0, 0 (canonical NOP, uncompressed).

if __name__ == "__main__":
    if os.path.exists(test_name):
        os.remove(test_name)
        # os.rename(test_name, test_name + ".old")
    wl(comment="This file is generated by dcache1.py (run that script manually)")
    wl('#include "WALLY-init-lib.h"')
    wl('main:')

    # excercise all 4 D$ ways. If they're not all full, it uses the first empty.
    # So we are sure all 4 ways are exercised.
    for i in range(dcache_num_ways):
        wl(comment=f"start way test #{i+1}")
        wl(f'li t0, {hex(mem_addr)}')
        wl('.align 6')                # start at i$ set boundary. 6 lsb bits are zero.
        wl(comment=f"i$ boundary, way test #{i+1}")
        write_repro_instrs()
        mem_addr += dcache_way_size_in_bytes  # so that we excercise a new D$ way.

    wl("j done")
