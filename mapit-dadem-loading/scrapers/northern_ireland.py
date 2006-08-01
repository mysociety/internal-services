#! /usr/bin/env python2.4
#
# northern_ireland.py:
# Screen scrape representatives from Northern Ireland assembly website, 
# Northern Ireland Council for Voluntary Action website, and merge.
# 
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: louise.crow@gmail.com; WWW: http://www.mysociety.org/
#

#=================================

from urllib2 import urlopen
from urlparse import urljoin
from HTMLParser import HTMLParser
from sys import stderr
import re
import string

NIA_LIST_PAGE = "http://www.niassembly.gov.uk/members/membership03.htm"
NICVA_LIST_PAGE = "http://www.nicva.org/index.cfm/section/General/key/190805"
NIA_OUTPUT_FILE = "nia_out.txt"
NICVA_OUTPUT_FILE = "nicva_out.txt"

# order preserving unique
def uniq_preserve_order(alist):
    s = {}
    return [s.setdefault(e,e) for e in alist if e not in s]
         
#=================================
class NIATableParser( HTMLParser ):
    """Ignore outer table and pull data from inner table"""
    #-----------------------------
    def __init__( self ):
        HTMLParser.__init__( self )
        self._state = 'START'
        self._data = ''
        self._url = None
        self.table = None
    #-----------------------------
    def handle_starttag( self, tag, attrs ):
        if self._state == 'PREAMBLE' and tag == 'table':
            self._state = 'CONTENT'
        elif self._state == 'CONTENT' and tag == 'table':
            self._state = 'TABLE'
            self.table = []
        elif self._state == 'TABLE' and tag == 'tr':
            self._state = 'ROW'
            self._currentRow = []
        elif self._state == 'ROW' and tag == 'td':
            self._state = 'COLUMN'
            self._data = ''
            self._url = None
        elif self._state == 'COLUMN' and tag == 'a':
            self._url = [ value for key, value in attrs if key == 'href' ][0]
            
        elif self._state == 'CONTENT' and tag == 'img':
             srcs = [ value for key, value in attrs if key == 'src' ]
             if srcs:
                 self.imgUrl = hrefs[0]
        
    #-----------------------------
    def handle_endtag( self, tag ):       
        if self._state == 'ROW' and tag == 'tr':
            self._state = 'TABLE'
            if self._currentRow:
                self.table.append( self._currentRow )
        elif self._state == 'COLUMN' and tag == 'td':
            self._state = 'ROW'
            self._currentRow.append( self.tidy_data() )
            if self._url:
                self._currentRow.append( (self._url ) )
        elif self._state == 'TABLE' and tag == 'table':
            self._state = 'CONTENT'
    #-----------------------------
    def handle_data( self, data ):
        self._data += data
    #-----------------------------
    def handle_entityref( self, ref ):
        if ref == 'nbsp':
            self._data += ' '
        elif ref == 'amp':
            self._data += '&'
        
    #-----------------------------
    def handle_comment( self, comment ):
        if comment == ' #BeginEditable "data" ':
            self._state = 'PREAMBLE'
        elif comment == ' #EndEditable ' and self._state == 'CONTENT':
            self._state = 'END'
    #-----------------------------
    def tidy_data( self ):
        return ' '.join( self._data.strip().replace('*','').split() )

#=================================
class NIADetailPageParser( HTMLParser ):
    
    #-----------------------------
    def __init__( self ):
        HTMLParser.__init__( self )
        self._state = 'START'
        self._data = ''
        self.table = []
        self.email = None
        self.imgUrl = None
    #-----------------------------
    def handle_comment( self, comment ):
        if comment == ' #BeginEditable "data" ':
            self._state = 'CONTENT'
        elif comment == ' #EndEditable ':
            self._state = 'END'
    #-----------------------------
    def handle_starttag( self, tag, attrs ):
      if self._state == 'CONTENT' and tag == 'table':
          self._state = 'TABLE'
      elif self._state == 'TABLE' and tag == 'tr':
          self._state = 'ROW'
          self._currentRow = []
      elif self._state == 'ROW' and tag == 'td':
          self._state = 'COLUMN'
          self._data = ''
      elif self._state == 'COLUMN' and tag == 'img':
             srcs = [ value for key, value in attrs if key == 'src' ]
             if srcs:
                 self.imgUrl = srcs[0]
        
    #-----------------------------
    def handle_endtag( self, tag ):       
        if self._state == 'ROW' and tag == 'tr':
            self._state = 'TABLE'
            if self._currentRow:
                self.table.append( self._currentRow )
        elif self._state == 'COLUMN' and tag == 'td':
            self._state = 'ROW'
            text = self.tidy_data()
            if text: self._currentRow.append( text )
        elif self._state == 'TABLE' and tag == 'table':
            for line in self.table:
                if line[0] == 'E-Mail Address:' and len(line) >1:
                    self.email = line[1] 
            self._state = 'CONTENT'             
    #-----------------------------
    def tidy_data( self ):
        return ' '.join( self._data.strip().split() )
    #-----------------------------
    def handle_data( self, data ):
        self._data += data
 
#=================================
class NICVAPageParser( HTMLParser ):
    
    HONORIFICS = ["Dr", "Rev", "Mr", "Mrs", "Miss", "Ms"]
    
    #-----------------------------
    def __init__( self ):
        HTMLParser.__init__( self )
        self._state = 'START'
        self._data = ''
        self._currentConstituency = ''
        self.MIAs = []
    #-----------------------------
    def handle_starttag( self, tag, attrs ):
        #print tag
        #print self._state
        if self._state in ['CONTENT', 'MLA'] and tag == 'strong':
            self._state = 'CONSTITUENCY'
        elif self._state == 'CONTENT' and tag == 'p':
            self._state = 'MLA'
        elif self._state in ['CONTENT', 'MLA'] and tag == 'br':
            self._state = 'END'
    #-----------------------------
    def handle_endtag( self, tag ):       
        #<strong>MLAs</strong>
        text = self.tidy_data()
        if self._state == 'START' and tag == 'strong':
            if text == "MLAs":
                self._state = 'CONTENT'
        elif self._state == 'CONSTITUENCY' and tag == 'strong':
            self._currentConstituency = text
            self._state = 'CONTENT'
        elif self._state == 'MLA' and (( tag == 'a' ) or ( tag == 'p' )) and text:
            ( forename, surname, party, email ) = self.extract_fields( text )
            self.MIAs.append( ( forename, surname, party, email, self._currentConstituency ) ) 
            self._state = 'CONTENT'    
        self._data = ''           
    #-----------------------------
    def tidy_data( self ):
        return ' '.join( self._data.strip().replace(',','').split() )
    #-----------------------------
    def handle_data( self, data ):
        self._data += data
    #-----------------------------
    def extract_fields( self, data ):
            
        words = data.split()
        # strip any honorific
        if words[0] in self.HONORIFICS:
            words = words[1:]
            
        #pop the first word - always firstname
        forename = words[0]
        words = words[1:]
            
        #pop the last word - always email
        email = words[-1]
        words = words[:-1]
            
        #use heuristics to figure out what is
        #name and what is party from the remaining words
        if len(words) == 1:
            surname = words[0]
            party = ''
        elif len(words) == 2:
            surname = words[0]
            party = words[1]
        elif len(words) == 3:
            surname = " ".join(words[:2])
            party = words[2]
        #clean up any slashes in the email field
        if email:
            email = email.replace("/", " ")
        return ( forename, surname, party, email )
    
#=================================
def parseNIAssemblySite():
    
    f = open( NIA_OUTPUT_FILE, 'w' )
    
    page = urlopen( NIA_LIST_PAGE )
    parser = NIATableParser()
    parser.feed( page.read() )
    
    #crop the first header row
    assembly_members = parser.table[1:]

    f.write( "First\tLast\tConstituency\tParty\tEmail\tFax\tImage\n" )
    
    for details in assembly_members:
        email = None
        imgUrl = None
        
        #case where a url is given
        if len(details) == 5:
            surname, url, forename, party, constituency = details
            url = urljoin( NIA_LIST_PAGE, url )
            page = urlopen( url )
            parser = NIADetailPageParser()
            parser.feed( page.read() )
            
            email = parser.email
            
            if parser.imgUrl:
                imgUrl = urljoin( url, parser.imgUrl)
        #case where no url is given
        elif len(details) == 4:
            surname, forename, party, constituency = details
        # extra fields or fields missing 
        else: 
             raise StandardError, "Unexpected number of info fields for MP "   
        constituency = constituency.split( '(', 1 )[0].strip()
      
        f.write( '%s\t%s\t%s\t%s\t%s\t\t%s\n' % ( forename, surname, constituency, party, email or "", imgUrl or "" ))
    f.close()
#-------------------------------------------------------
def parseNICVASite():
    
    f = open( NICVA_OUTPUT_FILE, 'w')
    page = urlopen( NICVA_LIST_PAGE )
    parser = NICVAPageParser()
    parser.feed( page.read() )
    
    f.write( "First\tLast\tConstituency\tParty\tEmail\tFax\tImage\n" )
    for forename, surname, party, email, constituency in parser.MIAs:
        
        f.write( '%s\t%s\t%s\t%s\t%s\t\t%s\n' % ( forename, surname, constituency, party, email or "", "" ))
    f.close()
    
#-------------------------------------------------------
def outputFileToList( filename ):
    
    file = open( filename )
    #crop the header and make each line a list
    lines = file.readlines()[1:]
    lines = [ line.replace('\n','').split('\t') for line in lines ]
    
    file.close()
    return lines
    
#-------------------------------------------------------
def realNameCase( name ):
        #Should cover people and place names
        words = re.split("(/| AND | |-|')", name)
        words = [ string.capitalize(word) for word in words ]

        def handlescottish(word):
            if (re.match("Mc[a-z]", word)):
                return word[0:2] + string.upper(word[2]) + word[3:]
            if (re.match("Mac[a-z]", word)):
                return word[0:3] + string.upper(word[3]) + word[4:]
            return word
        words = map(handlescottish, words)

        return string.join(words , "")
#-------------------------------------------------------    
def normalizeConstituencies():
    
    niaLines = outputFileToList( NIA_OUTPUT_FILE )
    nicvaLines = outputFileToList( NICVA_OUTPUT_FILE )
    
    #get a distinct list of constituency names from NIA
    niaConstituencies = set([ line[2]  for line in niaLines ])
   
    #get a distinct list of constituency names from NICVA
    nicvaConstituencies = set([line[2].upper() for line in nicvaLines ])
    
    print "All distinct NIA constituencies",   niaConstituencies
    print "All distinct NICVA constituencies", nicvaConstituencies
    print "NICVA constituencies not in NIA",   nicvaConstituencies - niaConstituencies
    print "NIA constituencies not in NICVA",   niaConstituencies - nicvaConstituencies

#-------------------------------------------------------
def mergeData():        
    
    #set of mappings from the names used by each source for 
    #constituencies to a standard where differences exist -
    #generated using the normalizeConstituencies method above. 
    #both lists are being normalized against standard names as there's 
    #some variance in the names used at NIA
    normalizedConstits = {"FERMANAGH AND SOUTH TYRONE":  "FERMANAGH/SOUTH TYRONE",
                          "MID ULSTER":                  "MID-ULSTER",
                          "EAST BELFAST":                "BELFAST EAST",
                          "SOUTH BELFAST":               "BELFAST SOUTH",
                          "NORTH BELFAST":               "BELFAST NORTH",
                          "WEST BELFAST":                "BELFAST WEST"}
                          
    #set of mappings between lexical name variations between the
    #two sources. The NICVA list is being normalized to the NIA standard
    normalizedForenames = {"RAYMON":                       "RAYMOND",
                           "FRANCIE":                      "FRANCIS",
                           "ALEXANDER":                    "ALEX",
                           "PJ":                           "P J",
                           "MITCHELL":                     "MITCHEL",
                           "KIERAN":                       "KEIRAN",
                           "PAT":                          "PATRICIA",
                           "HUGH":                         "TOM", # NICVA seems to have the wrong forename altogether for tom o'reilly
                           "IAN":                          "IAN Jnr"} 
   
    normalizedSurnames = { "PAISLEY JNR":                  "PAISLEY"}
    
    # dictionary of known incorrect emails from NICVA, keyed by surname, forename,
    #consituency combination
    emailBlacklist = {"BELLBILLYLAGAN VALLEY":    ["billy@billyarmstrong.co.uk"]} #NICVA has the wrong Billy
   
    niaDict = {}
    nicvaDict = {}
    niaConstituencies = []
    nicvaConstituencies = []
    
    niaLines = outputFileToList( NIA_OUTPUT_FILE )
    nicvaLines = outputFileToList( NICVA_OUTPUT_FILE )
    
    
    # normalize NICVA data to uppercase
    nicvaLines = [ (forename.upper(), surname.upper(), constituency.upper(), party, email, fax, imgUrl) for (forename, surname, constituency, party, email, fax, imgUrl) in nicvaLines]
    
    # make a dictionary of the nia data
    for (forename, surname, constituency, party, email, fax, imgUrl) in niaLines:
        key = surname.replace("'","") + forename + normalizedConstits.get(constituency, constituency)
        niaDict[key] = (forename, surname, constituency, party, email, fax, imgUrl)
        niaConstituencies.append(normalizedConstits.get(constituency, constituency))
        
    # make a dictionary of the nicva data, normalizing forenames and 
    # constituencies where necessary
    for (forename, surname, constituency, party, email, fax, imgUrl) in nicvaLines:
        key = surname + forename  + normalizedConstits.get(constituency, constituency)
        if key not in niaDict.keys():
            key = normalizedSurnames.get(surname, surname) + normalizedForenames.get(forename, forename) + normalizedConstits.get(constituency, constituency)
        nicvaDict[key] = (forename, surname, constituency, party, email, fax, imgUrl)
        nicvaConstituencies.append(normalizedConstits.get(constituency, constituency))
    
    matches = 0
    final_records = 0
    
    #check that we have 18 consituencies
    niaConstituencies = set(niaConstituencies)
   
    if len(niaConstituencies) != 18:
        raise StandardError, "Expected 18 constituencies from NIA, got %d" %  len(niaConstituencies) 
   
    nicvaConstituencies = set(nicvaConstituencies)
   
    if len(nicvaConstituencies) != 18:
        raise StandardError, "Expected 18 constituencies from NICVA, got %d" %  len(nicvaConstituencies) 
 
    #check that we have 108 MLAs
    if len(niaDict.keys()) != 108:
        raise StandardError, "Expected 108 MLAs from NIA, got %d" % len(niaDict.keys()) 
   
    if len(nicvaDict.keys()) != 108:
        raise StandardError, "Expected 108 MLAs from NICVA, got %d" % len(nicvaDict.keys()) 
   
    print '"Forename","Surname","Consituency","Party","Email","Fax","Image URL"' 
    
    for niaKey  in niaDict.keys():
        
        niaData = niaDict[niaKey]
        (niaForename, niaSurname, niaConstituency, niaParty, niaEmail, niaFax, niaImgUrl) = niaData
        
        niaDict.pop(niaKey)
        final_records += 1
        if  niaKey in nicvaDict.keys():
            matches += 1
            
            # pull data from both sources on this match
            nicvaData = nicvaDict[niaKey]
            (nicvaForename, nicvaSurname, nicvaConstituency, nicvaParty, nicvaEmail, nicvaFax, nicvaImgUrl) = nicvaData
            
            #clean up NICVA emails using blacklist
            nicvaEmailList = [ email for email in nicvaEmail.split() if email not in emailBlacklist.get(niaKey, [])]
            
            # combine all the emails we've found, use nicva ones as preference (list more maintained than nia).
            # remove duplicates, but preserve order
            combinedEmail = " ".join( uniq_preserve_order([email.lower() for email in nicvaEmailList + niaEmail.split()] ))
            nicvaDict.pop(niaKey)
        else:
            #can't match - just go with NIA
            combinedEmail = " ".join( set([email.lower() for email in niaEmail.split()]))
        normCons = normalizedConstits.get(niaConstituency, niaConstituency)
        #print data to output, giving preference to NIA data, but listing all emails
        print '"%s","%s","%s","%s","%s","","%s"' % (realNameCase(niaForename),
                                                    realNameCase(niaSurname), 
                                                    realNameCase(normCons), 
                                                    niaParty, 
                                                    combinedEmail, 
                                                    niaImgUrl) 
            
        
    #diagnostic: print some summary info and the unmatched records 
    #print "Matches: ", matches
    #print "Final records: ", final_records
    #print "Unmatched records: "
    #print "NICVA"
    #print nicvaDict.values()
   
#-------------------------------------------------------
if __name__ == '__main__':
    
    # get the data from the live URLS and output the data from
    # each site into a file with a consistent format
    parseNIAssemblySite()
    parseNICVASite()
 
    #this function can be used to identify lexical differences
    #in constituency names
    #normalizeConstituencies()
    
    #merge the information from the files
    mergeData() 
