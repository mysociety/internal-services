#!/usr/bin/env python

# This script outputs a CSV file of current UK MEPs scraped from
# http://www.europarl.org.uk/en/your_meps.html to standard output.

from csv import DictWriter
import hashlib
import json
from optparse import OptionParser
import os
import re
import sys
import urllib2
import urlparse

from bs4 import BeautifulSoup
from bs4.element import Tag

parser = OptionParser()
parser.add_option(
    "-c", "--cache-directory",
    dest="cache_directory",
    help="use DIRECTORY as a cache for downloaded HTML",
    metavar="DIRECTORY",
    default='cache'
)

options, args = parser.parse_args()

if len(args):
    parser.print_help()
    sys.exit(1)

host = 'www.europarl.org.uk'
regions_path = '/en/your_meps.html'

expected_region_counts = {
    'East Midlands': 5,
    'Eastern': 7,
    'London': 8,
    'North East': 3,
    'North West': 8,
    'Northern Ireland': 3,
    'Scotland': 6,
    'South East': 10,
    'South West': 6,
    'Wales': 4,
    'West Midlands': 7,
    'Yorkshire and the Humber': 6
}

expected_regions = expected_region_counts.keys()

honorifics = ('Ms', 'Mrs', 'Rt. Hon. Sir', 'Mr', 'Dr', 'Baroness')
honorifics_re = re.compile(
    '^\s*(' +'|'.join(re.escape(h) for h in honorifics) + ')\s*'
)

def get_url_cached(url):
    """GET a URL, caching the result for future runs of the script"""
    cached_filename = os.path.join(
        options.cache_directory,
        hashlib.md5(url).hexdigest()
    )
    if os.path.exists(cached_filename):
        with open(cached_filename) as f:
            return f.read()
    else:
        response = urllib2.urlopen(url)
        data = response.read()
        with open(cached_filename, 'w') as f:
            f.write(data)
        return data

def make_url(path, params=''):
    return urlparse.urlunsplit(
    ('http', host, path, params, '')
)

all_regions_url = make_url(regions_path)
all_region_soup = BeautifulSoup(get_url_cached(all_regions_url))
content_div = all_region_soup.find(id='content')

def tidy_region_name(region_name):
    result = region_name.replace(' Region', '')
    return result.replace('Noth', 'North')

def tidy_party(party):
    # Strip any abbreviation in parentheses:
    return re.sub(r'\(.*?\)', '', party).strip()

csv_headers = [
    'First', 'Last', 'Constituency', 'Party', 'Email', 'Fax', 'Image'
]

csv_writer = DictWriter(sys.stdout, fieldnames=csv_headers, lineterminator='\n')
csv_writer.writeheader()

for region_link in content_div.find_all('a', {'class': 'simple'}):
    region_name = tidy_region_name(region_link.text).strip()
    region_url = make_url(region_link['href'])
    region_soup = BeautifulSoup(get_url_cached(region_url))
    meps_found = 0
    for mep_soup in region_soup('div', {'class': re.compile('standard')}):
        image_element = mep_soup.find('img')
        # The name is in the span immediately after the image:
        sibling_tags = [
            i for i in image_element.next_siblings
            if isinstance(i, Tag)
        ]
        full_name = honorifics_re.sub('', sibling_tags[0].text)
        name_match = re.search(r'^\s*(\S+)\s+(.*)', full_name)
        # Assume there's only one first name and possibly multiple
        # last names, as the previous script did:
        first_name, last_names = name_match.groups()
        # Look for the party affiliation:
        party_match = re.search(
            r'(?ims)National\s+party\s*:\s*(.*?)\n',
            mep_soup.text
        )
        if party_match:
            party = tidy_party(party_match.group(1))
        else:
            if first_name == 'Amjad' and last_names == 'Bashir':
                party = 'United Kingdom Independence Party'
            elif first_name == 'Richard' and last_names == 'Corbett':
                party = 'Labour Party'
            else:
                message = "Warning: couldn't find the party for {0} {1}"
                print >> sys.stderr, message.format(first_name, last_names)
                party = ''
        # Find any email addreses - in fact, we only use the first
        # one.
        mailto_links = mep_soup.find_all(
            'a',
            {'href': re.compile(r'^mailto:')}
        )
        email_addresses = [
            re.sub(r'^mailto:(\S+).*', r'\1', a['href']).strip()
            for a in mailto_links
        ]
        row = {
            'Image': make_url(image_element['src']),
            'First': first_name.strip().encode('utf-8'),
            'Last': last_names.strip().encode('utf-8'),
            'Constituency': region_name,
            'Party': party.encode('utf-8'),
            'Email': email_addresses[0],
            'Fax': ''
        }
        csv_writer.writerow(row)
        meps_found += 1
    if meps_found != expected_region_counts[region_name]:
        message = "Unexpected number of MEPs found for {0}: expected {1}, but found {2}"
        print >> sys.stderr, message.format(
            region_name, expected_region_counts[region_name], meps_found
        )
