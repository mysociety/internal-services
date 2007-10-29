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

$regions_url='http://www.europarl.org.uk/uk_meps/MembersPrincip.htm';

require_once '../../../phplib/phpcli.php';

//CONFIG VARS
define('MEP_DEBUG',false); // true or false
define('MEP_CACHE',true); // true or false
define('MEP_CACHE_DIR','cache'); // absolute or relative

//Translate peer titles (etc) to personal names
#$meptrans=array('NICHOLSON OF WINTERBOURNE' => 'NICHOLSON, Emma');

//How many members per region should we expect?
$expectmembers=array(
	'East Midlands' =>6,
	'Eastern' =>7,
	'London' =>9,
	'North East' =>3,
	'North West' =>9,
	'Northern Ireland' =>3,
	'Scotland' =>7,
	'South East' =>10,
	'South West' =>7,
	'Wales' =>4,
	'West Midlands' =>7,
	'Yorkshire and the Humber' =>6
);

$honorifics=array(
	'Mrs','Rt. Hon. Sir','Mr','Dr' 
);

$mepsfound = array();

print "First,Last,Constituency,Party,Email,Fax,Image\n";
//"Mike","Tuffrey","Proportionally Elected Member","Liberal Democrat","mike.tuffrey@london.gov.uk",""

//Get the base file
$regions_data=cached_file_get_contents($regions_url);

$regions_data=preg_replace("/\n/",' ',$regions_data);
$regions_data=preg_replace("/\s+/",' ',$regions_data);

$regions_data=preg_replace('/.*<map /s','',$regions_data);
$regions_data=preg_replace('/<\/map>.*/s','',$regions_data);

	preg_match_all('/<area[^>]+href\s*=\s*["\']([^"]+)["\'][^>]+alt\s*=\s*["\']([^"]+)["\']/',$regions_data,$matches,PREG_SET_ORDER);
# 2: URL, 3: DISTRICT

foreach($matches as $match) {
	$region=preg_replace('/&amp;/','and',$match[2]);
	$region=preg_replace('/\bThe/','the',$region);
	// Remove jsessionid to keep URLs constant (avoid flooding cache dir)
	$regionurls[$region]=relativeUrlToAbsolute($regions_url,$match[1]);
}

foreach($regionurls as $region => $regionurl) {
	$meplist_data=cached_file_get_contents($regionurl);
#	$meplist_data=preg_replace("/\n/",' ',$meplist_data);
	$meplist_data=preg_replace("/\s+/",' ',$meplist_data);
	preg_match_all('#\d+. <a href="\#([^>]+)"><font[^>]+>([^>]+)</font></a><br>#',$meplist_data,$matches,PREG_SET_ORDER);
    $mepsfound[$region] = 0;

	foreach ($matches as $match) {
		$mep = $match[2];	
		$ismep[$mep] = true;
		$target[$mep] = $match[1];
	}

	$sections=preg_split('/<a name/',$meplist_data,-1,PREG_SPLIT_NO_EMPTY);

	foreach ($sections as $section) {
		$matched = 0;
		if(preg_match('#^="([^"]*)".*<img src="([^"]*)".*<b>([^>]*)</b>.*<font [^>]*>([^>]*)<br>([^>]*)</font>.*(Tel: ([^<]*).*)?Fax: ([^<]*).*?mailto:([^"]+)#',$section,$matches)) {
			$matched = 1;
		} elseif (preg_match('#^="([^"]*)"().*?<b>([^>]*)</b>.*?<font [^>]*>([^>]*)<br>([^>]*)</font>.*?(Tel: ([^<]*).*?Fax: ([^<]*))?.*?mailto:([^"]+)#',$section,$matches)) {
			$matched = 1;
        }
		if ($matched) {

			$name=trim($matches[3]);
			
			foreach($honorifics as $honorific) {
				$name=preg_replace("/^$honorific/",'',$name);	
			}

			$name=trim($name);

			preg_match('/^(\S+)\s(.*)/',$name,$nameparts);
			$members[$name]['firstname']=$nameparts[1];
			$members[$name]['surname']=$nameparts[2];
		
			$members[$name]['region']=$region;
			$mepsfound[$members[$name]['region']]++;

			$members[$name]['image']=trim($matches[2]);
			$members[$name]['party']=trim($matches[4]);
			$members[$name]['affiliation']=trim($matches[5]);
			$members[$name]['phone']=trim($matches[7]);
			$members[$name]['fax']=trim($matches[8]);
			$members[$name]['email']=trim($matches[9]);
		}
	}
}

#foreach($members as $mep=>$data) {
#	$mep_data=cached_file_get_contents($data['url']);
#	$mep_data=preg_replace("/\n/",' ',$mep_data);
#	$mep_data=preg_replace("/\s+/",' ',$mep_data);
#	preg_match('#<td class="mepmail">\s+<a href="mailto:([^"]+)#',$mep_data,$matches);
#	$members[$mep]['email']=$matches[1];
#
#	preg_match('#<!-- national party -->\s*([^<]*)#',$mep_data,$matches);
#   $members[$mep]['party']=trim($matches[1]);             
#
#	preg_match('#<img [^>]*src="([^"]*)"[^>]*class="photoframe" />#',$mep_data,$matches);
#   $members[$mep]['image']=relativeUrlToAbsolute($data['url'],$matches[1]);             
#
#	preg_match_all('#<strong>Fax</strong>\s*:?\s*([^<]*)#',$mep_data,$matches,PREG_SET_ORDER);
#	foreach($matches as $match) {
#   	$members[$mep]['fax'][]=$match[1];             
#	}
#
#	$mepsfound[$members[$mep]['region']]++;
#}

foreach($members as $member) {
    if(!preg_match("#\d+#",$member['fax'])) {
        #err("Missing fax data for $member[firstname] $member[surname] ($member[region])\n");
    }
    if(strlen($member['party'])<4) {
        err("Invalid party info for $member[firstname] $member[surname] ($member[region])\n");
    }

    foreach(array_keys($member) as $key) {
        $member[$key] = utf8_encode($member[$key]);
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
