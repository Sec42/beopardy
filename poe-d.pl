#!/usr/bin/perl
use warnings;
use strict;
use feature 'switch';
use CGI qw(:standard);               # For HTML building functions.
use POE;
use POE::Component::Server::HTTP;    # For the web interface.
use POE::Component::Server::TCP;     # For the telnet interface.
use POE::Filter::WebSocket;
use POE::Wheel::ReadLine;     		 # For the cli interface.
use JSON;

use Bpardy;

sub MAX_LOG_LENGTH () { 50 }
my @chat_log;
### Start the web server.
POE::Component::Server::HTTP->new(
  Port           => 32080,
  ContentHandler => {"/" => \&web_handler, },
  StreamHandler	 => \&stream,
  Headers        => {Server => 'POEpardy/1.0'},
);

### Start the websocket-server.
POE::Component::Server::TCP->new( 
# XXX: defaults to POE::Filter::Line w/ autodetect. Should fix it to \r\n
  Alias              => "ws_server",
  Port               => 8090,
  InlineStates       => {send => \&ws_handle_send},
  ClientConnected    => \&ws_connected,
  ClientError        => \&ws_error,
  ClientDisconnected => \&ws_disconnected,
  ClientInput        => \&ws_input,
);

### Start the chat server.
POE::Component::Server::TCP->new(
  Alias              => "chat_server",
  Port               => 32082,
  InlineStates       => {send => \&handle_send},
  ClientConnected    => \&client_connected,
  ClientError        => \&client_error,
  ClientDisconnected => \&client_disconnected,
  ClientInput        => \&client_input,
);

### Start the cli.
POE::Session->create(
	inline_states => {
		_start		=> \&cli_init,
		send		=> \&console_output,
		cli_input	=> \&console_input,
	},
);

### Run the servers together, and exit when they are done.
$poe_kernel->run();
exit 0;

my %users;

###
### Handlers for the cli.
###
sub cli_init {
	my $heap = $_[HEAP];
	my $session_id = $_[SESSION]->ID;
	$heap->{cli_wheel} = POE::Wheel::ReadLine->new(InputEvent => 'cli_input');
	$heap->{cli_wheel}->get("=> ");
	$users{$session_id} = 1;
	$_[KERNEL]->yield("cli_input","load Runde1");
	Bpardy::setdebug(sub { $heap->{cli_wheel}->put("dbg: @_");});
};

sub console_input {
	my ($heap, $input, $exception) = @_[HEAP, ARG0, ARG1];
	if (defined $input) {
		$heap->{cli_wheel}->addhistory($input);
#		$heap->{cli_wheel}->put("You Said: $input");
		handle_command($input);
	} elsif ($exception eq 'cancel') {
		$heap->{cli_wheel}->put("Canceled.");
	} else {
		$heap->{cli_wheel}->put("Bye.");
		delete $heap->{cli_wheel};
		exit(-1); # XXX: should be a clean shutdown.
		return;
	}

	# Prompt for the next bit of input.
	$heap->{cli_wheel}->get("=> ");
};

sub console_output {
	my ($heap, $input) = @_[HEAP, ARG0];
	$heap->{cli_wheel}->put("+ $input");
}


###
### Handlers for the web server.
###
sub web_handler {
  my ($request, $response) = @_;

  # Build the response.
  $response->code(RC_OK);
  $response->push_header("Content-Type", "text/html");
  my $count = @chat_log;
  my $content =
    start_html("Last $count messages.") . h1("Last $count messages.");
  if ($count) {
    $content .= ul(li(\@chat_log));
  }
  else {
    $content .= p("Nothing has been said yet.");
  }
  $content .= end_html();
  $response->content($content);

  # Signal that the request was handled okay.
  return RC_OK;
}

###
### Handlers for the websocket server.
###

my %wsstate;

sub ws_handle_send {
  my ($heap, $message) = @_[HEAP, ARG0];
  $heap->{client}->put($message);
}

sub ws_connected {
  my $session_id = $_[SESSION]->ID;
  $wsstate{$session_id}{state} = "startup";
  announce("WebSocket ($session_id) connected.");
}

sub ws_disconnected {
  my $session_id = $_[SESSION]->ID;
  delete $wsstate{$session_id};
  announce("WebSocket ($session_id) disconnected.");
}

sub ws_error {
  my $session_id = $_[SESSION]->ID;
  delete $wsstate{$session_id};
  announce("WebSocket ($session_id) error-disconnected.");
  $_[KERNEL]->yield("shutdown");
}

sub ws_input {
  my ($client_host, $session, $input) = @_[KERNEL, SESSION, ARG0];
  my $session_id = $_[SESSION]->ID;
  given($wsstate{$session_id}{state}){
	  when("startup"){
		  my ($get,$url,$proto)=split(/ /,$input);
		  $wsstate{$session_id}{url}=$url;
		  if($get ne "GET" || $proto ne "HTTP/1.1"){
			  announce("broken WSConnect ($input)");
			  $_[KERNEL]->yield("shutdown");
		  };
		  announce("WSConnect to $url");
		  $wsstate{$session_id}{state}="headers";
	  };
	  when("headers"){
		  if($input eq ""){ # End of Headers....
			  if ($wsstate{$session_id}{hdr}{Upgrade} ne "WebSocket" ||
			      $wsstate{$session_id}{hdr}{Connection} ne "Upgrade" ){
				  announce("broken headers in WSConnect");
				  $_[KERNEL]->yield("shutdown");
			  };
			  my $client=$_[HEAP]->{client}; # Who defines that?

			  $client->put("HTTP/1.1 101 Web Socket Protocol Handshake");
			  $client->put("Upgrade: WebSocket");
			  $client->put("Connection: Upgrade");
			  $client->put("WebSocket-Origin: ".
					  $wsstate{$session_id}{hdr}{Origin}
			  );
			  $client->put("WebSocket-Location: "."ws://".
				  $wsstate{$session_id}{hdr}{Host}.
				  $wsstate{$session_id}{url}
			  );
			  $client->put("");

			  $client->set_filter( POE::Filter::WebSocket->new() );
			  $wsstate{$session_id}{state}="connected";
		  }else{
#			  announce("Header(".$session->ID."): $input");
			  my ($hdr,$value)=split(/:\s+/,$input);
			  $hdr=~y/a-zA-Z//cd;
			  $wsstate{$session_id}{hdr}{$hdr}=$value;
		  };
	  };
	  when("connected"){ # XXX: Maybe move to separate sub?
		  my $client=$_[HEAP]->{client};
		  announce("socketinput: $input");
		  my @cmd=split(/ /,$input);
		  given($cmd[0]){
			  when("board"){
				  $client->put(encode_json({
							  board => $Bpardy::game->{board},
							  categories => $Bpardy::game->{cats},
							  players => $Bpardy::game->{names},
							  }));
			  }
			  when("question"){
				  $client->put(encode_json({question =>Bpardy::ask($cmd[1])}));
			  };
			  default{
				  $client->put("out ! reflect:$input");
			  };
		  };
	  };
	  default {
		  announce("WebSocket in unknown state");
		  $_[KERNEL]->yield("shutdown");
	  };
  };
}


###
### Handlers for the chat server.
###

sub broadcast {
  my ($sender, $message) = @_;

  # Log it for the web.  This is the only part that's different from
  # the basic chat server.
  push @chat_log, "$sender $message";
  shift @chat_log if @chat_log > MAX_LOG_LENGTH;

  # Send it to everyone.
  foreach my $user (keys %users) {
    if ($user == $sender) {
      $poe_kernel->post($user => send => "You $message");
    }
    else {
      $poe_kernel->post($user => send => "$sender $message");
    }
  }
}

sub handle_send {
  my ($heap, $message) = @_[HEAP, ARG0];
  $heap->{client}->put($message);
}

sub client_connected {
  my $session_id = $_[SESSION]->ID;
  $users{$session_id} = 1;
  broadcast($session_id, "connected.");
}

sub client_disconnected {
  my $session_id = $_[SESSION]->ID;
  delete $users{$session_id};
  broadcast($session_id, "disconnected.");
}

sub client_error {
  my $session_id = $_[SESSION]->ID;
  delete $users{$session_id};
  broadcast($session_id, "disconnected(error).");
  $_[KERNEL]->yield("shutdown");
}

sub client_input {
  my ($client_host, $session, $input) = @_[KERNEL, SESSION, ARG0];
  broadcast($session->ID, "said: $input");
  handle_command($input);
}

###
### Other functions.
###

sub handle_command{
	my @cmd=split(/ /,shift);
	given($cmd[0]){
		when ("load"){
			my $q=Bpardy::load($cmd[1]);
			announce("Loading result: $q");
		}
		when ("question"){
			my $q=Bpardy::ask($cmd[1]);
			announce("Your q is:".encode_json($q));
		};
		when ("board"){
			announce("Board: ".encode_json({board => $Bpardy::game->{board}}));
		};
		default {
			announce("Unknown command: >@cmd<");
		};
	};
};

sub announce {
  my ($message) = @_;

  # Send it to everyone.
  foreach my $user (keys %users) {
	  $poe_kernel->post($user => send => "$message");
  }
}
