#!/bin/sh
#
# eveld.sh:
# FreeBSD-style rc.d script for EvEl mail daemon.
#
# $Id: eveld.sh,v 1.1 2005-04-05 17:11:04 chris Exp $
#

# PROVIDE: eveld
# REQUIRE: LOGIN
# BEFORE:  securelevel
# KEYWORD: FreeBSD shutdown

. "/etc/rc.subr"

name="eveld"
rcvar=`set_rcvar`

command="/data/vhost/services.mysociety.org/mysociety/services/EvEl/bin/eveld"
command_args=""
pidfile="/data/vhost/services.mysociety.org/$name.pid"

# read configuration and set defaults
load_rc_config "$name"

: ${eveld_user="msservices"}
: ${eveld_chdir="/data/vhost/services.mysociety.org/mysociety/services/EvEl/bin"}
: ${command_interpreter="/usr/bin/perl"}
run_rc_command "$1"
