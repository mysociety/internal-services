#!/usr/bin/php -q
<?php
/**
 * European Parliament screenscraper for MySociety
 *
 * @copyright Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
 * Email: richard@phase.org; WWW: http://www.mysociety.org/
 *
 */
$short_opts = '';
$long_opts = array();

$regions_url='http://www.europarl.eu.int/members/public/geoSearch/zoneList.do?country=GB&language=EN';

require_once '../../../phplib/phpcli.php';

//CONFIG VARS
$debug=0;

print "First,Last,Constituency,Party,Email,Fax,Image\n";
//"Mike","Tuffrey","Proportionally Elected Member","Liberal Democrat","mike.tuffrey@london.gov.uk",""

//Get the base file
$regions_data=cached_file_get_contents($regions_url);

$regions_data=preg_replace("/\n/",' ',$regions_data);
$regions_data=preg_replace("/\s+/",' ',$regions_data);

$regions_data=preg_replace('/.*<td class="box_content_mep">/s','',$regions_data);
$regions_data=preg_replace('/<\/table>.*/s','',$regions_data);

#print($regions_data);
	preg_match_all('/(<a\s+href\s*=\s*["\']([^"]+)["\'])[^>]+>([^>]+)<\/a>/',$regions_data,$matches,PREG_SET_ORDER);
# 2: URL, 3: DISTRICT

#print_r($matches);
foreach($matches as $match) {
	$region=preg_replace('/.*:\s+/','',$match[3]);
	$disturl=preg_replace('/;jsessionid[^?]+\?/','?',$match[2]);
	$disturl=preg_replace('/&amp;/','&',$disturl); // URLS musn't contain &amp;! 
		//; has special meaning with these URLs
	$regionurls[$region]=relativeUrlToAbsolute($regions_url,$disturl);
}
#print_r($regionurls);

foreach($regionurls as $region => $regionurl) {
	$meplist_data=cached_file_get_contents($regionurl);
	$meplist_data=preg_replace("/\n/",' ',$meplist_data);
	$meplist_data=preg_replace("/\s+/",' ',$meplist_data);
	preg_match('/<span class="number_results">(\d+)<\/span> Members found/',$meplist_data,$matches);
	$mepcount[$region]=$matches[1];
	$meplist_data=preg_replace("/\s+/",' ',$meplist_data);
	$meplist_data=preg_replace('/.*<td class="box_content_mep">/s','',$meplist_data);
	$meplist_data=preg_replace("/<br[^>]*>/",' ',$meplist_data);
	#$meplist_data=preg_replace('/<\/table>.*/s','',$meplist_data);
	preg_match_all('/(<a\s+href\s*=\s*["\']([^"]+)["\'])[^>]+>([^>]+)<\/a>([^<])*/',$meplist_data,$matches,PREG_SET_ORDER);
	#print("region: ".$region." count ".count($matches)."\n");
    if($debug) { print_r($matches); exit();}
	foreach($matches as $match) {
#print("\n\nMATCH\n");
#print_r($match);
		$mep=$match[3];
		preg_match('/(.*),(.*)/',$mep,$name_match);
		$members[$mep]['firstname']=trim($name_match[2]);
		$surname=trim($name_match[1]);
		preg_match('#(Ma?c)?(\w)(.*)#',$surname,$snmatch);
		$surname=$snmatch[1].$snmatch[2].strtolower($snmatch[3]);
		$surname=preg_replace('#([- ]\w)#e','strtoupper("\1")',$surname);
		$members[$mep]['surname']=$surname;
		$mepurl=$match[2];
		$alignment=$match[4];
		$mepurl=preg_replace('/;jsessionid[^?]+\?/','?',$match[2]);
		$mepurl=preg_replace('/&amp;/','&',$mepurl); // URLS musn't contain &amp;! 
		$members[$mep]['url']=relativeUrlToAbsolute($regionurl,$mepurl);
		$alignment=trim(preg_replace('/<[^>]+>/','',$alignment));
		$members[$mep]['alignment']=$alignment;
		$members[$mep]['region']=$region;
	}
}

#print_r($mepcount);


foreach($members as $mep=>$data) {
	$mep_data=cached_file_get_contents($data['url']);
	$mep_data=preg_replace("/\n/",' ',$mep_data);
	$mep_data=preg_replace("/\s+/",' ',$mep_data);
	preg_match('#<td class="mepmail">\s+<a href="mailto:([^"]+)#',$mep_data,$matches);
	$members[$mep]['email']=$matches[1];

	preg_match('#<!-- national party -->\s*([^<]*)#',$mep_data,$matches);
   $members[$mep]['party']=trim($matches[1]);             

	preg_match('#<img [^>]*src="([^"]*)"[^>]*class="photoframe" />#',$mep_data,$matches);
   $members[$mep]['image']=relativeUrlToAbsolute($data['url'],$matches[1]);             

	preg_match_all('#<strong>Fax</strong>\s*:?\s*([^<]*)#',$mep_data,$matches,PREG_SET_ORDER);
	foreach($matches as $match) {
   	$members[$mep]['fax'][]=$match[1];             
	}

}

foreach($members as $member) {
$member['faxes']=join('/',$member['fax']);
print("$member[firstname],$member[surname],$member[region],$member[party],$member[email],$member[faxes],$member[image]\n");
}

#print_r($members);

function cached_file_get_contents($url) {
	$local='cache/'.md5($url);
	if(file_exists($local) && ((time()-filemtime($local))<6000)) {
		($content=file_get_contents($local)) || die("read err");
	} else {
		$content=file_get_contents($url);
		($lfh=fopen($local,'w')) || die("write err");
		fwrite($lfh,$content);	
		fclose($lfh);
	}
	return($content);
}


/** 
 * Convert http:// URL to absolute
 */ 
function relativeUrlToAbsolute($baseurl,$relurl) {
	global $debug;
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
			if($debug) {
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
