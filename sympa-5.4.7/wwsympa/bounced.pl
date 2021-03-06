#!--PERL--

# bounced.pl - This script runs as a daemon ; it does the incoming 
# non-delivery reports analysis and storage
# RCS Identication ; $Revision: 4999 $ ; $Date: 2008-05-16 16:31:12 +0200 (ven, 16 mai 2008) $ 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.


## Worl Wide Sympa is a front-end to Sympa Mailing Lists Manager
## Copyright Comite Reseau des Universites

## Patch 2001.07.24 by nablaphi <nablaphi@bigfoot.com>
## Change the Getopt::Std to Getopt::Long

## Options :  F         -> do not detach TTY
##         :  d		-> debug -d is equiv to -dF
## Now, it is impossible to use -dF but you have to write it -d -F

## Change this to point to your Sympa bin directory
use lib '--LIBDIR--';
use strict;

use FileHandle;

use List;
use Conf;
use Log;
use mail;
#use Getopt::Std;
use Getopt::Long;
use POSIX;

require 'tt2.pl';
require 'tools.pl';

## Equivalents relative to RFC 1893
my %equiv = ( "user unknown" => '5.1.1',
	      "receiver not found" => '5.1.1',
	      "the recipient name is not recognized" => '5.1.1',
	      "sorry, no mailbox here by that name" => '5.1.1',
	      "utilisateur non recens� dans le carnet d'adresses public" => '5.1.1',
	      "unknown address" => '5.1.1',
	      "unknown user" => '5.1.1',
	      "550" => '5.1.1',
	      "le nom du destinataire n'est pas reconnu" => '5.1.1',
	      "user not listed in public name & address book" => '5.1.1',
	      "no such address" => '5.1.1',
	      "not known at this site." => '5.1.1',
	      "user not known" => '5.1.1',
	      
	      "user is over the quota. you can try again later." => '4.2.2',
	      "quota exceeded" => '4.2.2',
	      "write error to mailbox, disk quota exceeded" => '4.2.2',
	      "user mailbox exceeds allowed size" => '4.2.2',
	      "insufficient system storage" => '4.2.2',
	      "User's Disk Quota Exceeded:" => '4.2.2');


require "--LIBDIR--/bounce-lib.pl";
use wwslib;

#getopts('dF');
## Check options
my %options;
unless (&GetOptions(\%main::options, 'debug|d','log_level=s','foreground|F')) {
    &fatal_err("Unknown options.");
}

# $main::options{'debug2'} = 1 if ($main::options{'debug'});

if ($main::options{'debug'}) {
    $main::options{'log_level'} = 2 unless ($main::options{'log_level'});
}

$main::options{'foreground'} = 1 if ($main::options{'debug'});
$main::options{'log_to_stderr'} = 1 if ($main::options{'debug'} || $main::options{'foreground'});


my $wwsympa_conf = "--WWSCONFIG--";
my $sympa_conf_file = '--CONFIG--';

my $daemon_name = &Log::set_daemon($0);
my $ip = $ENV{'REMOTE_HOST'};

my $wwsconf = {};

# Load WWSympa configuration
unless ($wwsconf = &wwslib::load_config($wwsympa_conf)) {
    print STDERR 'unable to load config file';
    exit;
}

# Load sympa.conf
unless (Conf::load($sympa_conf_file)) {
    &fatal_err("Unable to load sympa configuration, file $sympa_conf_file has errors.");
}


unshift @INC, $wwsconf->{'wws_path'};

## Check databse connectivity
unless (&List::check_db_connect()) {
    &fatal_err('Database %s defined in sympa.conf has not the right structure or is unreachable.', $Conf{'db_name'});
}

## Put ourselves in background if not in debug mode. 
unless ($main::options{'debug'} || $main::options{'foreground'}) {

    open(STDERR, ">> /dev/null");
    open(STDOUT, ">> /dev/null");
    if (open(TTY, "/dev/tty")) {
       ioctl(TTY, 0x20007471, 0);         # XXX s/b &TIOCNOTTY
#	ioctl(TTY, &TIOCNOTTY, 0);
	close(TTY);
    }
    setpgrp(0, 0);
    if ((my $child_pid = fork) != 0) {
	print STDOUT "Starting bounce daemon, pid $_\n";

	exit(0);
    }
}

## Create and write the pidfile
&tools::write_pid($wwsconf->{'bounced_pidfile'}, $$);

if ($main::options{'log_level'}) {
    &Log::set_log_level($main::options{'log_level'});
    do_log('info', "Configuration file read, log level set using options : $main::options{'log_level'}"); 
}else{
    &Log::set_log_level($Conf{'log_level'});
    do_log('info', "Configuration file read, default log level $Conf{'log_level'}"); 
}

$wwsconf->{'log_facility'}||= $Conf{'syslog'};
do_openlog($wwsconf->{'log_facility'}, $Conf{'log_socket_type'}, 'bounced');

## Set the UserID & GroupID for the process
$( = $) = (getgrnam('--GROUP--'))[2];
$< = $> = (getpwnam('--USER--'))[2];

## Required on FreeBSD to change ALL IDs(effective UID + real UID + saved UID)
&POSIX::setuid((getpwnam('--USER--'))[2]);
&POSIX::setgid((getgrnam('--GROUP--'))[2]);

## Check if the UID has correctly been set (usefull on OS X)
unless (($( == (getgrnam('--GROUP--'))[2]) && ($< == (getpwnam('--USER--'))[2])) {
    &fatal_err("Failed to change process userID and groupID. Note that on some OS Perl scripts can't change their real UID. In such circumstances Sympa should be run via SUDO.");
}

## Sets the UMASK
umask(oct($Conf{'umask'}));

## Change to list root
unless (chdir($Conf{'home'})) {
     &do_log('info','Unable to change directory');
    exit (-1);
}

my $pinfo = &List::_apply_defaults();

do_log('notice', "bounced Started");


## Catch SIGTERM, in order to exit cleanly, whenever possible.
$SIG{'TERM'} = 'sigterm';
my $end = 0;


my $queue = $Conf{'queuebounce'};

do_log('debug','starting infinite loop');
## infinite loop scanning the queue (unless a sig TERM is received
while (!$end) {
    ## this sleep is important to be raisonably sure that sympa is not currently
    ## writting the file this deamon is openning. 
    
    sleep $Conf{'sleep'};
    
    &List::init_list_cache();

    unless (opendir(DIR, $queue)) {
	fatal_err("Can't open dir %s: %m", $queue); ## No return.
    }

    my @files =  (sort grep(!/^(\.|T\.|BAD\-)/, readdir DIR ));
    closedir DIR;
    foreach my $file (@files) {

	last if $end;
	next unless (-f "$queue/$file");
	
	unless ($file =~ /^(\S+)\.\d+\.\d+$/) {
	    my @s = stat("$queue/$file");
	    if (POSIX::S_ISREG($s[2])) {
		do_log ('notice',"Ignoring file $queue/$file because unknown format");
		&ignore_bounce({'file' => $file,
				'queue' => $queue,
			    });
	        unlink("$queue/$file");
	    }
	    next;
	}

	if ($file =~ /^(\S+)\.\d+\.\d+$/) {
	    my ($listname, $robot) = split(/\@/,$1);
	    $robot ||= &List::search_list_among_robots($listname);
	}
	
	my ($listname, $robot) = split(/\@/,$1);
	$robot ||= &List::search_list_among_robots($listname);

	if (-z "$queue/$file") {
	    do_log ('notice',"Ignoring file $queue/$file because empty file");
	    &ignore_bounce({'file' => $file,
			    'robot' => $robot,
			    'queue' => $queue,
			});
	    unlink("$queue/$file");
	}
         
	unless (open BOUNCE, "$queue/$file") {
	    &do_log('notice', 'Could not open %s/%s: %s', $queue, $file, $!);
	    &ignore_bounce({'file' => $file,
			    'robot' => $robot,
			    'queue' => $queue,
			});
	    next;
	}
	my $parser = new MIME::Parser;
	$parser->output_to_core(1);
	my $entity = $parser->read(\*BOUNCE);
	my $head = $entity->head;
	my $to = $head->get('to', 0);
	close BOUNCE ; 

	my $who;
	chomp $to;	
	&do_log('debug', 'bounce for :%s:  Conf{bounce_email_prefix}=%sxx',$to,$Conf{'bounce_email_prefix'});
	$to =~ s/<//;
	$to =~ s/>//;
	if ($to =~ /^$Conf{'bounce_email_prefix'}\+(.*)\@(.*)$/) { #VERP in use

	    my $local_part = $1;
	    my $robot = $2;
	    my $unique ;
	    if ($local_part =~ /^(.*)(\=\=([wr]))$/) {
		$local_part = $1;
		$unique = $2;
	    }
	    $local_part =~ s/\=\=a\=\=/\@/ ;
	    $local_part =~ /^(.*)\=\=(.*)$/ ; 	    
	    $who = $1;
	    $listname = $2 ;

	    &do_log('debug', 'VERP in use : bounce related to %s for list %s@%s',$who,$listname,$robot);

	    if ($unique =~ /[wr]/) { # in this case the bounce result from a remind or a welcome message ;so try to remove the subscriber
		&do_log('debug', "VERP for a service message, try to remove the subscriber");
		my $list = new List ($listname, $robot);		
		unless($list) {
		    do_log('notice','Skipping bouncefile %s for unknown list %s@%s',$file,$listname,$robot);
		    &ignore_bounce({'file' => $file,
				    'robot' => $robot,
				    'queue' => $queue,
				});
		    unlink("$queue/$file");
		    next;
		}
		my $result =$list->check_list_authz('del','smtp',
						    {'sender' => $Conf{'listmasters'}[0],
						     'email' => $who});
		my $action;
		$action = $result->{'action'} if (ref($result) eq 'HASH');
		
		if ($action =~ /do_it/i) {
		    if ($list->is_user($who)) {
			my $u = $list->delete_user($who);
			do_log ('notice',"$who has been removed from $listname because welcome message bounced");
			&Log::db_log({'robot' => $list->{'domain'},'list' => $list->{'name'},'action' => 'del',
				      'target_email' => $who,'status' => 'error','error_type' => 'welcome_bounced',
				      'daemon' => 'bounced'});

			if ($action =~ /notify/) {
			    unless ($list->send_notify_to_owner('automatic_del',
								{'who' => $who,
								 'by' => 'bounce manager',
								 'reason' => 'welcome'})) {
				&wwslog('err',"Unable to send notify 'automatic_del' to $list->{'name'} list owner");
			    } 
			}
		    }
		}else {
		    do_log ('notice',"Unable to remove $who from $listname (welcome message bounced but del is closed)");
		    &ignore_bounce({'file' => $file,
				    'robot' => $robot,
				    'queue' => $queue,
				});
		}
		unlink("$queue/$file");
		next;
	    }
	}
	if(($head->get('Content-type') =~ /multipart\/report/) && ($head->get('Content-type') =~ /report\-type\=feedback-report/)) {
	    # this case a report Email Feedback Reports http://www.shaftek.org/publications/drafts/abuse-report/draft-shafranovich-feedback-report-01.txt mainly use by AOL
	    do_log ('notice',"processing  Email Feedback Report");
	    my @parts = $entity->parts();
	    my $original_rcpt;
	    my $user_agent;
	    my $version;
	    my $feedback_type = '';
	    my $listname, $robot;
	    foreach my $p (@parts) {
		my $h = $p->head();
		my $content = $h->get('Content-type');
		next if ($content =~ /text\/plain/i);		 
		if ($content =~ /message\/feedback-report/) {
		    my @report = split(/\n/, $p->bodyhandle->as_string());
		    foreach my $line (@report) {
			$feedback_type = 'abuse' if ($line =~ /Feedback\-Type\:\s*abuse/i);
			if ($line =~ /Feedback\-Type\:\s*(.*)/i) {
			    $feedback_type = $1;
			}

			if ($line =~ /User\-Agent\:\s*(.*)/i) {
			    $user_agent = $1;
			}
			if ($line =~ /Version\:\s*(.*)/i) {
			    $version = $1;
			}
			my $email_regexp = &tools::get_regexp('email');
			if ($line =~ /Original\-Rcpt\-To\:\s*($email_regexp)\s*$/i) {
			    $original_rcpt = $1;
			    chomp $original_rcpt;
			}
		    }
		}elsif ($content =~ /message\/rfc822/) {
		    # do_log ('notice',"xxx processing  Email Feedback Report : message/rfc822 part");
		    my @subparts = $p->parts();
		    foreach my $subp (@subparts) {
			# do_log ('notice',"xxx subparts : subps");
			my $subph =  $subp->head;
			$listname = $subph->get('X-Loop');
		    }
		    # do_log ('notice',"xxx processing  Email Feedback Report : extract listname $listname");
		}
	    }
	    my $forward ;
	    ## RFC compliance remark: We do something if there is an abuse or an unsubscribe request.
	    ## We don't throw an error if we find another kind of feedback (fraud, miscategorized, not-spam, virus or other)
	    ## but we don't take action if we meet them yet. This is to be done, if relevant.
	    if (($feedback_type =~ /(abuse|opt-out|opt-out-list|fraud|miscategorized|not-spam|virus|other)/i) && (defined $version) && (defined $user_agent)) {
		
		do_log ('debug',"Email Feedback Report: $listname feedback-type: $feedback_type");
		if (defined $original_rcpt) {
		    do_log ('debug',"Recognized user : $original_rcpt list");		
		    my @lists;
		    
		    if (( $feedback_type =~ /(opt-out-list|abuse)/i ) && (defined $listname)) {
			$listname = lc($listname);
			chomp $listname ;
			$listname =~ /(.*)\@(.*)/;
			$listname = $1;
			$robot = $2;
			my $list = new List ($listname, $robot);
			unless($list) {
			    do_log('err','Skipping Feedback Report for unknown list %s@%s',$file,$listname,$robot);
			    &ignore_bounce({'file' => $file,
					    'robot' => $robot,
					    'queue' => $queue,
					});
			    unlink("$queue/$file");
			    next;
			}
			push @lists, $list;
		    }elsif( $feedback_type =~ /opt-out/ && (defined $original_rcpt)){
			@lists = &List::get_which($original_rcpt,$robot,'member');
		    }else {
			&do_log('notice','Ignoring Feedback Report %s : Nothing to do for this feedback type.(feedback_type:%s, original_rcpt:%s, listname:%s)',$file, $feedback_type, $original_rcpt, $listname );		
			&ignore_bounce({'file' => $file,
					'robot' => $robot,
					'queue' => $queue,
				    });
		    }
		    foreach my $list (@lists){
			my $result =$list->check_list_authz('unsubscribe','smtp',{'sender' => $original_rcpt});
			my $action;
			$action = $result->{'action'} if (ref($result) eq 'HASH');		    
			if ($action =~ /do_it/i) {
			    if ($list->is_user($original_rcpt)) {
				my $u = $list->delete_user($original_rcpt);
				
				do_log ('notice',"$original_rcpt has been removed from %s because abuse feedback report",$list->name);	
				unless ($list->send_notify_to_owner('automatic_del',{'who' => $original_rcpt, 'by' => 'listmaster'})) {
				    &do_log('notice',"Unable to send notify 'automatic_del' to $list->{'name'} list owner");
				}
			    }else{
				do_log('err','Ignore Feedback Report %s for list %s@%s : user %s not subscribed',$file,$list->name,$robot,$original_rcpt);
				unless ($list->send_notify_to_owner('warn-signoff',{'who' => $original_rcpt})) {
				    &do_log('notice',"Unable to send notify 'warn-signoff' to $list->{'name'} list owner");
				}
			    }
			}else{
			    $forward = 'request';
			    do_log('err','Ignore Feedback Report %s for list %s@%s : user %s is not allowed to unsubscribe',$file,$list->name,$robot,$original_rcpt);
			}
		    }
		}else{
		    do_log ('err','Ignoring Feedback Report %s : Unknown Original-Rcpt-To field. Can\'t do anything. (feedback_type:%s, listname:%s)',$file, $feedback_type, $listname );		
		    &ignore_bounce({'file' => $file,
				    'notify' => 1,
				    'robot' => $robot,
				    'queue' => $queue,
				    'error' => "Unknown Original-Rcpt-To field (feedback_type:$feedback_type, listname:$listname)",
				});
		}
	    }else{
		do_log ('err','Ignoring Feedback Report %s : Unknown format (feedback_type:%s, original_rcpt:%s, listname:%s)',$file, $feedback_type, $original_rcpt, $listname );		
		&ignore_bounce({'file' => $file,
				'notify' => 1,
				'robot' => $robot,
				'queue' => $queue,
				'error' => "Unknown format (feedback_type:$feedback_type, original_rcpt:$original_rcpt, listname:$listname)",
			    });
	    }
	    if (-f "$queue/$file") {
		unlink("$queue/$file");
	    }
	    next;		
	}

	# else (not welcome or remind) 
	my $list = new List ($listname, $robot);
	if (! $list) {
 	    &do_log('err','Skipping bouncefile %s for unknown list %s@%s',$file,$listname,$robot);
	    &ignore_bounce({'file' => $file,
			    'robot' => $robot,
			    'queue' => $queue,
			});
  	    unlink("$queue/$file");
  	    next;
 	}else{
	    &do_log('debug',"Processing bouncefile $file for list $listname");      

	    unless (open BOUNCE, "$queue/$file") {
		&do_log('notice', 'Could not open %s/%s: %s', $queue, $file, $!);
		&ignore_bounce({'file' => $file,
				'robot' => $robot,
				'queue' => $queue,
			    });
		next;
	    }

	    my (%hash, $from);
	    my $bounce_dir = $list->get_bounce_dir();

	    ## RFC1891 compliance check
	    my $bounce_count = &rfc1891(\*BOUNCE, \%hash, \$from);

	    unless ($bounce_count) {
		close BOUNCE;
		unless (open BOUNCE, "$queue/$file") {
		    &do_log('notice', 'Could not open %s/%s: %s', $queue, $file, $!);
		    &ignore_bounce({'file' => $file,
				    'robot' => $robot,
				    'queue' => $queue,
				});
		    next;
		    }		
		## Analysis of bounced message
		&anabounce(\*BOUNCE, \%hash, \$from);
	    }
	    close BOUNCE;
	    
	    ## Bounce directory
	    if (! -d $bounce_dir) {
		unless (mkdir $bounce_dir, 0777) {
		    &List::send_notify_to_listmaster('intern_error',$Conf{'domain'},{'error' => "Failed to list create bounce directory $bounce_dir"});
		    &do_log('err', 'Could not create %s: %s bounced die, check bounce-path in wwsympa.conf', $bounce_dir, $!);
		    exit;
		} 
	    }
 
	    my $adr_count;
	    ## Bouncing addresses

	    while (my ($rcpt, $status) = each %hash) {
		$adr_count++;
		my $bouncefor = $who;
		$bouncefor ||= $rcpt;

		next unless (&store_bounce ($bounce_dir,$file,$bouncefor));
		next unless (&update_subscriber_bounce_history($list, $rcpt, $bouncefor, &canonicalize_status ($status)));
	    }
    
	    ## No address found in the bounce itself
	    unless ($adr_count) {
		
		if ( $who ) {	# rcpt not recognized in the bounce but VERP was used
		    &store_bounce ($bounce_dir,$file,$who)
		    &update_subscriber_bounce_history($list, 'unknown', $who); # status is undefined 
		}else{          # no VERP and no rcpt recognized		
		    my $escaped_from = &tools::escape_chars($from);
		    &do_log('info', 'error: no address found in message from %s for list %s',$from, $list->{'name'});
		    
		    ## We keep bounce msg
		    if (! -d "$bounce_dir/OTHER") {
			unless (mkdir  "$bounce_dir/OTHER",0777) {
			    &do_log('notice', 'Could not create %s: %s', "$bounce_dir/OTHER", $!);
			    &ignore_bounce({'file' => $file,
					    'robot' => $robot,
					    'queue' => $queue,
					});
			    next;
			}
		    }
		     
		    ## Original msg
		    if (-w "$bounce_dir/OTHER") {
			unless (open BOUNCE, "$queue/$file") {
			    &do_log('notice', 'Could not open %s/%s: %s', $queue, $file, $!);
			    &ignore_bounce({'file' => $file,
					    'robot' => $robot,
					    'queue' => $queue,
					});
			    next;
			}
			
			unless (open ARC, ">$bounce_dir/OTHER/$escaped_from") {
			    &do_log('notice', "Cannot create $bounce_dir/OTHER/$escaped_from");
			    &ignore_bounce({'file' => $file,
					    'robot' => $robot,
					    'queue' => $queue,
					});
			    next;
			}
			print ARC <BOUNCE>;
			close BOUNCE;
			close ARC;
		    }else {
			&do_log('notice', "Failed to write $bounce_dir/OTHER/$escaped_from");
		    }
	    	}
	    }
	}
	
	unless (unlink("$queue/$file")) {
	    do_log ('err',"Could not remove $queue/$file ; $0 might NOT be running with the right UID or file was not created with the right UID");
	    &ignore_bounce({'file' => $file,
			    'notify' => 1,
			    'robot' => $robot,
			    'queue' => $queue,
			    'error' => "Could not remove $queue/$file ; $0 might NOT be running with the right UID or file was not created with the right UID",
			});
	    last;
	}
    }

    ## Free zombie sendmail processes
    &mail::reaper;

}
do_log('notice', 'bounced exited normally due to signal');
&tools::remove_pid($wwsconf->{'bounced_pidfile'}, $$);

exit(0);


## When we catch SIGTERM, just change the value of the loop
## variable.
sub sigterm {
    $end = 1;
}

## copy the bounce to the appropriate filename
sub store_bounce {

    my $bounce_dir = shift; 
    my $file= shift;
    my $rcpt=shift;
    
    do_log('debug', 'store_bounce(%s,%s,%s)', $bounce_dir,$file,$rcpt);

    my $queue = $Conf{'queuebounce'};

    #Store bounce 
    unless (open BOUNCE, "$queue/$file") {
	&do_log('notice', 'Could not open %s/%s: %s', $queue, $file, $!);
	&ignore_bounce({'file' => $file,
			'queue' => $queue,
		    });
	return undef;
    }

    my $filename = &tools::escape_chars($rcpt);    
    
    unless (open ARC, ">$bounce_dir/$filename") {
	&do_log('notice', "Unable to write $bounce_dir/$filename");
	&ignore_bounce({'file' => $file,
			'queue' => $queue,
		    });
	return undef;
    }
    print ARC <BOUNCE>;
    close BOUNCE; 
}


## Set error message to a status RFC1893 compliant
sub canonicalize_status {

    my $status =shift;
    
    if ($status !~ /^\d+\.\d+\.\d+$/) {
	if ($equiv{$status}) {
	    $status = $equiv{$status};
	}else {
	    return undef;
	}
    }
    return $status;
}


## update subscriber information
# $bouncefor : the email address the bounce is related for (may be extracted using verp)
# $rcpt : the email address recognized in the bounce itself. In most case $rcpt eq $bouncefor

sub update_subscriber_bounce_history {

    my $list = shift;
    my $rcpt = shift;
    my $bouncefor = shift;
    my $status = shift;
    
    &do_log ('debug','&update_subscriber_bounce_history (%s,%s,%s,%s)',$list->{'name'},$rcpt,$bouncefor,$status); 

    my $first = my $last = time;
    my $count = 0;
    
    my $user = $list->get_subscriber($bouncefor);
    
    unless ($user) {
	&do_log ('notice', 'Subscriber not found in list %s : %s', $list->{'name'}, $bouncefor); 		    
	return undef;
    }
    
    if ($user->{'bounce'} =~ /^(\d+)\s\d+\s+(\d+)/) {
	($first, $count) = ($1, $2);
    }
    $count++;
    if ($rcpt ne $bouncefor) {
	&do_log('notice','Bouncing address identified with VERP : %s / %s', $rcpt, $bouncefor);
	&do_log ('debug','&update_subscribe (%s, bounce-> %s %s %s %s,bounce_address->%s)',$bouncefor,$first,$last,$count,$status,$rcpt); 
	$list->update_user($bouncefor,{'bounce' => "$first $last $count $status",
				       'bounce_address' => $rcpt});
	&Log::db_log({'robot' => $list->{'domain'},'list' => $list->{'name'},'action' => 'get_bounce','parameters' => "address=$rcpt",
		      'target_email' => $bouncefor,'msg_id' => '','status' => 'error','error_type' => $status,
		      'daemon' => 'bounced'});
    }else{
	$list->update_user($bouncefor,{'bounce' => "$first $last $count $status"});
	&do_log('notice','Received bounce for email address %s, list %s', $bouncefor, $list->{'name'});
	&Log::db_log({'robot' => $list->{'domain'},'list' => $list->{'name'},'action' => 'get_bounce',
		      'target_email' => $bouncefor,'msg_id' => '','status' => 'error','error_type' => $status,
		      'daemon' => 'bounced'});
    }
}

## If bounce can't be handled correctly, saves it to the "bad" subdirectory of the bounce spool and notifies listmaster.
sub ignore_bounce {

    my $param = shift;

    my $file = $param -> {'file'};
    my $notify = $param -> {'notify'};
    my $error = $param -> {'error'};
    my $queue = $param -> {'queue'};
    my $robot = $param -> {'robot'};

    $notify |= 0;

    &tools::save_to_bad({
	'file' => $file,
	'hostname' => $robot,
	'queue' => $queue,
    });
    if ($notify) {
	unless (&List::send_notify_to_listmaster('bounce_management_failed',$robot,{'file' => $file,
										    'bad' => "$queue/bad",
										    'error' => $error,
										})) {
	    &do_log('notice',"Unable to send notify 'bounce_management_failed' to listmaster");
	}
    }
}









