#!/usr/bin/perl
use warnings;
use strict;
use feature 'switch';
use CGI qw(:standard);               # For HTML building functions.
use Data::Dumper;
$Data::Dumper::Indent = 1;
use POE;
use POE::Component::Server::HTTP;    # For the web interface.
use POE::Component::Server::TCP;     # For the telnet interface.
use POE::Filter::WebSocket;
use POE::Wheel::ReadLine;     		 # For the cli interface.
use Protocol::WebSocket::Handshake::Server; # WebSocket implementation
use Protocol::WebSocket::Frame;
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
  Alias              => "ws_server",
  Port               => 8090,
  InlineStates       => {
  							send => \&ws_handle_send,
						 	announce => \&ws_handle_announce,
						},
  ClientFilter		 => 'POE::Filter::Stream',
  ClientConnected    => \&ws_connected,
  ClientError        => \&ws_error,
  ClientDisconnected => \&ws_disconnected,
  ClientInput        => \&ws_input,
);

### Start the chat server.
POE::Component::Server::TCP->new(
  Alias              => "chat_server",
  Port               => 32082,
  InlineStates       => {send => \&handle_send, announce => \&handle_send},
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
		announce	=> \&console_announce,
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
sub console_announce {
	my ($heap, $input) = @_[HEAP, ARG0];
	my $d= Data::Dumper->Dump([$input],["announcing"]);
	$d=~s/\n/\r\n/g; # Needed due to raw tty mode.
	$heap->{cli_wheel}->put("+ ".$d);
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
  my $session_id = $_[SESSION]->ID;
  return if(!$users{$session_id}); # I'm a zombie
  my $frame=$wsstate{$session_id}{frame};
  $heap->{client}->put(
		$frame->new($message)->to_string
		);
}

sub ws_handle_announce {
  my ($heap, $message) = @_[HEAP, ARG0];
  my $session_id = $_[SESSION]->ID;
  return if(!$users{$session_id}); # I'm a zombie
  my $frame=$wsstate{$session_id}{frame};
  $heap->{client}->put(
		$frame->new(encode_json($message))->to_string
		);
}

sub ws_connected {
  my $session_id = $_[SESSION]->ID;
  $wsstate{$session_id}{state} = "startup";
  console("WebSocket ($session_id) connected.");
}

sub ws_disconnected {
  my $session_id = $_[SESSION]->ID;
  delete $wsstate{$session_id};
  delete $users{$session_id};
  console("WebSocket ($session_id) disconnected.");
}

sub ws_error {
  my $session_id = $_[SESSION]->ID;
  delete $wsstate{$session_id};
  delete $users{$session_id};
  console("WebSocket ($session_id) error-disconnected.");
  $_[KERNEL]->yield("shutdown");
}

sub ws_input {
  my ($client_host, $session, $chunk) = @_[KERNEL, SESSION, ARG0];
  my $session_id = $_[SESSION]->ID;
  $wsstate{$session_id}{hs} = Protocol::WebSocket::Handshake::Server->new
	if (!defined $wsstate{$session_id}{hs});
  my $hs=$wsstate{$session_id}{hs};

  if (!$hs->is_done) {
	$hs->parse($chunk);

	if ($hs->is_done) {
	  $wsstate{$session_id}{frame}=Protocol::WebSocket::Frame->new;
	  $_[HEAP]{client}->put($hs->to_string);
	  console("WSConnect done.");
	  $users{$session_id} = 1;
	}
	return;
  }

  my $frame=$wsstate{$session_id}{frame};
  $frame->append($chunk);

  while (my $message = $frame->next) {
#	  $_[HEAP]{client}->put($frame->new($message)->to_string);

	# XXX: Maybe move to separate sub?
	my $client=$_[HEAP]->{client};
	console("socketinput: $message");
	my @cmd=split(/ /,$message);
	given($cmd[0]){
	  when("board"){
		$client->put($frame->new(encode_json({
			  board => $Bpardy::game->{board},
			  categories => $Bpardy::game->{cats},
			  players => $Bpardy::game->{names},
			  }))->to_string);
	  }
	  when("question"){
#		$client->put($frame->new(
#			  encode_json({question =>Bpardy::ask($cmd[1])})
#			  )->to_string
#			);
			announce({buzzer => 1,foo => 2});
	  };
	  default{
		console("unhandled input from WebSocket: $message");
	  };
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
			console("Loading result: $q");
		}
		when ("question"){
			my $q=Bpardy::ask($cmd[1]);
			console("Your q is:".encode_json($q));
		};
		when ("board"){
			console("Board: ".encode_json({board => $Bpardy::game->{board}}));
		};
		when ("buzzer"){
			announce({buzzer => 1});
		};
		default {
			console("Unknown command: >@cmd<");
		};
	};
};

sub console { # Log something to everyone. (Maybe skip WebSocket?)
  my ($message) = @_;

  # Send it to everyone.
  foreach my $user (keys %users) {
	  $poe_kernel->post($user => send => "$message");
  }
}

sub announce { # Announce game events to everyone.
  my ($message) = @_;

  # Send it to everyone.
  foreach my $user (keys %users) {
	  $poe_kernel->post($user => "announce" , $message);
  }
}
