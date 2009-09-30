# SympaSession.pm - This module includes functions managing HTTP sessions in Sympa
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


package SympaSession;

use Exporter;
@ISA = ('Exporter');
@EXPORT = ();


use Digest::MD5;
use POSIX;
use CGI::Cookie;
use Log;
use Conf;
use Time::Local;
use Text::Wrap;
use strict ;


# this structure is used to define which session attributes are stored in a dedicated database col where others are compiled in col 'data_session'
my %session_hard_attributes = ('id_session' => 1, 'date' => 1, 'remote_addr'  => 1,'robot'  => 1,'email' => 1, 'start_date' => 1, 'hit' => 1);


sub new {
    my $pkg = shift; 
    my $robot = shift;
    my $context = shift;

    my $cookie = $context->{'cookie'};
    my $action = $context->{'action'};
    my $rss = $context->{'rss'};

    do_log('debug', 'SympaSession::new(%s,%s,%s)', $robot,$cookie,$action);

    my $session={};
    bless $session, $pkg;
    
    unless ($robot) {
	&do_log('err', 'Missing robot parameter, cannot create session object') ;
	return undef;
    }

#   passive_session are session not stored in the database, they are used for crawler bots and action such as css, wsdl and rss
    
    if (&tools::is_a_crawler($robot,{'user_agent_string' => $ENV{'HTTP_USER_AGENT'}})) {
	$session->{'is_a_crawler'} = 1;
	$session->{'passive_session'} = 1;
    }
    $session->{'passive_session'} = 1 if ($rss||$action eq 'wsdl'||$action eq 'css');

    # if a session cookie exist, try to restore an existing session, don't store sessions from bots
    if (($cookie)&&($session->{'passive_session'} != 1)){
	my $status ;
	$status = $session->load($cookie) ;
	unless (defined $status) {
	    return undef;
	}
	if ($status eq 'not_found') {
	    do_log('info','SympaSession::new ignoring unknown session cookie'); # start a new session (may ne a fake cookie)
	    return (new SympaSession ($robot));
	}
	if($session->{'remote_addr'} ne $ENV{'REMOTE_ADDR'}){
	    do_log('info','SympaSession::new ignoring session cookie because remote host %s is not the original host %s', $ENV{'REMOTE_ADDR'},$session->{'remote_addr'}); # start a new session
	    return (new SympaSession ($robot));
	}
    }else{
	# create a new session context
        $session->{'id_session'} = &get_random();
	$session->{'email'} = 'nobody';
        $session->{'remote_addr'} = $ENV{'REMOTE_ADDR'};
	$session->{'date'} = time;
	$session->{'start_date'} = time;
	$session->{'hit'} = 1;
	$session->{'robot'} = $robot; 
	$session->{'data'} = '';
    }
    return $session;
}

sub load {
    my $self = shift;
    my $cookie = shift;

    do_log('debug', 'SympaSession::load(%s)', $cookie);

    unless ($cookie) {
	do_log('err', 'SympaSession::load() : internal error, SympaSession::load called with undef id_session');
	return undef;
    }
    
    my $statement ;

    if ($Conf{'db_type'} eq 'Oracle') {
	## "AS" not supported by Oracle
	$statement = "SELECT id_session \"id_session\", date_session \"date\", remote_addr_session \"remote_addr\", robot_session \"robot\", email_session \"email\", data_session \"data\", hit_session \"hit\", start_date_session \"start_date\" FROM session_table WHERE id_session = ?";
    }else {
	$statement = "SELECT id_session AS id_session, date_session AS date, remote_addr_session AS remote_addr, robot_session AS robot, email_session AS email, data_session AS data, hit_session AS hit, start_date_session AS start_date FROM session_table WHERE id_session = ?";
    }    
    my $dbh = &List::db_get_handler();
    my $sth;

    ## Check database connection
    unless ($dbh and $dbh->ping) {
	return undef unless &List::db_connect();
    }
    unless ($sth = $dbh->prepare($statement)) {
	do_log('err','Unable to prepare SQL statement : %s', $dbh->errstr);
	return undef;
    }
    unless ($sth->execute($cookie)) {
	do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
	return undef;
    }    
    my $session = $sth->fetchrow_hashref('NAME_lc');
    $sth->finish();
    
    unless ($session) {
	return 'not_found';
    }
    
    my %datas= &tools::string_2_hash($session->{'data'});
    foreach my $key (keys %datas) {$self->{$key} = $datas{$key};} 

    $self->{'id_session'} = $session->{'id_session'};
    $self->{'date'} = $session->{'date'};
    $self->{'start_date'} = $session->{'start_date'};
    $self->{'hit'} = $session->{'hit'} +1 ;
    $self->{'remote_addr'} = $session->{'remote_addr'};
    $self->{'robot'} = $session->{'robot'};
    $self->{'email'} = $session->{'email'};

    return ($self);
}


sub store {

    my $self = shift;
    do_log('debug', 'SympaSession::store()');

    return undef unless ($self->{'id_session'});
    return if ($self->{'is_a_crawler'}); # do not create a session in session table for crawlers; 
    return if ($self->{'passive_session'}); # do not create a session in session table for action such as RSS or CSS or wsdlthat do not require this sophistication; 

    my %hash ;    
    foreach my $var (keys %$self ) {
	next if ($session_hard_attributes{$var});
	next unless ($var);
	$hash{$var} = $self->{$var};
    }
    my $data_string = &tools::hash_2_string (\%hash);
    my $dbh = &List::db_get_handler();
    my $sth;

    ## Check database connection
    unless ($dbh and $dbh->ping) {
	return undef unless &List::db_connect();
    }	   

#    my $count_statement = sprintf "SELECT count(*) FROM session_table WHERE (id_session=%s)",$self->{'id_session'};
#    
#    unless ($sth = $dbh->prepare($count_statement)) {
#      	do_log('err','Unable to prepare SQL statement %s : %s',$count_statement, $dbh->errstr);
#	return undef;
#    }
#    
#    unless ($sth->execute) {
#	do_log('err','Unable to execute SQL statement "%s" : %s', $count_statement, $dbh->errstr);
#	return undef;
#    }    
#    my $total =  $sth->fetchrow;
#    if ($total != 0) {
#	my $del_statement = sprintf "DELETE FROM session_table WHERE (id_session=%s)",$self->{'id_session'};
#	do_log('debug3', 'SympaSession::store() : removing existing Session del_statement = %s',$del_statement);	
#	unless ($dbh->do($del_statement)) {
#	    do_log('info','SympaSession::store unable to remove existing session %s to update it',$self->{'id_session'});
#	    return undef;
#	}	
#    }

    my $del_statement = sprintf "DELETE FROM session_table WHERE (id_session=%s)",$self->{'id_session'};
    unless ($dbh->do($del_statement)) {
	    do_log('debug3','SympaSession::store unable to remove session %s, new session ?',$self->{'id_session'});
	}	 
    # in order to prevent session hijacking, the session_id (used as http cookie) is renewed for each clic
    $self->{'id_session'} = &get_random();

    my $add_statement = sprintf "INSERT INTO session_table (id_session, date_session, remote_addr_session, robot_session, email_session, start_date_session, hit_session, data_session) VALUES ('%s','%s','%s','%s','%s','%s','%s','%s')",$self->{'id_session'},time,$ENV{'REMOTE_ADDR'},$self->{'robot'},$self->{'email'},$self->{'start_date'},$self->{'hit'}, $data_string;
    unless ($dbh->do($add_statement)) {
	do_log('err','Unable to update session information in database while execute SQL statement "%s" : %s', $add_statement, $dbh->errstr);
	return undef;
    }    
}

## remove old sessions from a particular robot or from all robots. delay is a parameter in seconds
## 
sub purge_old_sessions {

    my $robot = shift;

    do_log('info', 'SympaSession::purge_old_sessions(%s,%s)',$robot);

    my $delay = &tools::duration_conv($Conf{'session_table_ttl'}) ; 
    my $anonymous_delay = &tools::duration_conv($Conf{'anonymous_session_table_ttl'}) ; 

    unless ($delay) { do_log('info', 'SympaSession::purge_old_session(%s) exit with delay null',$robot); return;}
    unless ($anonymous_delay) { do_log('info', 'SympaSession::purge_old_session(%s) exit with anonymous delay null',$robot); return;}

    my @sessions ;
    my  $sth;

    my $dbh = &List::db_get_handler();

    my $robot_condition = sprintf "robot_session = %s", $dbh->quote($robot) unless (($robot eq '*')||($robot));

    my $delay_condition = time-$delay.' > date_session' if ($delay);
    my $anonymous_delay_condition = time-$anonymous_delay.' > date_session' if ($anonymous_delay);

    my $and = ' AND ' if (($delay_condition) && ($robot_condition));
    my $anonymous_and = ' AND ' if (($anonymous_delay_condition) && ($robot_condition));

    my $count_statement = sprintf "SELECT count(*) FROM session_table WHERE $robot_condition $and $delay_condition";
    my $anonymous_count_statement = sprintf "SELECT count(*) FROM session_table WHERE $robot_condition $anonymous_and $anonymous_delay_condition AND email_session = 'nobody' AND hit_session = '1'";


    my $statement = sprintf "DELETE FROM session_table WHERE $robot_condition $and $delay_condition";
    my $anonymous_statement = sprintf "DELETE FROM session_table WHERE $robot_condition $anonymous_and $anonymous_delay_condition AND email_session = 'nobody' AND hit_session = '1'";

    ## Check database connection
    unless ($dbh and $dbh->ping) {
	return undef unless &List::db_connect();
    }	   
    unless ($sth = $dbh->prepare($count_statement)) {
	do_log('err','Unable to prepare SQL statement %s : %s',$count_statement, $dbh->errstr);
	return undef;
    }
    
    unless ($sth->execute) {
	do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
	return undef;
    }    
    my $total =  $sth->fetchrow;
    if ($total == 0) {
	do_log('debug','SympaSession::purge_old_sessions no sessions to expire');
    }else{
	unless ($sth = $dbh->prepare($statement)) {
	    do_log('err','Unable to prepare SQL statement : %s', $dbh->errstr);
	    return undef;
	}
	unless ($sth->execute) {
	    do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
	    return undef;
	}    
    }
    unless ($sth = $dbh->prepare($anonymous_count_statement)) {
	do_log('err','Unable to prepare SQL statement %s : %s',$anonymous_count_statement, $dbh->errstr);
	return undef;
    }
    unless ($sth->execute) {
	do_log('err','Unable to execute SQL statement "%s" : %s', $anonymous_statement, $dbh->errstr);
	return undef;
    }    
    my $anonymous_total =  $sth->fetchrow;
    if ($anonymous_total == 0) {
	do_log('debug','SympaSession::purge_old_sessions no anonymous sessions to expire');
	return $total ;
    }
    unless ($sth = $dbh->prepare($anonymous_statement)) {
	do_log('err','Unable to prepare SQL statement : %s', $dbh->errstr);
	return undef;
    }
    unless ($sth->execute) {
	do_log('err','Unable to execute SQL statement "%s" : %s', $anonymous_statement, $dbh->errstr);
	return undef;
    }    
    return $total+$anonymous_total;
}

# list sessions for $robot where last access is newer then $delay. List is limited to connected users if $connected_only
sub list_sessions {
    my $delay = shift;
    my $robot = shift;
    my $connected_only = shift;

    do_log('debug', 'SympaSession::list_session(%s,%s,%s)',$delay,$robot,$connected_only);

    my @sessions ;
    my $sth;

    my $dbh = &List::db_get_handler();

    my $condition = sprintf "robot_session = %s", $dbh->quote($robot) unless ($robot eq '*');
    my $condition2 = time-$delay.' < date_session ' if ($delay);
    my $and = ' AND ' if (($condition) && ($condition2));
    $condition = $condition.$and.$condition2 ;

    my $condition3 =  " email_session != 'nobody' " if ($connected_only eq 'on');
    my $and2 = ' AND '  if (($condition) && ($condition3));
    $condition = $condition.$and2.$condition3 ;

    my $statement = sprintf "SELECT remote_addr_session, email_session, robot_session, date_session, start_date_session, hit_session FROM session_table WHERE $condition";
    do_log('debug', 'SympaSession::list_session() : statement = %s',$statement);

    ## Check database connection
    unless ($dbh and $dbh->ping) {
	return undef unless &List::db_connect();
    }	   
    unless ($sth = $dbh->prepare($statement)) {
	do_log('err','Unable to prepare SQL statement : %s', $dbh->errstr);
	return undef;
    }
    
    unless ($sth->execute) {
	do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
	return undef;
    }
    
    while (my $session = ($sth->fetchrow_hashref('NAME_lc'))) {

	$session->{'formated_date'} = &Language::gettext_strftime ("%d %b %y  %H:%M", localtime($session->{'date_session'}));
	$session->{'formated_start_date'} = &Language::gettext_strftime ("%d %b %y  %H:%M", localtime($session->{'start_date_session'}));

	# do_log('debug', 'SympaSession::list_session() DUMP : %s,%s,%s,%s',$session->{'remote_addr_session'}, $session->{'email_session'}, $session->{'robot_session'}, $session->{'formated_date'});

	push @sessions, $session;
    }

    $sth->finish();
    return \@sessions;
}

###############################
# Subroutines to read cookies #
###############################

## Generic subroutine to get a cookie value
sub get_session_cookie {
    my $http_cookie = shift;

    my %cookies = parse CGI::Cookie($http_cookie);
        
    foreach (keys %cookies) {
	my $cookie = $cookies{$_};
	next unless ($cookie->name eq 'sympa_session');
	return ($cookie->value);
    }

    return (undef);
}


## Generic subroutine to set a cookie
## Set user $email cookie, ckecksum use $secret, expire=(now|session|#sec) domain=(localhost|<a domain>)
sub set_cookie {
    my ($self, $http_domain, $expires) = @_ ;
    do_log('debug','Session::set_cookie(%s,%s)',$http_domain, $expires);

    my $expiration;
    if ($expires =~ /now/i) {
	## 10 years ago
	$expiration = '-10y';
    }else{
	$expiration = '+'.$expires.'m';
    }

    if ($http_domain eq 'localhost') {
	$http_domain="";
    }

    my $cookie;
    if ($expires =~ /session/i) {
	$cookie = new CGI::Cookie (-name    => 'sympa_session',
				   -value   => $self->{'id_session'},
				   -domain  => $http_domain,
				   -path    => '/'
				   );
    }else {
	$cookie = new CGI::Cookie (-name    => 'sympa_session',
				   -value   => $self->{'id_session'},
				   -expires => $expiration,
				   -domain  => $http_domain,
				   -path    => '/'
				   );
    }

    ## Send cookie to the client
    printf "Set-Cookie: %s\n", $cookie->as_string;
    return 1;
}
    

sub get_random {
    do_log('debug', 'SympaSession::random ');
     my $random = int(rand(10**7)).int(rand(10**7)); ## Concatenates 2 integers for a better entropy
     $random =~ s/^0(\.|\,)//;
     return ($random)
}

1;

