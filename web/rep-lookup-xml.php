<?
/*
 * rep-lookup-xml.php:
 * XML interface to postcode lookup.
 * 
 * Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
 * Email: matthew@mysociety.org. WWW: http://www.mysociety.org
 *
 * $Id: rep-lookup-xml.php,v 1.1 2008-06-30 15:12:55 matthew Exp $
 * 
 */
require_once "../conf/general";
require_once "../../phplib/utility.php";
require_once "../../phplib/mapit.php";
require_once '../../phplib/dadem.php';

header("Content-Type: text/xml");
header('Cache-Control: max-age=3600');

$pc = get_http_var('pc');
if (!$pc)
    output();

$voting_areas = mapit_get_voting_areas($pc);
if (rabx_is_error($voting_areas))
    output(error($voting_areas->text));

$va_info = mapit_get_voting_areas_info(array_values($voting_areas));
if (rabx_is_error($va_info))
    output(error($va_info->text));

$out = '';
foreach ($va_info as $id => $data) {
    $out .=  '<name type="', $data['type'], '">', $data['name'], "</name>\n";
}
output($out);

function error($s) {
    return '<error>' . htmlspecialchars($s) . "</error>\n";
}

function output($s = '') {
    echo '<areas>', $s, '</areas>';
    exit;
}

