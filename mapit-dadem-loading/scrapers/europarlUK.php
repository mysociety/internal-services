#!/usr/local/bin/php -q
<?php
/**
 * European Parliament (UK site) screenscraper for MySociety
 *
 * @copyright Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
 * Email: richard@phase.org; WWW: http://www.mysociety.org/
 *
 */
$short_opts = '';
$long_opts = array();

$regions_url = 'http://www.europarl.org.uk/section/your-meps/list-region';

require_once '../../../phplib/phpcli.php';

//CONFIG VARS
define('MEP_DEBUG',false); // true or false
define('MEP_CACHE',true); // true or false
define('MEP_CACHE_DIR','cache'); // absolute or relative

//Translate peer titles (etc) to personal names
#$meptrans=array('NICHOLSON OF WINTERBOURNE' => 'NICHOLSON, Emma');

//How many members per region should we expect?
$expectmembers=array(
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
    'West Midlands' => 6,
    'Yorkshire and the Humber' => 6
);

$honorifics = array( 'Ms', 'Mrs', 'Rt. Hon. Sir', 'Mr', 'Dr', 'Baroness', );

$mepsfound = array();

print "First,Last,Constituency,Party,Email,Fax,Image\n";
//"Mike","Tuffrey","Proportionally Elected Member","Liberal Democrat","mike.tuffrey@london.gov.uk",""

//Get the base file
$regions_data=cached_file_get_contents($regions_url);
preg_match_all('#<a href="(/section/your-meps/findmep[^"]*)">(.*?)</a>#', $regions_data, $matches, PREG_SET_ORDER);

foreach($matches as $match) {
    $region=preg_replace('/&amp;/','and',$match[2]);
    $region=preg_replace('/\bThe/','the',$region);
    // Remove jsessionid to keep URLs constant (avoid flooding cache dir)
    $regionurls[$region]=relativeUrlToAbsolute($regions_url,$match[1]);
}

foreach($regionurls as $region => $regionurl) {
    $meplist_data=cached_file_get_contents($regionurl);
    $meplist_data=preg_replace("/\s+/",' ',$meplist_data);
    $mepsfound[$region] = 0;

    preg_match_all('#<h2>\s*(.*?)\s*</h2>.*?
        <img[ ]src="([^"]*)".*?
        Telephone:</strong>\s*(.*?)\s*(?:UK[ ]Office|EU[ ]Office|<br).*?
        Fax:</strong>\s*(.*?)\s*(?:UK[ ]Office|EU[ ]Office|<br).*?
        E-Mail:</strong>\s*<a[ ]href="mailto:([^"]*)">[^<]*</a>\s*<a[ ]href="mailto:([^"]*)">.*?
        National[ ]Political[ ]Party:[ ]</strong>(.*?)<br/>\s*
        <strong>European[ ]Group:[ ]</strong>(.*?)</div>#sx',
        $meplist_data, $sections, PREG_SET_ORDER);
    foreach ($sections as $section) {
        list($dummy, $name, $image, $phone, $fax, $email, $email2, $party, $affiliation) = $section;

        $name = preg_replace('/^(' . join('|', $honorifics) . ')\s*/', '', $name);
        preg_match('/^(\S+)\s(.*)/',$name,$nameparts);
        $members[$name]['firstname']=$nameparts[1];
        $members[$name]['surname']=$nameparts[2];
        
        $members[$name]['region']=$region;
        $mepsfound[$members[$name]['region']]++;

        $members[$name]['party'] = html_entity_decode(trim($party), ENT_COMPAT, 'UTF-8');
        $members[$name]['affiliation'] = trim($affiliation);
        $members[$name]['phone'] = trim($phone);
        $members[$name]['fax'] = trim($fax);
        $members[$name]['email'] = trim($email2);
        if ($email) $members[$name]['email'] = trim($email);
        $members[$name]['image'] = trim($image);
    }
}

foreach($members as $member) {
    if(strlen($member['party'])<4) {
        err("Invalid party info for $member[firstname] $member[surname] ($member[region])\n");
    }
    print("$member[firstname],$member[surname],$member[region],$member[party],$member[email],$member[fax],$member[image]\n");
}

foreach($expectmembers as $region => $expect) {
    if(($expect<$mepsfound[$region]) ) {
        fwrite(STDERR, "Too many MEPs in '$region': expected $expect,  found $mepsfound[$region], aborting\n");
        exit(1);
    }
    if(($expect>$mepsfound[$region]) ) {
        fwrite(STDERR, "Missing MEPs for '$region': expected $expect,  found $mepsfound[$region]\n");
        if ($expect - $mepsfound[$region] > 1) {
            fwrite(STDERR, "More than one difference, so aborting\n");
            exit(1);
        }
    }
}

function cached_file_get_contents($url) {
    if(MEP_CACHE) {
        if(!file_exists(MEP_CACHE_DIR)) {
            err('Cache directory "'.MEP_CACHE_DIR.'" not found'."\n");
        }
        if(!is_writeable(MEP_CACHE_DIR)) {
            err('Cache directory "'.MEP_CACHE_DIR.'" not writeable'."\n");
        }
        $local=MEP_CACHE_DIR.'/'.md5($url);
        if(file_exists($local) && !is_writeable($local)) {
            err('Cache file "'.$local.'" not writeable'."\n");
        }
        if(file_exists($local) && ((time()-filemtime($local))<6000)) {
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


/** 
 * Convert http:// URL to absolute
 */ 
function relativeUrlToAbsolute($baseurl,$relurl) {
    if(!preg_match("#(http://)([^/]*)/?((.*)/([^/]+))?$#",$baseurl,$urlparts)) {
        return(false);
    }
    list($url,$proto,$host,$filepath,$dir,$file)=$urlparts;
    if(preg_match('#^http://#',$relurl)) {
        $absurl=$relurl;
    } else if (preg_match('#^/#',$relurl)) {
        $absurl=$proto.$host.$relurl;
    } else {
        while(preg_match('#^../#',$relurl)) {
            if(MEP_DEBUG) {
                print("Relurl: $relurl / Dir: $dir\n");
            }
            $relurl=preg_replace('#^../#','',$relurl,1);
            $dir=preg_replace('#/?[^/]*$#','',$dir,1);
        }
        $absurl=$host.'/'.$dir.'/'.$relurl;
        $absurl=preg_replace('#//#','/',$absurl);
        $absurl=$proto.$absurl;
    }
    return($absurl);
}
?>
