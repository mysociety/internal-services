Overview
----------
There are two command-line sample applications provided that demonstrate the Amazon SQS API. These applications exercise the main API actions: creating a queue, sending a message, listing the queues, retrieving a message, and deleting a message.


Configuration
----------------
If you just run any of the two sample applications without modifying them, you'll only get the following error message:
"update QueueServiceMethods.pm with your AWS credentials"

To make them work, open QueueServiceMethods.pm, find the following lines, and replace the values with your actual AWS Access Key ID and Secret Access Key from your AWS account:

my $ACCESS_KEY_ID = 'WRITE YOUR OWN ACCESS_KEY_ID HERE';
my $SECRET_ACCESS_KEY_ID = 'WRITE YOUR OWN SECRET_ACCESS_KEY_ID';

Once you have done that, and removed the following two lines from the same file you can use the sample applications.

print "update QueueServiceMethods.pm with your AWS credentials\n";
exit;


Please see the Amazon SQS Getting Started Guide for more information.



Enqueue Sample
---------------
The first sample application is in sqs-enqueue-sample.pl. It takes the following arguments:
1. queue name
2. message string
3. REST or Query (optional - defaults to Query)

It creates a queue with the given name (if one does not exist already) and it enqueues the given message into the queue. You can run it from the command line, like this:

perl sqs-enqueue-sample.pl "SomeQueueName" "SomeMessage"




Dequeue Sample
----------------
The second sample appplication is in sqs-dequeue-sample.pl. It takes the following arguments:
1. queue name
2. REST or Query (optional - defaults to Query)

It finds a queue with the given name (if one exists), and it attempts to read a message from the queue. If not successful, it retries four more times (with a "sleep 1" in between); if successful, it reads and then deletes the message from the queue.
You can run it from the command-line, like this:

perl sqs-dequeue-sample.pl "FooBarQueueName" "Query"




Troubleshooting
------------------
Make sure you have the following dependencies:

Crypt::SSLeay
Data::Dumper
Digest::HMAC_SHA1
Digest::MD5
Digest::SHA1
HTTP::Date
HTTP::Headers
HTTP::Request
HTTP::Response
LWP::Simple
LWP::UserAgent
MIME::Base64
Time::HiRes
URI::Escape
XML::Simple
XML::XPath



If you are missing any of these, you can try running

    perl -MCPAN -e shell

If you haven't run this before, it will ask you a series of configuration
questions.  Please refer to the Perl documentation for information.

Once everything is configured, type:

install [package-name]

For each dependency, say 'yes' to install all dependencies of these
dependencies.  


Also, there have been reports that CPAN on OS X may not work well with FTP
mirrors. Choosing an HTTP mirror will solve this.  If you've already configured CPAN to use an FTP mirror, do the following:

1) Find either /Users/<user-name>/.cpan/CPAN/MyConfig.pm or
/System/Library/Perl/5.8.6/CPAN/Config.pm.  One of these is where CPAN is configured.

2) Find an HTTP mirror on this page: http://www.cpan.org/SITES.html

3) Replace the urllist parameter so that it looks something like this:

'urllist' => [q[http://cpan.llarian.net/]],

4) Try running install [package-name] again.