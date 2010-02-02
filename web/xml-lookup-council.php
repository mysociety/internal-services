<?
/*
 * xml-lookup-council.php:
 * XML interface to postcode lookup.
 * 
 * Copyright (c) 2010 UK Citizens Online Democracy. All rights reserved.
 * Email: matthew@mysociety.org. WWW: http://www.mysociety.org
 *
 * $Id: xml-lookup-council.php,v 1.1 2010-02-02 14:35:48 matthew Exp $
 * 
 */
require_once "../conf/general";
require_once "../../phplib/utility.php";
require_once "../../phplib/mapit.php";
require_once '../../phplib/votingarea.php';

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

$lookup = array();
foreach ($va_info as $id => $data) {
    $lookup[$data['type']] = $data;
}

$out = '';
foreach ($lookup as $type => $data) {
    $extra = '';
    if ($type == 'DIW') $extra = ' type="district"';
    if ($type == 'CED') $extra = ' type="county"';
    if (in_array($type, $va_council_child_types)) {
        $parent = $lookup[$va_inside[$type]];
        $out .= '<ward' . $extra . '>' . htmlspecialchars($data['name']) . "</ward>\n";
        $out .= '<council' . $extra . '>' . htmlspecialchars($parent['name']) . "</council>\n";
    }
}
output($out);

function error($s) {
    return '<error>' . htmlspecialchars($s) . "</error>\n";
}

function output($s = '') {
    echo "<areas>\n", $s, "</areas>\n";
    exit;
}

