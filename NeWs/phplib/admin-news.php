<?php
/*
 * admin-news.php:
 * NeWs service admin pages.
 * 
 * Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
 * Email: louise.crow@gmail.com. WWW: http://www.mysociety.org
 *
 * $Id: admin-news.php,v 1.3 2006-05-01 15:06:56 louise Exp $
 * 
 */

require_once "../../phplib/news.php";
require_once "../../phplib/utility.php";
require_once 'HTML/QuickForm.php';


class ADMIN_PAGE_NEWS_NEWSPAPERS {
    function ADMIN_PAGE_NEWS_NEWSPAPERS() {
        $this->id = 'newspapers';
        $this->navname = 'NeWs Newspapers';
    }
    function display() {
        $newspaper_id = get_http_var('newspaper_id');
	
	# show a specific newspaper
        if ($newspaper_id) {
            $newspaper = news_get_newspaper($newspaper_id);

	    // Instantiate the HTML_QuickForm object
            $form = new HTML_QuickForm('newspaper_update');

	    // Set defaults for the form elements
	    $form->setDefaults(array(
    		'name' => $newspaper['name'],
                'nsid' => $newspaper['nsid'],
		'address' => $newspaper['address'],
                'editor' => $newspaper['editor'],
		'postcode' => $newspaper['postcode'],
                'website' => $newspaper['website'],
                'email' => $newspaper['email'],
                'telephone' => $newspaper['telephone'],
                'fax' => $newspaper['fax'],
                'isweekly' => $newspaper['isweekly'],
                'isevening' => $newspaper['isevening'],
                'free' => $newspaper['free']
 	    ));

	    // Add some elements to the form
	    $form->addElement('header', null, 'Update Newspaper Information');
	    $form->addElement('hidden', 'newspaper_id', $newspaper_id, null);
	    $form->addElement('hidden', 'nsid', $newspaper['nsid'], null);
	    $form->addElement('text', 'name', 'Newspaper Name', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'editor', 'Editor', array('size' => 50, 'maxlength' => 255));
            $form->addElement('textarea', 'address', 'Newspaper Address', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'postcode', 'Postcode', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'email', 'Email', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'telephone', 'Telephone', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'fax', 'Fax', array('size' => 50, 'maxlength' => 255));
            $form->addElement('checkbox', 'isweekly', 'Weekly', null);
	    $form->addElement('checkbox', 'isevening', 'Evening', null);
	    $form->addElement('checkbox', 'free', 'Free', null);	
	    $form->addElement('submit', 'update', 'Send');

	    // Define filters and validation rules
	    $form->applyFilter('name', 'trim');
	    $form->addRule('name', 'Please enter the newspaper name', 'required', null, 'server');

	    // Try to validate a form 
	    if ($form->validate()) {
              
                $news = array();
		$news['nsid']=$form->exportValue('nsid');
		$news['name']=$form->exportValue('name');
  		$news['editor']=$form->exportValue('editor');
		$news['address']=$form->exportValue('address');
		$news['postcode']=$form->exportValue('postcode');
		$news['email']=$form->exportValue('email');
		$news['telephone']=$form->exportValue('telephone');
		$news['fax']=$form->exportValue('fax');
		
		
		$checkboxElements = array('isweekly', 'isevening', 'free');
		foreach($checkboxElements as $check){
			if ($form->exportValue($check) == 1){
		        	$news[$check]=$form->exportValue($check);
                	}else{
                        	$news[$check]=0;
                	}
		
		}

		$news['isdeleted']= 0;	
		
		#update through the web service
		news_publish_update($newspaper_id, http_auth_user(), $news);
		
		print "The newspaper has been updated";
	    }

	    // Output the form
	    $form->display();
?>
<h2>Coverage</h2>
<?
	   #get the coverage info
	   $coverage = news_get_coverage($newspaper_id);
	
           print "<table>";
	   print "<tr>";
	   $coverage_headings = array('Location', 'Lat', 'Lon', 'Population', 'Coverage');
	   foreach ($coverage_headings as $heading){
	    	print "<th>";
	   	print "$heading";
	   	print "</th>"; 
	   }
           print "</tr>";
	   
	   $coverage_keys = array('name', 'lat', 'lon', 'population', 'coverage');
           foreach($coverage as $location){
		print "<tr>";
                foreach ($coverage_keys as $key){
			print "<td>";
			print "$location[$key]";
			print "</td>";
		}
		print "</tr>";
           }

	   print "</table>";

?>
<h2>Edit History</h2>
<? 
		
            # get the edit history
            $history = news_get_history($newspaper_id);

	    foreach($history as $edit){            	
               print "Edited on: $edit[lastchange] <br />\n";
	       print "By: $edit[source] <br />\n";
		if ($edit['isdel']){
			print "Record was deleted <br />\n"; 
		}else{ 
                        $data = $edit['data'];
			print "<b>Name</b> $data[name]<br />\n";
			print "<b>Editor</b> $data[editor]<br />\n";
			print "<b>Address</b> $data[address]<br />\n";
			print "<b>Postcode</b> $data[postcode]<br />\n";
			print "<b>Email</b> $data[email]<br />\n";
			print "<b>Telephone</b> $data[telephone]<br />\n";
			print "<b>Fax</b> $data[fax]<br />\n";
			if ($data['isweekly'] == 1){
			
				print "<b>Weekly</b> true<br />\n";
			}else{
				print "<b>Weekly</b> false<br />\n";
			}
                        if ($data['isevening'] == 1){

                                print "<b>Evening</b> true<br />\n";
                        }else{
                                print "<b>Evening</b> false<br />\n";
                        }
                        if ($data['free'] == 1){

                                print "<b>Free</b> true<br />\n";
                        }else{
                                print "<b>Free</b> false<br />\n";
                        }
	
		}
		print "<br />\n";
            }

        }else{
	   $q = news_get_newspapers();
?>
<h2>Newspaper records</h2>
<table cellpadding="3" cellspacing="0" border="0">
<tr><th>Name</th></tr>
<?
	    foreach($q as $r){

	        print "<tr><td><a href=\"/news-admin.php?page=newspapers&newspaper_id=$r[0]\">$r[1]</a></td></tr>\n";
            
            }
?>	
</table>
<?
	}
    }
}
?>
