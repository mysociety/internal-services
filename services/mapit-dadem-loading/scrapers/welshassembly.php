#!/usr/local/bin/php -q
<?php
/**
 * Welsh Assembly members screenscraper for mySociety
 *
 * @copyright Copyright (c) 2011 UK Citizens Online Democracy. All rights reserved.
 * Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
 *
 */

$f = file_get_contents('http://business.senedd.wales/mgCommitteeMailingList.aspx?ID=0');
preg_match_all('#
    <h3[ ]class="mgSubSubTitleTxt">(.*?)</h3>
    \s*<p>(.*?)</p>
    \s*<p>(.*?)</p>
    \s*<p><a[ ]+href="mailto:(.*?)"[ ]+title=".*?">.*?</a>
    \s*</p>
#x', $f, $m, PREG_SET_ORDER);
$out = array();
foreach ($m as $row) {
    $name = preg_replace('#\s+#', ' ', $row[1]);
    $out[$name]['name'] = $name;
    $out[$name]['email'] = $row[4];
}

# 58 as a couple might have resigned
if (count($out) < 58) {
    print "Expected to get 60 Welsh Assembly members, but got " . count($out) . "\n";
    exit(1);
}

$f = file_get_contents('http://business.senedd.wales/mgMemberIndex.aspx');
$f = str_replace('<!--<p></p>-->', '', $f);
$f = preg_replace('#<!--\s*Tel:\s*-->#', '', $f);
preg_match_all('#
    <li>
    \s*<a[ ]*href="mgUserInfo\.aspx\?UID=(.*?)"[ ]*>
    \s*<img[ ]*class="mgCouncillorImages"[ ]*src="(.*?)"
    [^>]*><br[ ]/>(.*?)</a>
    \s*<p>(.*?)</p>
    \s*<p>(.*?)</p>
    (?: \s*<p>(.*?)</p> )?
    \s*</li>
#x', $f, $m, PREG_SET_ORDER);
foreach ($m as $r) {
    list( $dummy, $id, $img, $name, $const, $party, $min) = $r;
    $out[$name]['img'] = $img;
    $out[$name]['party'] = party_lookup($party);
    $const = str_replace(array('Anglesey', 'Ynys Mon', 'Ynys M&#244;n'), "Ynys M\xc3\xb4n", $const);
    $const = preg_replace('#^\((.*)\)$#', '$1', $const);
    $out[$name]['const'] = $const;
}

function by_const($a, $b) {
    $aa = strpos($a['const'], 'Wales');
    $bb = strpos($b['const'], 'Wales');
    if ($aa && $bb) {
        if (strcmp($a['const'], $b['const'])) {
            return strcmp($a['const'], $b['const']);
        } else {
            return strcmp($a['name'], $b['name']);
        }
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
    $name = html_entity_decode($name, ENT_COMPAT | ENT_HTML401, "utf-8");
    $name = preg_replace('# MS$#', '', $name);
    preg_match('#^(.*) (.*?)$#', $name, $m);
    list($first, $last) = array($m[1], $m[2]);
    $img = $arr['img'] ? "http://www.senedd.assemblywales.org/$arr[img]" : "";
    print "$first,$last,$arr[const],$arr[party],$arr[email],,$img\n";
}

function party_lookup($p) {
    if ($p == 'Labour Party') return 'Labour';
    if ($p == 'Welsh Labour') return 'Labour';
    if ($p == 'Welsh Labour and Co-operative Party') return 'Labour';
    elseif ($p == 'Welsh Conservative Party') return 'Conservative';
    elseif ($p == 'Welsh Liberal Democrats') return 'Liberal Democrat';
    elseif ($p == 'Independant') return 'Independent';
    elseif ($p == 'Independent Plaid Cymru Member') return 'Plaid Cymru'; # Bethan Jenkins
    else return $p;
}
