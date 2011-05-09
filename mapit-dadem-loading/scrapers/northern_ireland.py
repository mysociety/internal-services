#! /usr/bin/env python
#
# northern_ireland.py:
# Screen scrape representatives from Northern Ireland assembly website,.
# Northern Ireland Council for Voluntary Action website, and merge.
# 
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: louise@mysociety.org; WWW: http://www.mysociety.org/
#

from urllib2 import urlopen
from urlparse import urljoin
from HTMLParser import HTMLParser
from htmlentitydefs import name2codepoint
import re

NIA_LIST_PAGE = "http://www.niassembly.gov.uk/members/membership11.htm"
NIA_NAME_FIXES = {
    "MID-ULSTER": "MID ULSTER",
    "NEWRY & ARMAGH": "NEWRY AND ARMAGH",
    "FERMANAGH & SOUTH TYRONE": "FERMANAGH AND SOUTH TYRONE",
}
                          
class Member:
    """Will store a member's details."""
    def __init__(self):
        self.name = None
        self.party = None
        self.constituency = None
        self.url = None
        self.email = ''
        self.image_url = ''

    def __repr__(self):
        return str((self.name,self.party, self.constituency,self.url,self.email,self.image_url))

def discard_head(html):
    """HTMLParser doesn't like the <head> section of these pages,
    so let's discard it."""
    return html.split("</head>",1)[1]

class NIATableParser( HTMLParser ):
    """Used to extract the useful data from the NIA site.
    self.state will be used to store the values:

    START - Until we first see the start of a table
    TABLE - While we are extracting the data from that table
    FINISHED - Indicates that we are done, and that we don't
          need any more tags or data.
    """
    #-----------------------------
    def __init__( self ):
        HTMLParser.__init__( self )
        self._state = 'START'
        self._data = ''
        self.table = []
        self._current_member = None

        # We'll use a count of the number of <td>s so far
        # in this row to tell us what the next bit of data is.
        # details in handle_endtag.
        self._td_count = None

    def handle_starttag(self, tag, attrs):
        # Note that we have now reached the start of the table,
        # and can begin extracting the data
        if tag == 'table':
            if ('border', '1') in attrs:
                self._state = 'TABLE'
        # This is the start of a new row, where each row contains
        # a member. Create a new blank Member, and set the <td> count
        # to zero.
        elif self._state == 'TABLE' and tag == 'tr':
            self._current_member = Member()
            self._td_count = 0
        # Increment the <td> count, and reset self._data.
        elif self._state == 'TABLE' and tag == 'td':
            self._td_count += 1
            self._data = ''
        elif self._state == 'TABLE' and tag == 'sup':
            self._state = 'SUP'
        # if we are in the first <td>, and we see a link,
        # this is a link to the member's homepage. Add the link
        # as member.url.
        elif self._state == 'TABLE' and self._td_count == 1 and tag == 'a' and attrs[0][0] == 'href':
            self._current_member.url = attrs[0][1]
                    
    #-----------------------------
    def handle_endtag(self, tag):
        # We have reached the end of the table - there is nothing else to do.
        if self._state == 'TABLE' and tag == 'table':
            self._state = 'FINISHED'
        elif tag == 'sup':
            self._state = 'TABLE'
        elif self._state == 'TABLE' and tag == 'tr':
            # add this member to the list (unless there were no <td>s,
            # in which case, it was just the header...
            if self._td_count > 0:
                self.table.append(self._current_member)
        elif self._state == 'TABLE' and tag == 'td':
            # First <td> contains the name
            if self._td_count == 1:
                self._current_member.name = self.tidy_data()
            # Second <td> contains the party
            if self._td_count == 2:
                self._current_member.party = self.tidy_data()
            # Third <td> contains the constituency
            if self._td_count == 3:
                self._current_member.constituency = self.tidy_data()

    
    #-----------------------------
    def handle_data( self, data ):
        # there is no need to bother with this if we aren't in the table.
        if self._state == 'TABLE':
            self._data += data
            
    #-----------------------------
    def handle_entityref( self, ref ):
        # there is no need to bother with this if we aren't in the table.
        if self._state == 'TABLE':
            if ref == 'nbsp':
                self._data += ' '
            elif ref == 'amp':
                self._data += '&'
            else:
                self._data += unichr(name2codepoint[ref])
    #-----------------------------
    def tidy_data( self ):
        return ' '.join( self._data.strip().replace('*','').split() )

class NIADetailPageParser( HTMLParser ):
    """This parser is used to extract the info from each
    member's 'home page'.

    The useful stuff here is the member's email address
    and the url of an image.
    """
    
    #-----------------------------
    def __init__( self ):
        HTMLParser.__init__( self )

        # This stores how many table starts we have seen. We are
        # only interested in the contents of the first table.
        self._table_number = 0

        # These two attributes simply indicate that we
        # are in the correct tr and td.
        self._in_email_row = False
        self._in_email_td = False
        
        self.email = ''
        self.image_url = None
    
    #-----------------------------
    def handle_starttag( self, tag, attrs ):
        if tag == 'table':
            self._table_number += 1
        elif self._in_email_row is True and tag == 'td':
            self._in_email_td = True
        elif self._table_number == 1 and tag == 'img':
            for key, value in attrs:
                if key == 'src':
                    self.image_url = value
                    break

    #-----------------------------
    def handle_data( self, data ):
        # If we see data 'E-mail Address', then we are in
        # the row containing the email address
        if data == 'E-Mail Address:' and self.email is None:
            self._in_email_row = True

        if self._in_email_td:
            self.email = data
            self._in_email_row = False
            self._in_email_td = False
 
def parseNIAssemblySite():
    page = urlopen( NIA_LIST_PAGE )
    parser = NIATableParser()

    # the <head> section is a bit broken - we'd better discard it...
    good_html = discard_head(page.read())
    parser.feed(good_html)
    
    #crop the first header row
    assembly_members = parser.table

    print "First,Last,Constituency,Party,Email,Fax,Image"
    
    for member in assembly_members:

        #case where a url is given
        if member.url is not None:
            url = urljoin( NIA_LIST_PAGE, member.url )

            parser = NIADetailPageParser()
            parser.feed(discard_head(urlopen(url).read()))
            
            member.email = parser.email
            
            if parser.image_url:
                member.image_url = urljoin(url, parser.image_url)

        # Now we need to split the name into surname and forename
        # We'll do this by splitting on the last space.
        # An exception will have to be made for Ian Paisley Jnr...
        # It may as well work for any other JNRs who appear in the future.
        
        rsplit_name = member.name.rsplit(' ', 1)
        
        if rsplit_name[1] == "JNR":
            split_again = rsplit_name[0].rsplit(' ', 1)
            member.surname = split_again[0]
            member.forename = split_again[1]+' '+'JNR'
        else:
            member.surname, member.forename = tuple(member.name.rsplit(' ',1))

        # Manual fixes
        if member.forename == 'PJ':
            member.forename = 'P J'
        if member.surname[0] == '#':
            member.surname = member.surname[1:]

        member.email = member.email.strip()
        member.constituency = NIA_NAME_FIXES.get(member.constituency, member.constituency)
        
        print ('"%s","%s","%s","%s","%s","","%s"' % (realNameCase(member.forename),
                                                    realNameCase(member.surname), 
                                                    realNameCase(member.constituency), 
                                                    member.party, 
                                                    member.email, 
                                                    member.image_url)).encode('utf-8')
    
def realNameCase( name ):
        #Should cover people and place names
        words = re.split("(/| AND | |-|')", name)
        words = [ word.capitalize() for word in words ]

        def handlescottish(word):
            if (re.match("Mc[a-z]", word)):
                return word[0:2] + word[2].upper() + word[3:]
            if (re.match("Mac[a-z]", word)):
                return word[0:3] + word[3].upper() + word[4:]
            return word
        words = map(handlescottish, words)

        return "".join(words)

if __name__ == '__main__':
    
    # get the data from the live URLS and output the data from
    # each site into a file with a consistent format
    parseNIAssemblySite()

