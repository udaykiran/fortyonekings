# mail.pm - This module includes mail sending functions and does the smtp job.
# RCS Identication ; $Revision: 4831 $ ; $Date: 2008-02-06 09:19:09 +0100 (mer, 06 fév 2008) $ 
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

package mail;

require Exporter;
use Carp;
@ISA = qw(Exporter);
@EXPORT = qw(mail_file mail_message mail_forward set_send_spool);

#use strict;
use POSIX;
use Mail::Internet;
use MIME::Charset;
use MIME::Tools;
use Version;
use Conf;
use Log;
use Language;
use List;
use strict;
require 'tools.pl';

#use strict;

## RCS identification.
#my $id = '@(#)$Id: mail.pm 4831 2008-02-06 08:19:09Z david.verdin $';

my $opensmtp = 0;
my $fh = 'fh0000000000';	## File handle for the stream.

my $max_arg = eval { &POSIX::_SC_ARG_MAX; };
if ($@) {
    $max_arg = 4096;
    printf STDERR gettext("Your system does not conform to the POSIX P1003.1 standard, or\nyour Perl system does not define the _SC_ARG_MAX constant in its POSIX\nlibrary. You must modify the smtp.pm module in order to set a value\nfor variable $max_arg.\n");
} else {
    $max_arg = POSIX::sysconf($max_arg);
}

my %pid = ();

my $send_spool; ## for calling context



#################################### PUBLIC FUNCTIONS ##############################################


####################################################
# public set_send_spool      
####################################################
# set in global $send_spool, the concerned spool for
# sending message when it is not done by smtpto
#    
# IN : $spool (+): spool concerned by sending
# OUT :
#      
####################################################
sub set_send_spool {
    my $spool = pop;

    $send_spool = $spool;
}

####################################################
# public mail_file                          
####################################################
# send a tt2 file 
# 
#  
# IN : -$filename(+) : tt2 filename (with .tt2) | ''
#      -$rcpt(+) : SCALAR |ref(ARRAY) : SMTP "RCPT To:" field
#      -$data(+) : used to parse tt2 file, ref(HASH) with keys :
#        -return_path(+) : SMTP "MAIL From:" field if send by smtp, 
#                          "X-Sympa-From:" field if send by spool
#        -to : "To:" header field
#        -lang : tt2 language if $filename
#        -list :  ref(HASH) if $sign_mode = 'smime', keys are :
#          -name
#          -dir
#        -from : "From:" field if not a full msg
#        -subject : "Subject:" field if not a full msg
#        -replyto : "Reply-to:" field if not a full msg
#        -body  : body message if not $filename
#        -headers : ref(HASH) with keys are headers mail
#      -$robot(+)
#      -$sign_mode :'smime' | '' | undef
#         
# OUT : 1 | undef
####################################################
sub mail_file {
    my ($filename, $rcpt, $data,$robot,$sign_mode) = @_;
    &do_log('debug2', 'mail::mail_file(%s, %s, %s)', $filename, $rcpt, $sign_mode);

    my ($to,$message);

    ## boolean
    my $header_possible = 0; # =1 : it is possible there are some headers
    my %header_ok;           # hash containing no missing headers
    my $existing_headers = 0;# the message already contains headers
   
    ## We may receive a list a recepients
    if (ref ($rcpt)) {
	unless (ref ($rcpt) eq 'ARRAY') {
	    &do_log('notice', 'mail:mail_file : Wrong type of reference for rcpt');
	    return undef;
	}
    }

    ## Charset for encoding
    $data->{'charset'} ||= &Language::GetCharset();

    ## TT2 file parsing 
    if ($filename =~ /\.tt2$/) {
	my $output;
	my @path = split /\//, $filename;	   
	&Language::PushLang($data->{'lang'}) if (defined $data->{'lang'});
	&tt2::parse_tt2($data, $path[$#path], \$output);
	&Language::PopLang() if (defined $data->{'lang'});
	$message .= join('',$output);
	$header_possible = 1;

    }else { # or not
	$message .= $data->{'body'};
       }
       
    ## ## Does the message include headers ?
    if ($header_possible) {
	foreach my $line (split(/\n/,$message)) {
	    last if ($line=~/^\s*$/);
       
	    if ($line=~/^[\w-]+:\s*/) { ## A header field
		$existing_headers=1;
	    }elsif ($existing_headers && ($line =~ /^\s/)) { ## Following of a header field
		next;
	    }else{
		last;
	    }
		
	    foreach my $header ('to','from','subject','reply-to','mime-version', 'content-type','content-transfer-encoding') {
		if ($line=~/^$header:/i) {
		    $header_ok{$header} = 1;
		    last;
		}
	    }
	}
   }
   
    ## ADD MISSING HEADERS
    my $headers="";

    unless ($header_ok{'to'}) {

	if (ref ($rcpt)) {
	    if ($data->{'to'}) {
		$to = $data->{'to'};
	    }else {
		$to = join(",\n   ", @{$rcpt});
	    }
	}else{
	    $to = $rcpt;
	}   
	$headers .= "To: ".MIME::EncWords::encode_mimewords(
	    Encode::decode('utf8', $to),
	    'Encoding' => 'A', 'Charset' => $data->{'charset'}, 'Field' => 'To'
	    )."\n"; 
    }     
    unless ($header_ok{'from'}) {
	if ($data->{'from'} eq 'sympa') {
	    $headers .= "From: ".MIME::EncWords::encode_mimewords(
		sprintf("SYMPA <%s>",&Conf::get_robot_conf($robot, 'sympa')),
		'Encoding' => 'A', 'Charset' => "US-ASCII", 'Field' => 'From'
		)."\n";
	} else {
	    $headers .= "From: ".MIME::EncWords::encode_mimewords(
		Encode::decode('utf8', $data->{'from'}),
		'Encoding' => 'A', 'Charset' => $data->{'charset'}, 'Field' => 'From'
		)."\n"; 
	}
   }
    unless ($header_ok{'subject'}) {
	$headers .= "Subject: ".MIME::EncWords::encode_mimewords(
	    Encode::decode('utf8', $data->{'subject'}),
	    'Encoding' => 'A', 'Charset' => $data->{'charset'}, 'Field' => 'Subject'
	    )."\n";
   }
    unless ($header_ok{'reply-to'}) { 
	$headers .= "Reply-to: ".MIME::EncWords::encode_mimewords(
	    Encode::decode('utf8', $data->{'replyto'}),
	    'Encoding' => 'A', 'Charset' => $data->{'charset'}, 'Field' => 'Reply-to'
	    )."\n" if ($data->{'replyto'})
    }
    if ($data->{'headers'}) {
	foreach my $field (keys %{$data->{'headers'}}) {
	    $headers .= $field.': '.MIME::EncWords::encode_mimewords(
		Encode::decode('utf8', $data->{'headers'}{$field}),
		'Encoding' => 'A', 'Charset' => $data->{'charset'}, 'Field' => $field
		)."\n";
	}
    }
    unless ($header_ok{'mime-version'}) {
	$headers .= "MIME-Version: 1.0\n";
    }
    unless ($header_ok{'content-type'}) {
	$headers .= "Content-Type: text/plain; charset=UTF-8\n";
    }
    unless ($header_ok{'content-transfer-encoding'}) {
	$headers .= "Content-Transfer-Encoding: 8bit\n"; 
    }
    unless ($existing_headers) {
	$headers .= "\n";
   }
   
    ## All these data provide mail attachements in service messages
    my @msgs = ();
    if (ref($data->{'msg_list'}) eq 'ARRAY') {
	@msgs = map {$_->{'msg'} || $_->{'full_msg'}} @{$data->{'msg_list'}};
    } elsif ($data->{'spool'}) {
	@msgs = @{$data->{'spool'}};
    } elsif ($data->{'msg'}) {
	push @msgs, $data->{'msg'};
    } elsif ($data->{'msg_path'} and open IN, '<'.$data->{'msg_path'}) {
	push @msgs, join('', <IN>);
	close IN;
    } elsif ($data->{'file'} and open IN, '<'.$data->{'file'}) {
	push @msgs, join('', <IN>);
	close IN;
    }

    my $listname = '';
    if (ref($data->{'list'}) eq "HASH") {
	$listname = $data->{'list'}{'name'};
    } elsif ($data->{'list'}) {
	$listname = $data->{'list'};
    }
     
    unless ($message = &reformat_message("$headers"."$message", \@msgs)) {
	&do_log('err', "mail::mail_file: Failed to reformat message");
    }

    ## Set it in case it was not set
    $data->{'return_path'} ||= &Conf::get_robot_conf($robot, 'request');
    
    ## SENDING
    if (ref($rcpt)) {
	unless (defined &sending($message,$rcpt,$data->{'return_path'},$robot,$listname,$sign_mode)) {
	    return undef;
	}
    } else {
	unless (defined &sending($message,\$rcpt,$data->{'return_path'},$robot,$listname,$sign_mode)) {
	    return undef;
	}
    }
   return 1;
}


####################################################
# public mail_message                              
####################################################
# distribute a message to a list, Crypting if needed
# 
# IN : -$message(+) : ref(Message)
#      -$from(+) : message from
#      -$robot(+) : robot
#      -{verp=>[on|off]} : a hash to introduce verp parameters, starting just on or off, later will probably introduce optionnal parameters 
#      -@rcpt(+) : recepients
# OUT : -$numsmtp : number of sendmail process | undef
#       
####################################################
sub mail_message {
    my($message, $list, $verp, @rcpt) = @_;
   

    my $host = $list->{'admin'}{'host'};
    my $robot = $list->{'domain'};
    my $name = $list->{'name'};

    # normal return_path (ie used if verp is not enabled)
    my $from = $list->{'name'}.&Conf::get_robot_conf($robot, 'return_path_suffix').'@'.$host;

    do_log('debug', 'mail::mail_message(from: %s, , file:%s, %s, verp->%s %d rcpt)', $from, $message->{'filename'}, $message->{'smime_crypted'}, $verp->{'enable'}, $#rcpt+1);
    
    
    my($i, $j, $nrcpt, $size, @sendto);
    my $numsmtp = 0;
    
    ## If message contain a footer or header added by Sympa  use the object message else
    ## Extract body from original file to preserve signature
    my ($msg_body, $msg_header);
    
    $msg_header = $message->{'msg'}->head;
    
    if ($message->{'altered'}) {
	$msg_body = $message->{'msg'}->body_as_string;
	
    }elsif ($message->{'smime_crypted'}) {
	$msg_body = ${$message->{'msg_as_string'}};
	
    }else {
	## Get body from original file
	unless (open MSG, $message->{'filename'}) {
	    do_log ('notice',"mail::mail_message : Unable to open %s:%s",$message->{'filename'},$!);
	    return undef;
	}
	my $in_header = 1 ;
	while (<MSG>) {
	    if ( !$in_header)  { 
		$msg_body .= $_;       
	    }else {
		$in_header = 0 if (/^$/); 
	    }
	}
	close (MSG);
    }
    
    ## if the message must be crypted,  we need to send it using one smtp session for each rcpt
    ## n.b. : sendto can send by setting in spool, however, $numsmtp is incremented (=> to change)
    # ignore verp if crypted. It should be better to do the reverse : allway use verp if crypted (sa 03/01/2006)
    
    if (($message->{'smime_crypted'})||($verp->{'enable'} eq 'on')){
	$numsmtp = 0;
	while (defined ($i = shift(@rcpt))) {
	    my $return_path = $from;
	    if ($verp->{'enable'} eq 'on') {
		$return_path = $i ;
		$return_path =~ s/\@/\=\=a\=\=/; 
		$return_path = "$Conf{'bounce_email_prefix'}+$return_path\=\=$name\@$robot";
	    }
	    $numsmtp++ if (&sendto($msg_header, $msg_body, $return_path, [$i], $robot, $message->{'smime_crypted'}));
	}
	
	return ($numsmtp);
    }
    

    my %rcpt_by_dom ;


    while (defined ($i = shift(@rcpt))) {
	my @k = reverse(split(/[\.@]/, $i));
	my @l = reverse(split(/[\.@]/, $j));

	my $dom;
	if ($i =~ /\@(.*)$/) {
	    $dom = $1;
	    chomp $dom;
	}
	$rcpt_by_dom{$dom} += 1 ;
	&do_log('debug2', "domain: $dom ; rcpt by dom: $rcpt_by_dom{$dom} ; limit for this domain: $Conf{'nrcpt_by_domain'}{$dom}");

	if (defined ($Conf{'nrcpt_by_domain'}{$dom}) && ( $rcpt_by_dom{$dom} >= $Conf{'nrcpt_by_domain'}{$dom} )){
	    undef %rcpt_by_dom ;
	    $numsmtp++ if (&sendto($msg_header, $msg_body, $from, \@sendto, $robot));
	    $nrcpt = $size = 0;
	    @sendto = ();  
	}
	
	if ($j && $#sendto >= &Conf::get_robot_conf($robot, 'avg') && lc("$k[0] $k[1]") ne lc("$l[0] $l[1]")) {
	    undef %rcpt_by_dom ;
	    $numsmtp++ if (&sendto($msg_header, $msg_body, $from, \@sendto, $robot));
	    $nrcpt = $size = 0;
	    @sendto = ();
	}
	if ($#sendto >= 0 && (($size + length($i)) > $max_arg || $nrcpt >= &Conf::get_robot_conf($robot, 'nrcpt'))) {
	    undef %rcpt_by_dom ;
	    $numsmtp++ if (&sendto($msg_header, $msg_body, $from, \@sendto, $robot));
	    $nrcpt = $size = 0;
	    @sendto = ();
	}
	$nrcpt++; $size += length($i) + 5;
	push(@sendto, $i);
	$j = $i;
    }
    if ($#sendto >= 0) {
	$numsmtp++ if (&sendto($msg_header, $msg_body, $from, \@sendto, $robot));
	
    }
    
    return $numsmtp;
}


####################################################
# public mail_forward                              
####################################################
# forward a message.
# 
# IN : -$msg(+) : ref(Message)|ref(MIME::Entity)|string
#      -$from(+) : message from
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY)  - recepients
#      -$robot(+) : robot
# OUT : 1 | undef
#
####################################################
sub mail_forward {
    my($msg,$from,$rcpt,$robot)=@_;
    &do_log('debug3', "mail::mail_forward($from,$rcpt)");

    my $message;
    if (ref($msg) eq 'Message') {
	$message = $msg->{'msg'};
   
    } else {
	$message = $msg;
    }
	
    unless (defined &sending($message,$rcpt,$from,$robot,'','none')) {
	&do_log('err','mail::mail_forward from %s impossible to send',$from);
	   return undef;
       }

    return 1;
}

#####################################################################
# public reaper                              
#####################################################################
# Non blocking function called by : mail::smtpto(), sympa::main_loop
#  task_manager::INFINITE_LOOP scanning the queue, 
#  bounced::infinite_loop scanning the queue, 
# just to clean the defuncts list by waiting to any processes and 
#  decrementing the counter. 
# 
# IN : $block
# OUT : $i 
#####################################################################
sub reaper {
   my $block = shift;
   my $i;

   $block = 1 unless (defined($block));
   while (($i = waitpid(-1, $block ? &POSIX::WNOHANG : 0)) > 0) {
      $block = 1;
      if (!defined($pid{$i})) {
         &do_log('debug2', "Reaper waited $i, unknown process to me");
         next;
      }
      $opensmtp--;
      delete($pid{$i});
   }
   &do_log('debug2', "Reaper unwaited pids : %s\nOpen = %s\n", join(' ', sort keys %pid), $opensmtp);
   return $i;
}
     

#################################### PRIVATE FUNCTIONS ##############################################

####################################################
# sendto                              
####################################################
# send messages, S/MIME encryption if needed, 
# grouped sending (or not if encryption)
#  
# IN: $msg_header (+): message header : MIME::Head object 
#     $msg_body (+): message body
#     $from (+): message from
#     $rcpt(+) : ref(SCALAR) | ref(ARRAY) - message recepients
#     $robot(+) : robot
#     $encrypt : 'smime_crypted' | undef  
# OUT : 1 - call to smtpto (sendmail) | 0 - push in spool | undef
#       
####################################################
sub sendto {
    my($msg_header, $msg_body, $from, $rcpt, $robot, $encrypt) = @_;
    do_log('debug2', 'mail::sendto(%s, %s, %s', $from, $rcpt, $encrypt);

    my $msg;

    #XXX## Encode subject before sending
    #XXX$msg_header->replace('Subject', MIME::Words::encode_mimewords($msg_header->get('Subject')));

    if ($encrypt eq 'smime_crypted') {
	my $email ;
	if (ref($rcpt) eq 'SCALAR') {
	    $email = lc ($$rcpt) ;
	}else{
	    my @rcpts = @$rcpt;
	    if ($#rcpts != 0) {
		do_log('err',"incorrect call for encrypt with $#rcpts recipient(s)"); 
		return undef;
	    }
	    $email = lc ($rcpt->[0]); 
	}
	$msg = &tools::smime_encrypt ($msg_header, $msg_body, $email);
       }else {
        $msg = $msg_header->as_string . "\n" . $msg_body;
       }
    
    if ($msg) {
	my $result = &sending($msg,$rcpt,$from,$robot,'','none');
	return $result;

   }else{
	return undef;
   }   
}


####################################################
# sending                              
####################################################
# send a message using smpto function or puting it
# in spool according to the context
# Signing if needed
# 
#  
# IN : -$msg(+) : ref(MIME::Entity) | string - message to send
#      -$rcpt(+) : ref(SCALAR) | ref(ARRAY) - recepients 
#       (for SMTP : "RCPT To:" field)
#      -$from(+) : for SMTP "MAIL From:" field , for 
#        spool sending : "X-Sympa-From" field
#      -$robot(+) : robot
#      -$listname : listname | ''
#      -$sign_mode(+) : 'smime' | 'none' for signing
#      -$sympa_email : for the file name for spool 
#        sending
# OUT : 1 - call to smtpto (sendmail) | 0 - push in spool
#           | undef
#  
####################################################
sub sending {
    my ($msg,$rcpt,$from,$robot,$listname,$sign_mode,$sympa_email) = @_;
    &do_log('debug3', 'mail::sending()');
    my $sympa_file;
    my $fh;
    my $signed_msg; # if signing

 
    ## FILE HANDLER
    ## Don't fork if used by a CGI (FastCGI problem)
    if (defined $send_spool) {
	unless ($sympa_email) {
	    $sympa_email = &Conf::get_robot_conf($robot, 'sympa');
	}
	
	$sympa_file = "$send_spool/T.$sympa_email.".time.'.'.int(rand(10000));
	
	my $all_rcpt;
	if (ref($rcpt) eq "ARRAY") {
	    $all_rcpt = join (',', @$rcpt);
	} else {
	    $all_rcpt = $$rcpt;
	}
	
	unless ($all_rcpt && $from) {
	    &do_log('err', 'mail::sending: missing required parameter, cannot send message');
	    return undef;
	}

	unless (open TMP, ">$sympa_file") {
	    &do_log('notice', 'mail::sending : Cannot create %s : %s', $sympa_file, $!);
	    return undef;
	}
	
	printf TMP "X-Sympa-To: %s\n", $all_rcpt;
	printf TMP "X-Sympa-From: %s\n", $from;
	printf TMP "X-Sympa-Checksum: %s\n", &tools::sympa_checksum($all_rcpt);
	
	*SMTP = \*TMP;

	
    }else {



	## SIGNING 
	if ($sign_mode eq 'smime') {
	    my $parser = new MIME::Parser;
	    $parser->output_to_core(1);
	    my $in_msg;

	    if (ref($msg) eq "MIME::Entity") {
		$in_msg = $msg;

	    }else {
		
		unless ($in_msg = $parser->parse_data($msg)) { 
		    &do_log('notice', 'mail::sending : unable to parse message for signing', $listname);
		    return undef;
		}
	    }
	    
	    unless ($signed_msg = &tools::smime_sign($in_msg,$listname, $robot)) {
		&do_log('notice', 'mail::sending : unable to sign message from %s', $listname);
		return undef;
	    }
	}
	
	*SMTP = &smtpto($from, $rcpt, $robot);
    }

   

    ## WRITING MESSAGE
    if (ref($signed_msg)) {
	$signed_msg->print(\*SMTP);

    }elsif (ref($msg) eq "MIME::Entity") {
	$msg->print(\*SMTP);
    
    }else {
	print SMTP $msg;
    }
    close SMTP;

    ## If spool sending : renaming file 
    if (defined $sympa_file) {
	my $new_file = $sympa_file;
	$new_file =~ s/T\.//g;

	unless (rename $sympa_file, $new_file) {
	    &do_log('notice', 'mail::sending : Cannot rename %s to %s : %s', $sympa_file, $new_file, $!);
	   return undef;
       }
    }


    if (defined $send_spool) {
	return 0;
    } else {
	return 1;
   }
}


##################################################################################
# smtpto                               
##################################################################################
# Makes a sendmail ready for the recipients given as argument, uses a file 
# descriptor in the smtp table which can be imported by other parties. 
# Before, waits for number of children process < number allowed by sympa.conf
# 
# IN : $from :(+) for SMTP "MAIL From:" field
#      $rcpt :(+) ref(SCALAR)|ref(ARRAY)- for SMTP "RCPT To:" field
#      $robot :(+) robot
# OUT : mail::$fh - file handle on opened file for ouput, for SMTP "DATA" field
#       | undef
#
##################################################################################
sub smtpto {
   my($from, $rcpt, $robot, $sign_mode) = @_;

   unless ($from) {
       &do_log('err', 'Missing Return-Path in mail::smtpto()');
   }
   
   if (ref($rcpt) eq 'SCALAR') {
       &do_log('debug2', 'mail::smtpto(%s, %s, %s )', $from, $$rcpt,$sign_mode);
   }else {
       &do_log('debug2', 'mail::smtpto(%s, %s, %s)', $from, join(',', @{$rcpt}), $sign_mode);
   }
   
   my($pid, $str);
   
   ## Escape "-" at beginning of recepient addresses
   ## prevent sendmail from taking it as argument
   
   if (ref($rcpt) eq 'SCALAR') {
       $$rcpt =~ s/^-/\\-/;
       }else {
       my @emails = @$rcpt;
       foreach my $i (0..$#emails) {
	   $rcpt->[$i] =~ s/^-/\\-/;
	   }
       }
   
   ## Check how many open smtp's we have, if too many wait for a few
   ## to terminate and then do our job.

   do_log('debug3',"Open = $opensmtp");
   while ($opensmtp > &Conf::get_robot_conf($robot, 'maxsmtp')) {
       do_log('debug3',"mail::smtpto: too many open SMTP ($opensmtp), calling reaper" );
       last if (&reaper(0) == -1); ## Blocking call to the reaper.
       }
    
   *IN = ++$fh; *OUT = ++$fh;
   

   if (!pipe(IN, OUT)) {
       fatal_err(sprintf gettext("Unable to create a channel in smtpto: %m"), $!); ## No return
       }
   $pid = &tools::safefork();
   $pid{$pid} = 0;
       
   my $sendmail = &Conf::get_robot_conf($robot, 'sendmail');
   my $sendmail_args = &Conf::get_robot_conf($robot, 'sendmail_args');
       
   if ($pid == 0) {
       close(OUT);
       open(STDIN, "<&IN");

       if (ref($rcpt) eq 'SCALAR') {
	   exec $sendmail, split(/\s+/,$sendmail_args), '-f', $from, $$rcpt;
       }else{
	   exec $sendmail, split(/\s+/,$sendmail_args), '-f', $from, @$rcpt;
       }
       exit 1; ## Should never get there.
       }
   if ($main::options{'mail'}) {
       $str = "safefork: $sendmail $sendmail_args -f $from ";
       if (ref($rcpt) eq 'SCALAR') {
	   $str .= $$rcpt;
       } else {
	   $str .= join(' ', @$rcpt);
       }
       do_log('notice', $str);
   }
   close(IN);
   $opensmtp++;
   select(undef, undef,undef, 0.3) if ($opensmtp < &Conf::get_robot_conf($robot, 'maxsmtp'));
   return("mail::$fh"); ## Symbol for the write descriptor.
}





####################################################
# send_in_spool      : not used but if needed ...
####################################################
# send a message by putting it in global $send_spool
#   
# IN : $rcpt (+): ref(SCALAR)|ref(ARRAY) - recepients
#      $robot(+) : robot
#      $sympa_email : for the file name
#      $XSympaFrom : for "X-Sympa-From" field
# OUT : $return->
#        -filename : name of temporary file 
#         needing to be renamed
#        -fh : file handle opened for writing
#         on 
####################################################
sub send_in_spool {
    my ($rcpt,$robot,$sympa_email,$XSympaFrom) = @_;
    &do_log('debug3', 'mail::send_in_spool(%s,%s, %s)',$XSympaFrom,$rcpt);
    
    unless ($sympa_email) {
	$sympa_email = &Conf::get_robot_conf($robot, 'sympa');
   }
   
    unless ($XSympaFrom) {
	$XSympaFrom = &Conf::get_robot_conf($robot, 'sympa'); 
    }

    my $sympa_file = "$send_spool/T.$sympa_email.".time.'.'.int(rand(10000));
    
    my $all_rcpt;
    if (ref($rcpt) eq "ARRAY") {
	$all_rcpt = join (',', @$rcpt);
    } else {
	$all_rcpt = $$rcpt;
       }
    
    unless (open TMP, ">$sympa_file") {
	&do_log('notice', 'Cannot create %s : %s', $sympa_file, $!);
	return undef;
   }

    printf TMP "X-Sympa-To: %s\n", $all_rcpt;
    printf TMP "X-Sympa-From: %s\n", $XSympaFrom;
    printf TMP "X-Sympa-Checksum: %s\n", &tools::sympa_checksum($all_rcpt);
    
    my $return;
    $return->{'filename'} = $sympa_file;     
    $return->{'fh'} = \*TMP;

    return $return;
}

#####################################################################


####################################################
# reformat_message
####################################################
# Reformat bodies of text parts contained in the message using
# recommended encoding schema and/or charsets defined by MIME::Charset.
#
# MIME-compliant headers are appended / modified.  And custom X-Mailer:
# header is appended :).
#
# IN : $msg: ref(MIME::Entity) | string - message to reformat
#      $attachments: ref(ARRAY) - messages to be attached as subparts.
# OUT : string
#
####################################################

sub reformat_message($;$) {
    my $message = shift;
    my $attachments = shift || [];
    my $msg;

    my $parser = new MIME::Parser;
    unless (defined $parser) {
	&do_log('err', "mail::reformat_message: Failed to create MIME parser");
	return undef;
    }
    $parser->output_to_core(1);

    if (ref($message) eq 'MIME::Entity') {
	$msg = $message;
    } else {
	eval {
	    $msg = $parser->parse_data($message);
	};
	if ($@) {
	    &do_log('err', "mail::reformat_message: Failed to parse MIME data");
	    return undef;
	}
    }

    $msg->head->delete("X-Mailer");
    $msg = &fix_part($msg, $parser, $attachments);
    $msg->head->add("X-Mailer", sprintf "Sympa %s", $Version::Version);
    return $msg->as_string;
}

sub fix_part($$$) {
    my $part = shift;
    my $parser = shift;
    my $attachments = shift || [];
    return $part unless $part;

    my $enc = $part->head->mime_attr("Content-Transfer-Encoding");
    # Parts with nonstandard encodings aren't modified.
    return $part
	if $enc and $enc !~ /^(?:base64|quoted-printable|[78]bit|binary)$/i;

    my $eff_type = $part->effective_type;
    return $part if $eff_type =~ m{^multipart/(signed|encrypted)$};

    if ($part->head->get('X-Sympa-Attach')) { # Need re-attaching data.
	my $data = shift @{$attachments};
	if (ref($data) ne 'MIME::Entity') {
	    eval {
		$data = $parser->parse_data($data);
	    };
	    if ($@) {
		&do_log('notice',
			"mail::reformat_message: Failed to parse MIME data");
		$data = $parser->parse_data('');
	    }
	}
	$part->head->delete('X-Sympa-Attach');
	$part->parts([$data]);
    } elsif ($part->parts) {
	my @newparts = ();
	foreach ($part->parts) {
	    push @newparts, &fix_part($_, $parser, $attachments);
	}
	$part->parts(\@newparts);
    } elsif ($eff_type =~ m{^(?:multipart|message)(?:/|\Z)}i) {
	# multipart or message types without subparts.
	return $part;
    } elsif (MIME::Tools::textual_type($eff_type)) {
	my $bodyh = $part->bodyhandle;
	# Encoded body or null body won't be modified.
	return $part if !$bodyh or $bodyh->is_encoded;

	my $head = $part->head;
	my $body = $bodyh->as_string;
	my $charset = $head->mime_attr("Content-Type.Charset");

	my ($newbody, $newcharset, $newenc) = 
	    MIME::Charset::body_encode(Encode::decode('utf8', $body), $charset,
				       Replacement => 'FALLBACK');
	if ($newenc eq $enc and $newcharset eq $charset and
	    $newbody eq $body) {
	    return $part;
	}

	# Fix headers and body.
	$head->mime_attr("Content-Type", "TEXT/PLAIN")
	    unless $head->mime_attr("Content-Type");
	$head->mime_attr("Content-Type.Charset", $newcharset);
	$head->mime_attr("Content-Transfer-Encoding", $newenc);
	$head->add("MIME-Version", "1.0") unless $head->get("MIME-Version"); 
	my $io = $bodyh->open("w");

	unless (defined $io) {
	    &do_log('err', "mail::reformat_message: Failed to save message : $!");
	    return undef;
	}

	$io->print($newbody);
	$io->close;
	$part->sync_headers(Length => 'COMPUTE');
    } else {
	# Binary or text with long lines will be suggested to be BASE64.
	$part->head->mime_attr("Content-Transfer-Encoding",
			       $part->suggest_encoding);
	$part->sync_headers(Length => 'COMPUTE');
    }
    return $part;
}

1;
