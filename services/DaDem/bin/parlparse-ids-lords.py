#!/usr/bin/env python3
# -*- coding: latin-1 -*-

# Converts triple of (name, "House of Lords", date) into parlparse person id.
# Reads lines from standard input, each line having the triple hash-separated.
# Outputs the person ids, one per line.

import sys
import os
import traceback

# Check this out from the parlparse project:
# git clone https://github.com/mysociety/parlparse
os.chdir("../../../../parlparse/pyscraper")
sys.path.append(".")
import re
from lords.resolvenames import lordsList
from resolvemembernames import memberList
from contextexception import ContextException

while 1:
    sys.stdin.flush()
    line = sys.stdin.readline()
    if not line:
        break

    line = line.decode("utf-8")
    name, cons, date_today = line.split("#")

    id = None
    try:
        id = lordsList.GetLordIDfname(name, None, date_today) 
    except ContextException as ce:
        traceback.print_exc()
    if not id:
        print("failed to match lord %s %s" % (name, date_today), file=sys.stderr)
        print()
    else:
        print(id)
    sys.stdout.flush()

