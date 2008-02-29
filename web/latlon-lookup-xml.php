<?
/*
 * latlon-lookup-xml.php:
 * XML interface to postcode lat/lon lookup.
 * 
 * Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
 * Email: francis@mysociety.org. WWW: http://www.mysociety.org
 *
 * $Id: latlon-lookup-xml.php,v 1.1 2008-02-29 10:22:36 francis Exp $
 * 
 */
require_once "../conf/general";
require_once "../../phplib/utility.php";
require_once "../../phplib/mapit.php";
require_once '../../phplib/dadem.php';

$pc = get_http_var('input_postcode');
$partial = get_http_var('partial') ? 1 : null;

header("Content-Type: text/xml");
header('Cache-Control: max-age=3600');
?>
<MYSOCIETY>
<?

$loc = '';
if ($pc != "") {
    $loc = mapit_get_location($pc, $partial);
    if (!rabx_is_error($loc)) {
        foreach ($loc as $key => $value) {
            $uckey = strtoupper($key);
            print "<$uckey>";
            print $value;
            print "</$uckey>\n";
        }
    } else {
            print "<ERROR>";
            print htmlspecialchars($loc->text);
            print "</ERROR>\n";
    }
}

?>
</MYSOCIETY>
