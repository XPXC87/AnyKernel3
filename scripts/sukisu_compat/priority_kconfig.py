#!/usr/bin/env python3
"""Add the SUSFS Priority UID Filter Kconfig entry to older SukiSU trees."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
symbol = "config KSU_SUSFS_PRIORITY_UID_FILTER"
if symbol in source:
    print("SukiSU Kconfig: Priority UID Filter already defined")
    sys.exit(0)
anchor = "config KSU_SUSFS_SUS_MAP"
if anchor not in source:
    sys.exit("SukiSU Kconfig SUSFS section missing; cannot add Priority UID Filter")
config = (
    'config KSU_SUSFS_PRIORITY_UID_FILTER\n'
    '\tbool "Enable SUSFS priority UID filter"\n'
    '\tdepends on KSU_SUSFS\n'
    '\tdefault y\n'
    '\thelp\n'
    '\t  Enable SUSFS priority UID filtering used by current SukiSU.\n\n'
)
path.write_text(source.replace(anchor, config + anchor, 1))
print("SukiSU Kconfig: added SUSFS Priority UID Filter option")
