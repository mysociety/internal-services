<?
/*
 * rep-lookup-xml.php:
 * XML interface to postcode lookup.
 * 
 * Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
 * Email: matthew@mysociety.org. WWW: http://www.mysociety.org
 *
 * $Id: rep-lookup-xml.php,v 1.4 2010-04-13 13:24:23 matthew Exp $
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

# Magic Number 12 means pre-2010 constituencies will be returned.
$voting_areas = mapit_get_voting_areas($pc, 12);
if (rabx_is_error($voting_areas))
    output(error($voting_areas->text));

$va_info = mapit_get_voting_areas_info(array_values($voting_areas));
if (rabx_is_error($va_info))
    output(error($va_info->text));

$out = '';
foreach ($va_info as $id => $data) {
    $out .= '<name type="' . $data['type'] . '">' . htmlspecialchars($data['name']) . "</name>\n";
}
output($out);

function error($s) {
    return '<error>' . htmlspecialchars($s) . "</error>\n";
}

function output($s = '') {
    echo '<areas>', $s, '</areas>';
    exit;
}

