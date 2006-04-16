<?php
/*
 * admin-news.php:
 * NeWs service admin pages.
 * 
 * Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
 * Email: louise.crow@gmail.com. WWW: http://www.mysociety.org
 *
 * $Id: admin-news.php,v 1.2 2006-04-16 18:38:37 louise Exp $
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
	    $form->addElement('text', 'nsid', 'Newspaper Society ID', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'name', 'Newspaper Name', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'editor', 'Editor', array('size' => 50, 'maxlength' => 255));
            $form->addElement('textarea', 'address', 'Newspaper Address', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'postcode', 'Postcode', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'email', 'Email', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'telephone', 'Telephone', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'fax', 'Fax', array('size' => 50, 'maxlength' => 255));
            $form->addElement('text', 'isweekly', 'Weekly', array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'isevening', 'Evening',  array('size' => 50, 'maxlength' => 255));
	    $form->addElement('text', 'free', 'Free', array('size' => 50, 'maxlength' => 255));	
	    $form->addElement('submit', null, 'Send');

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
		$news['isweekly']=$form->exportValue('isweekly');
        	$news['isevening']=$form->exportValue('isevening');
		$news['free']=$form->exportValue('free');
		$news['isdeleted']= 0;	
		
		#update through the web service
		news_publish_update($newspaper_id, 'test', $news);
		
		print "The newspaper has been updated";
	    }

	    // Output the form
	    $form->display();
?>
<h2>Edit History</h2>
<? 
		
            # get the edit history
            $history = news_get_history($newspaper_id);

	    foreach($history as $edit){            	
               print "Edited on:  $edit $edit[lastchange] <br />\n";
	       print "By: $edit[source] <br />\n";
		if ($edit['isdel']){
			print "Record was deleted <br />\n"; 
		}else{
	  
			foreach($edit['data'] as $key => $value){
				print "<b>$key</b> $value<br />\n";
			}
		}
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
