#! /usr/bin/env python
#
# northern_ireland.py:
# Screen scrape representatives from Northern Ireland assembly website,.
# Northern Ireland Council for Voluntary Action website, and merge.
# 
# Copyright (c) 2012 UK Citizens Online Democracy. All rights reserved.
# Email: louise@mysociety.org; WWW: http://www.mysociety.org/

import json
import re
from urlparse import urljoin
from HTMLParser import HTMLParser
from cache import DiskCacheFetcher

NIA_MEMBERS = 'http://data.niassembly.gov.uk/members.asmx/GetAllCurrentMembers_JSON'
NIA_DETAIL_PAGE = 'http://aims.niassembly.gov.uk/mlas/details.aspx?&aff=%d&per=%d&sel=1&ind=11&prv=0'

fetcher = DiskCacheFetcher('cache')

def discard_head(html):
    """HTMLParser doesn't like the <head> section of these pages,
    so let's discard it."""
    return html.split("</head>",1)[1]

class NIADetailPageParser( HTMLParser ):
    """This parser is used to extract the info from each
    member's 'home page'.

    The useful stuff here is the member's email address
    and the url of an image.
    """
    
    def __init__( self ):
        HTMLParser.__init__( self )

        # These two attributes simply indicate that we
        # are in the correct tr and td.
        self._in_email_row = False
        self._in_email_td = False
        
        self.email = None
        self.image_url = None
    
    def handle_starttag( self, tag, attrs ):
        attrs = dict(attrs)
        if tag == 'img' and attrs.get('class') == 'mlaimg':
            self.image_url = attrs.get('src')
        if tag == 'a' and 'EmailHyperLink' in attrs.get('id', ''):
            link_url = attrs.get('href')
            if link_url != 'mailto:' and not self.email:
                self.email = link_url[7:]

def parseNIAssemblySite():
    print "First,Last,Constituency,Party,Email,Fax,Image"
    
    data = fetcher.fetch( NIA_MEMBERS )
    assembly_members = json.loads( data )['AllMembersList']['Member']

    for mla in assembly_members:
        m = re.match('(.*?) Belfast$', mla['ConstituencyName'])
        if m: mla['ConstituencyName'] = 'Belfast ' + m.group(1)
    
        url = NIA_DETAIL_PAGE % ( int(mla['AffiliationId']), int(mla['PersonId']) )
        data = fetcher.fetch( url )
        parser = NIADetailPageParser()
        parser.feed(discard_head(data))
        email = parser.email
        image_url = ''
        if parser.image_url:
            image_url = urljoin(url, parser.image_url)

        print ('"%s","%s","%s","%s","%s","","%s"' % (mla['MemberFirstName'],
                                                    mla['MemberLastName'],
                                                    mla['ConstituencyName'],
                                                    mla['PartyName'],
                                                    email or '', 
                                                    image_url)).encode('utf-8')

if __name__ == '__main__':
    
    # get the data from the live URLS and output the data from
    # each site into a file with a consistent format
    parseNIAssemblySite()

