#!/usr/bin/env python2.4
# -*- coding: latin-1 -*-
# $Id: parlparse-ids.py,v 1.1 2006-02-15 08:39:03 francis Exp $

# Converts triple of (name, constituency, date) into parlparse person id.
# Reads lines from standard input, each line having the triple hash-separated.
# Outputs the person ids, one per line.

import sys
import os

# Check this out from the ukparse project using Subversion:
# svn co https://scm.kforge.net/svn/ukparse/trunk/parlparse
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
        print >>sys.stderr, "failed to match %s (%s) %s" % (name, cons, date_today)

    person_id = memberList.membertoperson(id)
    print person_id
    sys.stdout.flush()
