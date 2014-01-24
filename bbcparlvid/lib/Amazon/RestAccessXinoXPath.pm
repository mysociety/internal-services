#!/usr/bin/perl

package Amazon::RestAccessXinoXPath;

use strict;

use HTTP::Headers;
use HTTP::Request;
use HTTP::Response;
use LWP::Simple;
use Time::HiRes qw(gettimeofday);
use XML::Simple;
use XML::XPath;


##
## CONSTRUCTOR
##
sub new {
  my ($class) = @_;
  
  my $self = bless {
		   }, $class;
  
  return $self;
}

##
## 'PUBLIC' METHODS
##


sub make_query {
  # accept: country, test/live, API version, & AWS xml/http call
  # return: webserver response time, http code, request type (unused?) & XML reply from AWS
  my ($self, $url, $query_string, $verb, $param_hash_ref, $security_params, $body_string) = @_;
  
  # set the header
  my $header = HTTP::Headers->new('Authorization' => $security_params->{'auth_string'});
  $header->header(
                  'AWS-Version' => "2006-04-01",
                  'Content-Md5' => $security_params->{'md5_signature'},
                  'Content-Type' => $security_params->{'content_type'},
                  'Date' => $security_params->{'date'},
                 );
  
  # hard code REST path
  my $full_url = "$url";

  # get rid of weird error
  unless ($query_string) {
      $query_string = '';
  }

   # now compile the full URL
  my $url_string = $full_url . $query_string;

  # push query, grab result
  my $browser = new LWP::UserAgent;
  my $request = new HTTP::Request($verb, $url_string, $header, $body_string);
  my ($raw_response, $xpath_response);
  my ($t0, $t1);
  eval {
    $t0 = gettimeofday * 1000;
    $raw_response = $browser->request($request);
    $t1 = gettimeofday * 1000;
  };
  
  my $elapsed_msecs = $t1 - $t0;
  my $response_code = $raw_response->status_line();
  
  if ($raw_response) {
    eval {
      $xpath_response = XML::XPath->new(xml => $raw_response->content());
    }
  } else {
    print "No response for this test\n";
  }
  
  
  # package data for return
  return $xpath_response;
  
}

1;
