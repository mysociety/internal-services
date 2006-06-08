<?
/*
 * mp-lookup-xml.php:
 * XML interface to postcode lookup.
 * 
 * Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
 * Email: matthew@mysociety.org. WWW: http://www.mysociety.org
 *
 * $Id: mp-lookup-xml.php,v 1.2 2006-06-08 10:15:37 matthew Exp $
 * 
 */
require_once "../conf/general";
require_once "../../phplib/utility.php";
require_once "../../phplib/mapit.php";
require_once '../../phplib/dadem.php';

$pc = get_http_var('input_postcode');

header("Content-Type: text/xml");
header('Cache-Control: max-age=3600');
?>
<FAXYOURMP>
<?

$voting_areas = '';
if ($pc != "") {
    $voting_areas = mapit_get_voting_areas($pc);
    if (!rabx_is_error($voting_areas)) {
        $va_info = mapit_get_voting_areas_info(array_values($voting_areas));
        if (!rabx_is_error($va_info)) {
            $type_reps = array();
            foreach ($va_info as $id => $data) {
                if ($data['type'] == 'WMC') {
                    $type_reps[] = $data['name'];
                }
            }
            if (count($type_reps) == 1) {
                print "<CONSTITUENCY_NAME>";
                print $type_reps[0];
                print "</CONSTITUENCY_NAME>\n";
            }
        } else {
            print "<ERROR>";
            print htmlspecialchars($va_info->text);
            print "</ERROR>\n";
        }
    } else {
            print "<ERROR>";
            print htmlspecialchars($voting_areas->text);
            print "</ERROR>\n";
    }
}

?>
</FAXYOURMP>
