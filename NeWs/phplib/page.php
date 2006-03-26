<?
// page.php:
// Header, footer and other layout parts for pages.
//
// Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
// Email: louise.crow@gmail.com. WWW: http://www.mysociety.org
//
// $Id: page.php,v 1.1 2006-03-26 13:20:31 louise Exp $


/* page_header TITLE [PARAMS]
 * Print top part of HTML page, with the given TITLE. This prints up to the
 * start of the "content" <div>.  */
function page_header($title='', $params = array()) {
    static $header_outputted = 0;
    if ($header_outputted && !array_key_exists('override', $params)) {
        return;
    }
    header('Content-Type: text/html; charset=utf-8');
    $header_outputted = 1;
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title><?
    if ($title)
        print htmlspecialchars($title);
?></title>
</head>
<body>
<div id="content">
<?
}

/* page_footer PARAMS
 * Print bottom of HTML page. This closes the "content" <div>.  */
function page_footer($params = array()) {
?>
</div>
<p id="footer">Built by <a href="http://www.mysociety.org/">mySociety</a>
</body>
</html>
<?  }
?>
