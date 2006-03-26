<?php
/*
 * NeWs.php:
 * General purpose functions specific to NeWs.  This must
 * be included first by all scripts to enable error logging.
 * 
 * Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
 * Email: louise.crow@gmail.com; WWW: http://www.mysociety.org
 *
 * $Id: news.php,v 1.1 2006-03-26 13:20:31 louise Exp $
 * 
 */

require_once '../../phplib/error.php';
require_once '../../phplib/utility.php';
require_once 'page.php';


/* news_handle_error NUMBER MESSAGE
 * Display a PHP error message to the user. */
function news_handle_error($num, $message, $file, $line, $context) {
    if (OPTION_NEWS_STAGING) {
        page_header(_("Sorry! Something's gone wrong."));
        print("<strong>$message</strong> in $file:$line");
        page_footer();
    } else {
        /* Nuke any existing page output to display the error message. */
        /* Message will be in log file, don't display it for cleanliness */
        $err = 'Please try again later, or <a href="mailto:team@mysociety.org">email us</a> for help resolving the problem.';
        if ($num & E_USER_ERROR) {
            $err = "<p><em>$message</em></p> $err";
        }
        news_show_error($err);
    }
}
err_set_handler_display('news_handle_error');

/* news_show_error MESSAGE
 * General purpose eror display. */
function news_show_error($message) {
    page_header(_("Sorry! Something's gone wrong."), array('override'=>true));
    print _('<h2>Sorry!  Something\'s gone wrong.</h2>') .
        "\n<p>" . $message . '</p>';
    page_footer();
}

?>
