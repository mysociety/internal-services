#!/usr/local/bin/php -q
<?php
/**
 * Welsh Assembly members screenscraper for MySociety
 *
 * @copyright Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
 * Email: richard@phase.org; WWW: http://www.mysociety.org/
 *
 */
$short_opts = '';
$long_opts = array();

require_once '../../../phplib/phpcli.php';

//CONFIG VARS
$debug=0;

$list_source_url="http://www.wales.gov.uk/who/constit_e.htm";

$list_source_block_start='BeginEditable "Content"[^>]*>';
$list_source_block_end='<[^>]*EndEditable';

$party_trans=array('Lab'=>'Labour','Lib Dem'=>'Liberal Democrat','Con'=>'Conservative','Plaid'=>'Plaid Cymru');

$bio_source_block_start=$address_source_block_start=$list_source_block_start;
$bio_source_block_end=$address_source_block_end=$list_source_block_end;

//fixes to typo'd #tags in WA site
$translatetag=array( 
	'carlsargeant' => 'carolsargeant'
#	'leannewood' => 'williams' // no help for that error!
);

//END CONFIG

print "First,Last,Constituency,Party,Email,Fax,Image\n";
//"Mike","Tuffrey","Proportionally Elected Member","Liberal Democrat","mike.tuffrey@london.gov.uk",""

//Get the base file
$list_data=file_get_contents($list_source_url);

//Normalise it
$list_data=preg_replace("/\n/",' ',$list_data);
$list_data=preg_replace("/\s+/",' ',$list_data);

//Grab the section we're intereted in (see vars above)
if($list_data=preg_match("/$list_source_block_start(.*)$list_source_block_end/",$list_data,$matches)) {
	$list_data=$matches[1];
} else { 
    fwrite(STDERR, "ERROR: Source page format (list page) has changed");
    exit(1);
}
//Put any entities in CDATA sections so the parser can't choke on them
$list_data=preg_replace("/(&\S+;)/",'<![CDATA[\1]]>',$list_data);
#print(htmlentities($list_data));
if($debug) {
	#header('Content-type: text/plain');
}

//First page is actually clean HTML, that can be converted to XHTML easily enough 
 //to make XML-based parsing possible

$lpp=&new listPageParser($list_source_url);
$lpp->parse('<assm>'.$list_data.'</assm>');

//grab the basic results
$members=$lpp->member;

//then grab the pages on which the biographies are found
 // (email addresses and links to the pages containing fax/phone)
$contacturl = array();
foreach ($lpp->biourls as $baseurl=>$alwaystrueval) {
	
	//split the base URL down so we can create relative URLs later
	#preg_match("#(http://)([^/]*)/?((.*)/([^/]+))?$#",$bu,$urlparts);
	#list($url,$proto,$host,$filepath,$dir,$file)=$urlparts;

	// grab the file
	$bio_data=@file_get_contents($baseurl);

	//normalise
	$bio_data=preg_replace("/\n/",' ',$bio_data);
	$bio_data=preg_replace("/\s+/",' ',$bio_data);
	
 	//extract useful section
	if($bio_data=preg_match("/$bio_source_block_start(.*)$bio_source_block_end/",$bio_data,$matches)) {
		$bio_data=$matches[1];
	} else { 
		fwrite(STDERR, "ERROR: Source page format (bio page) has changed in '$baseurl'"); 
        exit(1);
	}

/* Bio HTML is too broken to use - do PREG grabs instead!
	//Sanitise the HTML 
	$bio_data=preg_replace("/<br>/",'<br />',$bio_data);
	$bio_data=preg_replace("/&(\W)/",'&amp;\1',$bio_data);
	$bio_data=preg_replace("/&([^;]*)/",'&amp;\1',$bio_data);
	$bio_data=preg_replace("/<img([^>]+)>/i",'<img\1 />',$bio_data);
	//XXX HACK! - use a proper general case strtolower!
	$bio_data=preg_replace("/<P>/",'<p>',$bio_data);
	$bio_data=preg_replace("/<\/P>/",'</p>',$bio_data);
	$bio_data=preg_replace("/(&\S+;)/",'<![CDATA[\1]]>',$bio_data);

	print("BD:\n$bio_data");
	$bpp=&new bioPageParser($bu);
	$bpp->parse('<assm>'.$bio_data.'</assm>');
	print("\nCONTACTS\n");
	print_r($bpp->contact);
	foreach($bpp->contact as $tag=>$contact) {
		$allbios[$tag]=$contact;
	}		  
	print_r($bpp->contacturls);
*/

// find all <a name> and <a href> tags - this is where the data hides! 
	preg_match_all('/(<a\s+(\w+)\s*=\s*["\']([^"]+)["\'])|(<img[^>]*src="([^"]*)")/i',$bio_data,$matches,PREG_SET_ORDER);

    if($debug) { print_r($matches); }
	foreach($matches as $anchor) {
		$aparam=$anchor[2];
		$avalue=$anchor[3];
		if($aparam === 'name') {
			$biotag=$avalue;
			$image[$biotag]=$imgurl; //images come before anchors; everything else just after
		} else if (($aparam === 'href') && !array_key_exists($biotag, $contacturl)) {
//get a canonical URL for the contact page (where phone and fax data hide
			if(preg_match('/^mailto:(.*)/',$avalue,$mailmatch)) {
				$email[$biotag]=$mailmatch[1];
			} else if(!preg_match('/jpg$/',$avalue) &&  !preg_match('/gif$/',$avalue)){
				$linkurl=$avalue;
				$fullurl=relativeUrlToAbsolute($baseurl,$linkurl);
				$contacturl[$biotag]=$fullurl;	
				$fullurl=preg_replace('/#.*/','',$fullurl);
				$contacturls[$fullurl]=true;	
			}					
		} else if(count($anchor) >= 6) {
            $imgsrc=$anchor[5];
			//grab the image link for now, and assign it once we get to the anchor 
			$imgurl=relativeUrlToAbsolute($baseurl,$imgsrc);
		}
	}
}
if($debug) {
    print("EMAIL:");
    print_r($email);
    print("\nIMAGE:");
    print_r($image);
    print("\n");
}

$phone = array();
$fax = array();
foreach ($contacturls as $cu=>$trueval) {
	
		preg_match("#(http://)([^/]*)/?((.*)/([^/]+))?$#",$cu,$urlparts);
		list($url,$proto,$host,$filepath,$dir,$file)=$urlparts;
	$contact_data=@file_get_contents($cu); //plenty of dud URLs in this site!
	$contact_data=preg_replace("/\n/",' ',$contact_data);
	$contact_data=preg_replace("/\s+/",' ',$contact_data);
	
	$contact_data=preg_replace("/<br>/",'<br />',$contact_data);
	$contact_data=preg_replace("/&(\W)/",'&amp;\1',$contact_data);
	$contact_data=preg_replace("/&([^;]*)/",'&amp;\1',$contact_data);
	$contact_data=preg_replace("/<img([^>]+)>/i",'<img\1 />',$contact_data);
/* Bio HTML is too broken to use - do PREG grabs instead!
	//XXX HACK! - use a proper general case strtolower!
	$contact_data=preg_replace("/<P>/",'<p>',$contact_data);
	$contact_data=preg_replace("/<\/P>/",'</p>',$contact_data);
	$contact_data=preg_replace("/(&\S+;)/",'<![CDATA[\1]]>',$contact_data);

	print("BD:\n$contact_data");
	$bpp=&new contactPageParser($cu);
	$bpp->parse('<assm>'.$contact_data.'</assm>');
	print("\nCONTACTS\n");
	print_r($bpp->contact);
	foreach($bpp->contact as $tag=>$contact) {
		$allcontacts[$tag]=$contact;
	}		  
	print_r($bpp->contacturls);
*/

	preg_match_all('/(<a\s+(\w+)\s*=\s*["\']([^"]+)["\'])|((Tel:?\s+([0-9()\s]+)[^>]*)(Fax:?\s+([0-9()\s]+)[^>]*)<)/i',$contact_data,$matches,PREG_SET_ORDER);
// 2: 'name' or 'href', 3: contact tag, 4: address string, 6: phone, 8:Fax

    if($debug) { print("\nCONTACT\n"); print_r($matches); }
	foreach($matches as $anchor) {
		#foreach($anchorset as $anchor) {
			if($anchor[2] === 'name') {
				$contacttag=$anchor[3];
			} else if (count($anchor) >= 5 && !array_key_exists($contacttag, $phone)) { 
						// in case of duplicate anchors, at least one known
				$phone[$contacttag]=trim($anchor[6]);
				$fax[$contacttag]=trim($anchor[8]);
			}
		#}
	}
}

if($debug) {
    print("PHONE:\n");
    print_r($phone);
    print("FAX:\n");
    print_r($fax);
}

//iterate through member list to add email,image and phone/fax data
$count = 0;
$mouse = array();
foreach ($members as $member) {
		   $biotag=preg_replace('/^(.*#)/','',$member['detailsurl']);
		 	$member['email']=array_key_exists($biotag, $email) ? $email[$biotag] : '';
		 	$member['image']=array_key_exists($biotag, $image) ? $image[$biotag] : '';
		 	$member['contacturl']=array_key_exists($biotag, $contacturl) ? $contacturl[$biotag] : '';
		   $contacttag=preg_replace('/^(.*#)/','',$member['contacturl']);
if($debug) {
	print("Member: $member[membername]; contacttag: '$contacttag'\n");
}

//fix dodgy anchors - see conf section
		 	if(array_key_exists($contacttag, $phone)) {
                $member['phone']=$phone[$contacttag];
			} elseif (array_key_exists($contacttag, $translatetag)) {
				$member['phone']=$phone[$translatetag[$contacttag]];
			}
		 	if(array_key_exists($contacttag, $fax)) {
                $member['fax']=$fax[$contacttag];
			} elseif (array_key_exists($contacttag, $translatetag)) {
				$member['fax']=$fax[$translatetag[$contacttag]];
			}
		 	//$member['fax']=$fax[$contacttag];
		 	//$member['contacturl']=$allbios[$biotag]['url'];

		//Make an educated guess at forename / surname
			preg_match('/^\s*(\S.*)\s(\S+)\s*/',$member['membername'],$matches);
			$member['firstname']=$matches[1];
			$member['firstname']=preg_replace('/^Rt\.? Hon\.?\s*/','',$member['firstname']);
			$member['firstname']=preg_replace('/^Hon\.?\s*/','',$member['firstname']);
//XXX might need to strip out other honorifics in future...
			$member['surname']=$matches[2];

		//expand titles for parties
			$member['fullparty']=array_key_exists($member['party'],$party_trans)?$party_trans[$member['party']]:$member['party'];

		//protect "'s so as to avoid breaking CSV format
        //unescape ampersands
			foreach($member as $k=>$v) {
                if($debug) { print("[$k]:$v,   "); } 
                $v=str_replace('&amp;','&',$v);
                $v=str_replace('&ocirc;','ô',$v);
                $v=preg_replace('/"/','\"',$v);
				$member[$k]=$v;
            }
            if($debug) { print("\n"); }
            //	First,Last,Constituency,Party,Email,Fax, image
            if (!$member['constituency']) {
                die("$member[firstname] $member[surname] has no cons");
            }
			print "\"$member[firstname]\",\"$member[surname]\",\"$member[constituency]\",\"$member[fullparty]\",\"$member[email]\",\"".(array_key_exists('fax', $member) ? $member['fax'] : '')."\",\"$member[image]\"";
			print("\n");
            $count ++;
		}		  

if ($count <= 58) { // one dead, see TODO above
    err("Expected to get 60 Welsh Assembly members, but got $count");
    exit(1);
}

// Success
exit(0);
	
class listPageParser {

	var $data;
	var $output;
	var $tagstack=array();
	var $textpending;
	var $membercount=0;
	var $member;
    var $has_constituency=false;

	function listPageParser($base_url) {
		$this->base_url=$base_url;
		preg_match("#(http://)([^/]*)/?((.*)/([^/]+))?$#",$base_url,$matches);
		list($url,$this->proto,$this->host,$filepath,$this->dir,$this->file)=$matches;
		#print("($url,$proto,$host,$filepath,$dir,$file)");	
		#print_r($matches);
		
		$this->xml_parser = xml_parser_create();
        if (!$this->xml_parser)
            err("failed to call xml_parser_create");
		
		xml_parser_set_option($this->xml_parser, XML_OPTION_CASE_FOLDING,0);

		xml_set_element_handler($this->xml_parser, array(&$this,'startElement'), array(&$this,'endElement'));
		xml_set_character_data_handler($this->xml_parser, array(&$this,'cdataHandler'));
	}


	function parse($data) {
		$this->data = $data;
		if (!xml_parse($this->xml_parser, $data, true)) {
		   $this->output='<error>'.(sprintf("XML error in template: %s at line %d",
			xml_error_string(xml_get_error_code($this->xml_parser)),
			xml_get_current_line_number($this->xml_parser))).'</error>';
			fwrite(STDERR, 'ERROR: bad parse'. $this->output);
            exit(1);
		}
		xml_parser_free($this->xml_parser);

	
		#		print_r($this->biourls);
		#return($this->output);
	}


	function startElement($parser, $name, $attrs) {
			 $name=strtolower($name);
		
		switch($name) {

			case 'li':
				break;	

			case 'a':
				$this->member[$this->membercount]['constituency']=preg_replace('/\s*-\s*$/','',$this->textpending);	
				$this->member[$this->membercount]['detailsurlrel']=$linkurl=$attrs['href'];

				$fullurl=relativeUrlToAbsolute($this->base_url,$linkurl);
				$this->member[$this->membercount]['detailsurl']=$fullurl;
				$fullurl=preg_replace('/#.*/','',$fullurl);
				$this->biourls[$fullurl]=true;	

			}		
		$this->textpending=''; // Only one valid textblock can be open at once in our spec!
	}

	function endElement($parser, $name) {
			 $name=strtolower($name);
		switch($name) {

			case 'h2':
				$this->membertype=$this->textpending;
				break;	

			case 'h3':
				$this->constituency=$this->textpending;
                $this->has_constituency=true;
				break;	

			case 'a':
                $nametext = $this->textpending;	
                # Fix incorrect hyphenation on index page
                $nametext = str_replace("Elis Thomas", "Elis-Thomas", $nametext);
                $nametext = str_replace("Tamsin Dunwoody", "Tamsin Dunwoody-Kneafsey", $nametext);
				$this->member[$this->membercount]['membername']=$nametext;
				break;	

			case 'li':	
                if (preg_match("/Presiding Officer Statement/", $this->member[$this->membercount]['membername'])) {
                    // Probably member has died
                    // TODO: Create convention for storing dead members better in DaDem

                } else {
                    $this->member[$this->membercount]['party']=preg_replace('/\s*[()]\s*/','',$this->textpending);	
                    $this->member[$this->membercount]['membertype']=$this->membertype;	
                    if($this->has_constituency && (!array_key_exists('constituency',$this->member[$this->membercount])
                        || !$this->member[$this->membercount]['constituency'])) {
                        $this->member[$this->membercount]['constituency']=$this->constituency;
                    }		  

                    $this->membercount++;
                }
		}
		$this->textpending=''; // Only one valid textblock can be open at once in our spec!
	}

	function cdataHandler($parser,$data) {
		if(!preg_match("/^\s+$/",$data)) 
			$this->textpending.=$data;
	}
	
}

class bioPageParser {

	var $data;
	var $output;
	var $tagstack=array();
	var $textpending;
	var $membercount=0;
	var $member;
	var $contact=array();

	function __construct($base_url) {

		$this->base_url=$base_url;
		preg_match("#(http://)([^/]*)/?((.*)/([^/]+))?$#",$base_url,$matches);
		list($url,$this->proto,$this->host,$filepath,$this->dir,$this->file)=$matches;
		#print("($url,$proto,$host,$filepath,$dir,$file)");	
		#print_r($matches);
		
		$this->xml_parser = xml_parser_create();
		
		xml_parser_set_option($this->xml_parser, XML_OPTION_CASE_FOLDING,0);

		xml_set_element_handler($this->xml_parser, array(&$this,'startElement'), array(&$this,'endElement'));
		xml_set_character_data_handler($this->xml_parser, array(&$this,'cdataHandler'));
	}


	function parse($data) {
		$this->data = $data;
		if (!xml_parse($this->xml_parser, $data, true)) {
		   $this->output='<error>'.(sprintf("XML error in template: %s at line %d char %d",
			xml_error_string(xml_get_error_code($this->xml_parser)),
			xml_get_current_line_number($this->xml_parser),
			xml_get_current_column_number($this->xml_parser))).'</error>';
			fwrite(STDERR, 'ERROR: bad parse'. $this->output);
            exit(1);
		}
		xml_parser_free($this->xml_parser);

		/*
		foreach ($this->member as $member) {
			foreach($member as $k=>$v) {
				print("[$k]:$v,   ");
			}
			print("\n");
		}		  
		
		print_r($this->biourls); */
		#return($this->output);
	}


	function startElement($parser, $name, $attrs) {
			 $name=strtolower($name);
		
		switch($name) {

			case 'li':
				break;	

			case 'a':
				if($attrs['href']) {

					if(preg_match('#^mailto:(.*)#',$attrs['href'],$matches)) {
						$this->contact[$this->anchor]['email']=$matches[1];
					} else {		  
						$url=$attrs['href'];
						if(preg_match('#^http://#',$url)) {
							$this->contact[$this->anchor]['url']=$fu=$url;
							$fu=preg_replace('/#.*/','',$fu);
							$this->contacturls[$fu]=true;	
						} else if (preg_match('#^/#',$url)) {
							$this->contact[$this->anchor]['url']=$fu=$this->proto.$this->host.$url;
							$fu=preg_replace('/#.*/','',$fu);
							$this->contacturls[$fu]=true;	
						} else {
							$this->contact[$this->anchor]['url']=$fu=$this->proto.$this->host.'/'.$this->dir.'/'.$url;
							$fu=preg_replace('/#.*/','',$fu);
							$this->contacturls[$fu]=true;	
						}		  
			 		}
		 		} else if($attrs['name']) {
					$this->anchor=$attrs['name'];
			  	}

			}		
		$this->textpending=''; // Only one valid textblock can be open at once in our spec!
	}

	function endElement($parser, $name) {
		$name=strtolower($name);
			 
		$this->textpending=''; // Only one valid textblock can be open at once in our spec!
	}

	function cdataHandler($parser,$data) {
		if(!preg_match("/^\s+$/",$data)) 
			$this->textpending.=$data;
	}
	
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
