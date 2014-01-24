#!/usr/bin/perl
#
# scrapers/manchester_scraper.pl
# Manchester council requires a separate contact address for Labour and Lib
# Dem members, so our via democratic services doesn't work. This scraper
# gets the addresses for Manchester councillors.
#
# Example use:
#./lord ~/devel/parlparse/members/peers-ucl.xml ~/devel/parlparse/members/people.xml ~/devel/repdata/mysociety/lords.csv
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: s@msmith.net; WWW: http://www.mysociety.org/
#

die "This doesn't quite work yet - doesn't return all councillors";

my $Site_Base='http://www.manchester.gov.uk/localdemocracy/councillors/';
my $Front_Door=$Site_Base.'ward.htm';



use warnings;
use strict;

use LWP::UserAgent;
my $ua = LWP::UserAgent->new;



{
	$ua->cookie_jar({});
	$ua->agent('WriteToThem.com councillor scraper - visit www.writetothem.com or mail team@writetothem.com');
        my $response= $ua->get($Front_Door);
        if ($response->is_success)  {
        print "ID,First,Last,Ward,Council,Party,Fax,Email,CouncilFax,CouncilEmail\n";
		&parse_mcr_ward_index($response->content);
        } else {
                die "$0: fetch of $Front_Door failed";
        }
}



sub parse_mcr_ward_index {
	my $content=shift;
	# there's a single list on the page
	while ($content=~ m#<li><a href="([^"]+)">([^<]+)</a></li>#cg) {
		&parse_mcr_ward_page($1, $2);
	}

}


sub parse_mcr_ward_page {
	$|=1;
	my ($page, $ward)= @_;
	my %seen;
        my $response= $ua->get($Site_Base . $page);
        if ($response->is_success)  {
		my ($line, $email, $name);
		my @m= $response->content =~ m#(<a [^>]*href="mailto:([^@]*\@[^"]+)" name=[^>]*>([^<]+))<#gci;

		while (($line, $email, $name, @m)= @m) {
			next if $email =~ m#committeeservices#i; # gets in the way
			next if (defined $seen{$email}); # been here before.

			my $unreliable='';
			$name=~ s#^\s+##g;
			$name=~ s#\s+$##g;
			$name=~ s#\s+# #;

			if ($email eq $name) {
				if ($name=~ m#(?:cllr\.)?(\w+)\.([^\@]+)\@manchester\.gov\.uk#) { # usually initial.surname
					$name= uc($1) .' '. ucfirst($2);
				} else {
					$unreliable='attn required'; # if not, then flag it for attention
				}
			} elsif ($name =~ /\@/) {
				$unreliable='attn required'; # if not, then flag it for attention
			}
            if ($unreliable eq 'attn required') {
#            $email.=$unreliable;
#                die "Didn't scrape Manchester councillor $name well\n$Site_Base$page";
            }

            die "missing email or name in:\n$line" if (!$email || !$name);

            $name =~ m/^([^ ]+) (.+)$/;
            my $first = $1;
            my $last = $2;
            die "name split failed in:\n$line" if (!$first || !$last);

            die "no ward" if !$ward;

            my $party = "";
            my $id = "";
            print '"'.$id.'","'.$first.'","'.$last.'","'.$ward.'","Manchester City Council","'.$party.'","","'.$email.'","",""'."\n";

			$seen{$email}=$name;
		}
        } else {
                die "$0: fetch of $Site_Base$page failed";
	}
}

