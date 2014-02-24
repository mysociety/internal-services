#!/usr/local/bin/php -q
<?php
/**
 * European Parliament (UK site) screenscraper for MySociety
 * Copyright (c) 2012 UK Citizens Online Democracy. All rights reserved.
 *
 */

$host = 'http://www.europarl.org.uk';
$base_path = '/en/your_meps/list-meps-by-region';
$regions_url = "$host$base_path.html";

$short_opts = '';
$long_opts = array();
require_once '../../../phplib/phpcli.php';

define('MEP_DEBUG', false); // true or false
define('MEP_CACHE', true); // true or false
define('MEP_CACHE_DIR', 'cache'); // absolute or relative

//How many members per region should we expect?
$expectmembers = array(
    'East Midlands' => 5,
    'Eastern' => 7,
    'London' => 8,
    'North East' => 3,
    'North West' => 8,
    'Northern Ireland' => 3,
    'Scotland' => 6,
    'South East' => 10,
    'South West' => 6,
    'Wales' => 4,
    'West Midlands' => 7,
    'Yorkshire and the Humber' => 6
);

$honorifics = array( 'Ms', 'Mrs', 'Rt. Hon. Sir', 'Mr', 'Dr', 'Baroness', );

print "First,Last,Constituency,Party,Email,Fax,Image\n";
//"Mike","Tuffrey","Proportionally Elected Member","Liberal Democrat","mike.tuffrey@london.gov.uk",""

//Get the base file
$regions_data = cached_file_get_contents($regions_url);
preg_match_all('#href=" *(' . $base_path . '/[^";]*)[^"]*">(?:<span>)* *(.*?) *(?:</span>)*</a>#', $regions_data, $matches, PREG_SET_ORDER);

$regionurls = array();
foreach ($matches as $match) {
    $region = str_replace('&amp;', 'and', $match[2]);
    $region = str_replace('and Humber', 'and the Humber', $region);
    $regionurls[$region] = $host . $match[1];
}

$mepsfound = array();
$members = array();
foreach ($regionurls as $region => $regionurl) {
    $meplist_data = cached_file_get_contents($regionurl);
    $meplist_data = preg_replace("/\s+/", ' ', $meplist_data);
    $meplist_data = preg_replace('#<h2 [^>]* class="subtitle">Committee\(s\):?</h2>#', '<h3 class="subtitle">Committee(s)</h3>', $meplist_data);
    $mepsfound[$region] = 0;

    preg_match_all('#<h2[ ][^>]*[ ]class="subtitle">\s*(.*?)\s*</h2>.*?
        <img[ ]src="([^"]*)\?hash=[0-9]+".*?
        (?:Telephone|Tel):\s*(.*?)\s*(?:UK[ ]Office|EU[ ]Office|<br).*?
        (?:Fax:\s*(.*?)\s*(?:UK[ ]Office|EU[ ]Office|<br).*?)?
        Email:\s*(?:<a[ ]class="[^"]*"[ ]href="mailto:([^"]*)">)?.*?
        National[ ]Political[ ]Party:[ ](.*?)<br[ ]/>\s*
        European[ ]Group:\s*(.*?)</p>#sx',
        $meplist_data, $sections, PREG_SET_ORDER);
    foreach ($sections as $section) {
        list($dummy, $name, $image, $phone, $fax, $email, $party, $affiliation) = $section;

        $name = trim(preg_replace('#</?a[^>]*>#', '', $name));
        $name = preg_replace('/^(' . join('|', $honorifics) . ')\s*/', '', $name);
        preg_match('/^(\S+)\s(.*)/', $name, $nameparts);
        $members[$name]['firstname'] = $nameparts[1];
        $members[$name]['surname'] = $nameparts[2];
        if ($name == 'Malcolm Harbour') {
            $members[$name]['surname'] = 'Harbour CBE';
        }
        
        $members[$name]['region'] = $region;
        $mepsfound[$members[$name]['region']]++;

        $members[$name]['party'] = str_replace('Liberal Democrats Party', 'Liberal Democrats', html_entity_decode(trim($party), ENT_COMPAT, 'UTF-8'));
        $members[$name]['affiliation'] = trim($affiliation);
        $members[$name]['phone'] = trim($phone);
        $members[$name]['fax'] = trim(str_replace('&nbsp;', ' ', $fax));
        $members[$name]['email'] = trim($email);
        $members[$name]['image'] = $host . trim($image);
    }
}

foreach ($members as $member) {
    if (strlen($member['party']) < 4) {
        err("Invalid party info for $member[firstname] $member[surname] ($member[region])\n");
    }
    print "$member[firstname],$member[surname],$member[region],$member[party],$member[email],$member[fax],$member[image]\n";
}

$error = 0;
foreach ($expectmembers as $region => $expect) {
    if ($expect < $mepsfound[$region]) {
        fwrite(STDERR, "Too many MEPs in '$region': expected $expect,  found $mepsfound[$region]\n");
        $error = 1;
    }
    if ($expect > $mepsfound[$region]) {
        fwrite(STDERR, "Missing MEPs for '$region': expected $expect,  found $mepsfound[$region]\n");
        if ($expect - $mepsfound[$region] > 1) {
            $error = 1;
        }
    }
}

exit($error);

function cached_file_get_contents($url) {
    if (MEP_CACHE) {
        if (!file_exists(MEP_CACHE_DIR)) {
            err('Cache directory "'.MEP_CACHE_DIR.'" not found'."\n");
        }
        if (!is_writeable(MEP_CACHE_DIR)) {
            err('Cache directory "'.MEP_CACHE_DIR.'" not writeable'."\n");
        }
        $local=MEP_CACHE_DIR.'/'.md5($url);
        if (file_exists($local) && !is_writeable($local)) {
            err('Cache file "'.$local.'" not writeable'."\n");
        }
        if (file_exists($local) && ((time()-filemtime($local))<6000)) {
            ($content=file_get_contents($local)) || die("read err");
        } else {
            $content=file_get_contents($url);
            ($lfh=fopen($local,'w')) || die("write err");
            fwrite($lfh,$content);    
            fclose($lfh);
        }
    } else {
        $content=file_get_contents($url);
    }
    return($content);
}

