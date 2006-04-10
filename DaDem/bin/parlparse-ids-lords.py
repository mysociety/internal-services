#!/usr/bin/env python2.4
# -*- coding: latin-1 -*-
# $Id: parlparse-ids-lords.py,v 1.1 2006-04-10 11:33:32 francis Exp $

# Converts triple of (name, "House of Lords", date) into parlparse person id.
# Reads lines from standard input, each line having the triple hash-separated.
# Outputs the person ids, one per line.

import sys
import os

# Check this out from the ukparse project using Subversion:
# svn co https://scm.kforge.net/svn/ukparse/trunk/parlparse
os.chdir("../../../../parlparse/pyscraper")
sys.path.append(".")
sys.path.append("lords")
import re
from resolvelordsnames import lordsList
from resolvemembernames import memberList

while 1:
    sys.stdin.flush()
    line = sys.stdin.readline()
    if not line:
        break

    line = line.decode("utf-8")
    name, cons, date_today = line.split("#")

    id = lordsList.GetLordIDfname(name, None, date_today) 
    if not id:
        print >>sys.stderr, "failed to match lord %s %s" % (name, date_today)

    person_id = memberList.membertoperson(id)
    print person_id
    sys.stdout.flush()

