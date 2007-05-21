#!/usr/local/bin/php -q
<?php
/**
 * Welsh Assembly members screenscraper for mySociety
 *
 * @copyright Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
 * Email: richard@phase.org; WWW: http://www.mysociety.org/
 *
 */

/* Completely changed mid May 2007 to deal with new set-up to get some people back up */

$f = file_get_contents('https://www.assemblywales.org/memhome/mem-contact/eform-email-a-member.htm');
preg_match_all('#<option value="(.*?)" >(.*?)</option>#', $f, $m, PREG_SET_ORDER);
$out = array();
foreach ($m as $row) {
    $name = str_replace('  ', ' ', $row[2]);
    $out[$name]['email'] = $row[1];
}

for ($region=1; $region<=5; $region++) {
    $f = file_get_contents("http://www.assemblywales.org/memhome/member-search-results.htm?region=$region");
    preg_match_all('#<div class="member_card_images">\s*<a[^>]*><img src="(.*?)".*?<p><a[^>]*>(.*?)</a>.*?<p class="party_title">(.*?)</p>\s*<p>(.*?)</p>#s', $f, $m, PREG_SET_ORDER);
    foreach ($m as $r) {
        $name = $r[2];
        $out[$name]['img'] = $r[1];
        $out[$name]['party'] = party_lookup($r[3]);
        $out[$name]['const'] = $r[4];
    }
}

if (count($out) != 60) {
    err("Expected to get 60 Welsh Assembly members, but got $count");
    exit(1);
}

function by_const($a, $b) {
    $aa = strpos($a['const'], 'Wales');
    $bb = strpos($b['const'], 'Wales');
    if ($aa && $bb) {
        return strcmp($a['const'], $b['const']);
    } elseif ($aa) {
        return 1;
    } elseif ($bb) {
        return -1;
    } else {
        return strcmp($a['const'], $b['const']);
    }
}

uasort($out, 'by_const');
print "First,Last,Constituency,Party,Email,Fax,Image\n";
foreach ($out as $name => $arr) {
    # Aberconwy, Arfon, and Dwyfor Meirionnydd are not yet in our database
    if (in_array($arr['const'], array('Aberconwy', 'Arfon', 'Dwyfor Meirionnydd')))
        continue;
    preg_match('#^(.*) (.*?)$#', $name, $m);
    list($first, $last) = array($m[1], $m[2]);
    print "$first,$last,$arr[const],$arr[party],$arr[email],,http://www.assemblywales.org/memhome/$arr[img]\n";
}

function party_lookup($p) {
    if ($p == 'Labour Party') return 'Labour';
    elseif ($p == 'Welsh Conservative Party') return 'Conservative';
    elseif ($p == 'Independant') return 'Independent';
    else return $p;
}
