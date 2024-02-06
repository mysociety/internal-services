#!/usr/bin/env python3
# -*- coding: latin-1 -*-

# Converts triple of (name, constituency, date) into parlparse person id.
# Reads lines from standard input, each line having the triple hash-separated.
# Outputs the person ids, one per line.

import sys
import os

# Check this out from the parlparse project:
# git clone https://github.com/mysociety/parlparse
os.chdir("../../../../parlparse/pyscraper")
sys.path.append(".")
import re
from resolvemembernames import memberList

while 1:
    sys.stdin.flush()
    line = sys.stdin.readline()
    if not line:
        break

    line = line.decode("utf-8")
    name, cons, date_today = line.split("#")

    id, canonname, canoncons = memberList.matchfullnamecons(name, cons, date_today)
    if not id:
        print("failed to match %s (%s) %s" % (name, cons, date_today), file=sys.stderr)

    print(id)
    sys.stdout.flush()
