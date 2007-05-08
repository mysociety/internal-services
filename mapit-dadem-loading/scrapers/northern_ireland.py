#! /usr/bin/env python2.4
#
# northern_ireland.py:
# Screen scrape representatives from Northern Ireland assembly website, 
# Northern Ireland Council for Voluntary Action website, and merge.
# 
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: louise.crow@gmail.com; WWW: http://www.mysociety.org/
#
#
# Modified by duncan.parkes@gmail.com - 26/3/2007
# to take into account the latest Northern Ireland Assembly Elections
#=================================

# The NICVA parser is currently not being used - Duncan 26/3/2007

from urllib2 import urlopen
from urlparse import urljoin
from HTMLParser import HTMLParser
import re


NIA_LIST_PAGE = "http://www.niassembly.gov.uk/members/membership07.htm"
#NICVA_LIST_PAGE = "http://www.nicva.org/index.cfm/section/General/key/190805"
NIA_OUTPUT_FILE = "nia_out.txt"
#NICVA_OUTPUT_FILE = "nicva_out.txt"

# order preserving unique
def uniq_preserve_order(alist):
    s = {}
    return [s.setdefault(e,e) for e in alist if e not in s]


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

#=================================
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
            self._state = 'TABLE'
        # This is the start of a new row, where each row contains
        # a member. Create a new blank Member, and set the <td> count
        # to zero.
        elif tag == 'tr':
            self._current_member = Member()
            self._td_count = 0
        # Increment the <td> count, and reset self._data.
        elif tag == 'td':
            self._td_count += 1
            self._data = ''
        # if we are in the first <td>, and we see a link,
        # this is a link to the member's homepage. Add the link
        # as member.url.
        elif self._td_count == 1 and tag == 'a':
            self._current_member.url = [value for key, value in attrs if key == 'href'][0]
                    
    #-----------------------------
    def handle_endtag(self, tag):
        # We have reached the end of the table - there is nothing else to do.
        if tag == 'table':
            self._state = 'FINISHED'
        elif tag == 'tr':
            # add this member to the list (unless there were no <td>s,
            # in which case, it was just the header...
            if self._td_count > 0:
                self.table.append(self._current_member)
        elif tag == 'td':
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
    #-----------------------------
    def tidy_data( self ):
        return ' '.join( self._data.strip().replace('*','').split() )

#=================================
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
        
        self.email = None
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
 
## #=================================
## class NICVAPageParser( HTMLParser ):
    
##     HONORIFICS = ["Dr", "Rev", "Mr", "Mrs", "Miss", "Ms"]
    
##     #-----------------------------
##     def __init__( self ):
##         HTMLParser.__init__( self )
##         self._state = 'START'
##         self._data = ''
##         self._currentConstituency = ''
##         self.MIAs = []
##     #-----------------------------
##     def handle_starttag( self, tag, attrs ):
##         #print tag
##         #print self._state
##         if self._state in ['CONTENT', 'MLA'] and tag == 'strong':
##             self._state = 'CONSTITUENCY'
##         elif self._state == 'CONTENT' and tag == 'p':
##             self._state = 'MLA'
##         elif self._state in ['CONTENT', 'MLA'] and tag == 'br':
##             self._state = 'END'
##     #-----------------------------
##     def handle_endtag( self, tag ):       
##         #<strong>MLAs</strong>
##         text = self.tidy_data()
##         if self._state == 'START' and tag == 'strong':
##             if text == "MLAs":
##                 self._state = 'CONTENT'
##         elif self._state == 'CONSTITUENCY' and tag == 'strong':
##             self._currentConstituency = text
##             self._state = 'CONTENT'
##         elif self._state == 'MLA' and (( tag == 'a' ) or ( tag == 'p' )) and text:
##             ( forename, surname, party, email ) = self.extract_fields( text )
##             self.MIAs.append( ( forename, surname, party, email, self._currentConstituency ) ) 
##             self._state = 'CONTENT'    
##         self._data = ''           
##     #-----------------------------
##     def tidy_data( self ):
##         return ' '.join( self._data.strip().replace(',','').split() )
##     #-----------------------------
##     def handle_data( self, data ):
##         self._data += data
##     #-----------------------------
##     def extract_fields( self, data ):
            
##         words = data.split()
##         # strip any honorific
##         if words[0] in self.HONORIFICS:
##             words = words[1:]
            
##         #pop the first word - always firstname
##         forename = words[0]
##         words = words[1:]
            
##         #pop the last word - always email
##         email = words[-1]
##         words = words[:-1]
            
##         #use heuristics to figure out what is
##         #name and what is party from the remaining words
##         if len(words) == 1:
##             surname = words[0]
##             party = ''
##         elif len(words) == 2:
##             surname = words[0]
##             party = words[1]
##         elif len(words) == 3:
##             surname = " ".join(words[:2])
##             party = words[2]
##         #clean up any slashes in the email field
##         if email:
##             email = email.replace("/", " ")
##         return ( forename, surname, party, email )
    
## #=================================
def parseNIAssemblySite():
    
    f = open( NIA_OUTPUT_FILE, 'w' )
    
    page = urlopen( NIA_LIST_PAGE )

    parser = NIATableParser()

    # the <head> section is a bit broken - we'd
    # better discard it...
    good_html = discard_head(page.read())
    parser.feed(good_html)
    
    #crop the first header row
    assembly_members = parser.table

    f.write( "First\tLast\tConstituency\tParty\tEmail\tFax\tImage\n" )
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
        # It may an well work for any other JNRs who appear in the future.
        
        rsplit_name = member.name.rsplit(' ', 1)
        
        if rsplit_name[1] == "JNR":
            split_again = rsplit_name[0].rsplit(' ', 1)
            member.surname = split_again[0]
            member.forename = split_again[1]+' '+'JNR'
        else:
            member.surname, member.forename = tuple(member.name.rsplit(' ',1))
        member.email = member.email.strip()
        
        f.write( '%s\t%s\t%s\t%s\t%s\t\t%s\n' % ( member.forename,
                                                  member.surname,
                                                  member.constituency,
                                                  member.party,
                                                  member.email,
                                                  member.image_url))

        # I'm not sure which of the file and stdout is being used,
        # so I guess we had better print this stuff to stdout too
        # as it used to be when the NICVA site was being used.
        print '"%s","%s","%s","%s","%s","","%s"' % (realNameCase(member.forename),
                                                    realNameCase(member.surname), 
                                                    realNameCase(member.constituency), 
                                                    member.party, 
                                                    member.email, 
                                                    member.image_url) 
    f.close()
## #-------------------------------------------------------
## def parseNICVASite():
    
##     f = open( NICVA_OUTPUT_FILE, 'w')
##     page = urlopen( NICVA_LIST_PAGE )
##     parser = NICVAPageParser()
##     parser.feed( page.read() )
    
##     f.write( "First\tLast\tConstituency\tParty\tEmail\tFax\tImage\n" )
##     for forename, surname, party, email, constituency in parser.MIAs:
        
##         f.write( '%s\t%s\t%s\t%s\t%s\t\t%s\n' % ( forename, surname, constituency, party, email or "", "" ))
##     f.close()
    
## #-------------------------------------------------------
## def outputFileToList( filename ):
    
##     file = open( filename )
##     #crop the header and make each line a list
##     lines = file.readlines()[1:]
##     lines = [ line.replace('\n','').split('\t') for line in lines ]
    
##     file.close()
##     return lines
    
#-------------------------------------------------------
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
#-------------------------------------------------------    
## def normalizeConstituencies():
    
##     niaLines = outputFileToList( NIA_OUTPUT_FILE )
##     nicvaLines = outputFileToList( NICVA_OUTPUT_FILE )
    
##     #get a distinct list of constituency names from NIA
##     niaConstituencies = set([ line[2]  for line in niaLines ])
   
##     #get a distinct list of constituency names from NICVA
##     nicvaConstituencies = set([line[2].upper() for line in nicvaLines ])
    
##     print "All distinct NIA constituencies",   niaConstituencies
##     print "All distinct NICVA constituencies", nicvaConstituencies
##     print "NICVA constituencies not in NIA",   nicvaConstituencies - niaConstituencies
##     print "NIA constituencies not in NICVA",   niaConstituencies - nicvaConstituencies

## #-------------------------------------------------------
## def mergeData():        
    
##     #set of mappings from the names used by each source for 
##     #constituencies to a standard where differences exist -
##     #generated using the normalizeConstituencies method above. 
##     #both lists are being normalized against standard names as there's 
##     #some variance in the names used at NIA
##     normalizedConstits = {"FERMANAGH AND SOUTH TYRONE":  "FERMANAGH/SOUTH TYRONE",
##                           "MID ULSTER":                  "MID-ULSTER",
##                           "EAST BELFAST":                "BELFAST EAST",
##                           "SOUTH BELFAST":               "BELFAST SOUTH",
##                           "NORTH BELFAST":               "BELFAST NORTH",
##                           "WEST BELFAST":                "BELFAST WEST"}
                          
##     #set of mappings between lexical name variations between the
##     #two sources. The NICVA list is being normalized to the NIA standard
##     normalizedForenames = {"RAYMON":                       "RAYMOND",
##                            "FRANCIE":                      "FRANCIS",
##                            "ALEXANDER":                    "ALEX",
##                            "PJ":                           "P J",
##                            "MITCHELL":                     "MITCHEL",
##                            "KIERAN":                       "KEIRAN",
##                            "PAT":                          "PATRICIA",
##                            "HUGH":                         "TOM", # NICVA seems to have the wrong forename altogether for tom o'reilly
##                            "IAN":                          "IAN Jnr"} 
   
##     normalizedSurnames = { "PAISLEY JNR":                  "PAISLEY"}
    
##     # dictionary of known incorrect emails from NICVA, keyed by surname, forename,
##     #consituency combination
##     emailBlacklist = {"BELLBILLYLAGAN VALLEY":    ["billy@billyarmstrong.co.uk"]} #NICVA has the wrong Billy
   
##     niaDict = {}
##     nicvaDict = {}
##     niaConstituencies = []
##     nicvaConstituencies = []
    
##     niaLines = outputFileToList( NIA_OUTPUT_FILE )
##     nicvaLines = outputFileToList( NICVA_OUTPUT_FILE )
    
    
##     # normalize NICVA data to uppercase
##     nicvaLines = [ (forename.upper(), surname.upper(), constituency.upper(), party, email, fax, imgUrl) for (forename, surname, constituency, party, email, fax, imgUrl) in nicvaLines]
    
##     # make a dictionary of the nia data
##     for (forename, surname, constituency, party, email, fax, imgUrl) in niaLines:
##         key = surname.replace("'","") + forename + normalizedConstits.get(constituency, constituency)
##         niaDict[key] = (forename, surname, constituency, party, email, fax, imgUrl)
##         niaConstituencies.append(normalizedConstits.get(constituency, constituency))
        
##     # make a dictionary of the nicva data, normalizing forenames and 
##     # constituencies where necessary
##     for (forename, surname, constituency, party, email, fax, imgUrl) in nicvaLines:
##         key = surname + forename  + normalizedConstits.get(constituency, constituency)
##         if key not in niaDict.keys():
##             key = normalizedSurnames.get(surname, surname) + normalizedForenames.get(forename, forename) + normalizedConstits.get(constituency, constituency)
##         nicvaDict[key] = (forename, surname, constituency, party, email, fax, imgUrl)
##         nicvaConstituencies.append(normalizedConstits.get(constituency, constituency))
    
##     matches = 0
##     final_records = 0
    
##     #check that we have 18 consituencies
##     niaConstituencies = set(niaConstituencies)
   
##     if len(niaConstituencies) != 18:
##         raise StandardError, "Expected 18 constituencies from NIA, got %d" %  len(niaConstituencies) 
   
##     nicvaConstituencies = set(nicvaConstituencies)
   
##     if len(nicvaConstituencies) != 18:
##         raise StandardError, "Expected 18 constituencies from NICVA, got %d" %  len(nicvaConstituencies) 
 
##     #check that we have 108 MLAs
##     if len(niaDict.keys()) != 108:
##         raise StandardError, "Expected 108 MLAs from NIA, got %d" % len(niaDict.keys()) 
   
##     if len(nicvaDict.keys()) != 108:
##         raise StandardError, "Expected 108 MLAs from NICVA, got %d" % len(nicvaDict.keys()) 
   
##     print '"Forename","Surname","Consituency","Party","Email","Fax","Image URL"' 
    
##     for niaKey  in niaDict.keys():
        
##         niaData = niaDict[niaKey]
##         (niaForename, niaSurname, niaConstituency, niaParty, niaEmail, niaFax, niaImgUrl) = niaData
        
##         niaDict.pop(niaKey)
##         final_records += 1
##         if  niaKey in nicvaDict.keys():
##             matches += 1
            
##             # pull data from both sources on this match
##             nicvaData = nicvaDict[niaKey]
##             (nicvaForename, nicvaSurname, nicvaConstituency, nicvaParty, nicvaEmail, nicvaFax, nicvaImgUrl) = nicvaData
            
##             #clean up NICVA emails using blacklist
##             nicvaEmailList = [ email for email in nicvaEmail.split() if email not in emailBlacklist.get(niaKey, [])]
            
##             # combine all the emails we've found, use nicva ones as preference (list more maintained than nia).
##             # remove duplicates, but preserve order
##             combinedEmail = " ".join( uniq_preserve_order([email.lower() for email in nicvaEmailList + niaEmail.split()] ))
##             nicvaDict.pop(niaKey)
##         else:
##             #can't match - just go with NIA
##             combinedEmail = " ".join( set([email.lower() for email in niaEmail.split()]))
##         normCons = normalizedConstits.get(niaConstituency, niaConstituency)
##         #print data to output, giving preference to NIA data, but listing all emails
##         print '"%s","%s","%s","%s","%s","","%s"' % (realNameCase(niaForename),
##                                                     realNameCase(niaSurname), 
##                                                     realNameCase(normCons), 
##                                                     niaParty, 
##                                                     combinedEmail, 
##                                                     niaImgUrl) 
            
        
##     #diagnostic: print some summary info and the unmatched records 
##     #print "Matches: ", matches
##     #print "Final records: ", final_records
##     #print "Unmatched records: "
##     #print "NICVA"
##     #print nicvaDict.values()
   
#-------------------------------------------------------
if __name__ == '__main__':
    
    # get the data from the live URLS and output the data from
    # each site into a file with a consistent format
    parseNIAssemblySite()

    # This site is not currently being kept up to date.
    #parseNICVASite()
 
    #this function can be used to identify lexical differences
    #in constituency names
    #normalizeConstituencies()
    
    #merge the information from the files
    #mergeData() 
