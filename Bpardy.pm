package Bpardy;
use warnings;
use strict;
use autodie;
use feature qw(switch);

our $game;
our $questions;

sub cat2id;
sub id2cat;

sub ply2id;
sub id2ply;

###
### small Helper functions
###

sub dbg {print "dummy-dbg: @_\n"};
sub setdebug{
	no warnings 'redefine';
	*Bpardy::dbg=shift;
};
sub err { # TODO: Need to think about error handling
	dbg (@_);
	die @_;
};

###
### main game logic
###

sub setup {
	$game={
		players => 3,
		names => [qw(Foo Bar Baz)],
		scores => [0,0,0],
	};
};

sub boardsetup {
	my ($quest,@cats)=@_;
	$game->{cats}=\@cats;
	my @gui;
	for my $cat (0..$#cats+1){
		for my $pts (0..$quest-1){
			$gui[$cat][$pts]= {
				state=>"free",
				score=>($pts+1)*100
			};
		};
	};
	$game->{board}=\@gui;
	return 1;
};

sub load { # Old-style load -- a bit Hacky.
	my $gamefile=shift;
	my $q=5;		# Wieviele Fragen/Kategorie?

	my %jdata;
	my $qwidth=35;					# Width of a question.

	open (J,"<Jeopardy") || die;
	my ($nam,$c);
	while (<J>){
		chomp;
		next if ((!defined $nam) && (!/^>/));
		next if /^\s*(#|$)/;
		if (/^>(.*)/){
			$nam=$1;
			$c=0;
			next;
		}
		$_.=" ";
		if (!s/(?<!\\)\\n/\n/g){
			s/(.{10,$qwidth})\s+/$1\n/mg;
		};
		s/\\\\/\\/mg;
		$jdata{$nam}[++$c]=$_;
	};
	<J>;
	close(J);

	my @Cat;			# Namen der Kategorien
	$gamefile .= ".jg" if ( -f $gamefile.".jg" );
	$gamefile =~ /^([^.]+)(.jg)?/;
	my $title=$1;		# Titel des Spielfelds.

	&dbg ("Reading game '$title' ...");
	open(G,"<$gamefile") || die;
	while (<G>){
		chomp;
		next if (/^\s*(#|$)/);
		push @Cat,$_;
	};
	<G>;
	close(G);

	boardsetup($q,@Cat);
	my $p=0;
	my $qid=0;
	for (@Cat){
#		printf "%-20s:%2d\n",$_,$#{$jdata{$_}} if ($debug);
		if ($#{$jdata{$_}} < $q){
			print "ERROR: not enough questions in \"$_\"\n";
			$p++;
		};
		if ($#{$jdata{$_}} > $q){
#			print "WARN : too many questions in \"$_\"\n";
#			$p++;
		};
		for my $theq (0..$q-1){
			$qid++;
			$game->{board}[cat2id $_][$theq]{qid}=$qid;
			if($jdata{$_}[$theq+1] =~ m!\[img:(.*)\]!){
				$questions->{$qid}= {
					type => "image",
					url  => $1.".png",
				};
			}else{
				$questions->{$qid}= {
					type => "text",
					text => $jdata{$_}[$theq+1],
				};
			};
		};
	};

	return "$title (".join("/",@Cat).")";
};

sub ask {
	my $id=shift;
	# TODO: dies the q exist at all?
	return $questions->{$id} ;
};

sub answer {
	my $obj = shift;
	if (!defined $questions->{$obj->{id}}){
		err ("Answer with nonexistant id");
	};
	# TODO: more syntax checks
	$game->{board}{$obj->{id}}{state}="taken";
	given ($obj->{type}){
		when ("correct") {
			$game->{board}{$obj->{id}}{state}="taken";
			$game->{board}{$obj->{id}}{color}=$obj->{player};
			$game->{board}{$obj->{id}}{names}[0]=$obj->{player}; # XXX: push
			$game->{score}[$obj->{player}]+=$game->{board}{$obj->{id}}{score};
		};
		when ("wrong") {
			$game->{board}{$obj->{id}}{state}="taken";
			$game->{board}{$obj->{id}}{color}=$obj->{player};
			$game->{board}{$obj->{id}}{names}[0]="-".$obj->{player}; # XXX: push
			$game->{score}[$obj->{player}]-=$game->{board}{$obj->{id}}{score};
		};
		default {
			err("unknown answer type");
		}
	};
};


###
### id translat0rs
###

sub cat2id {
	my $id=0;
	for my $cat (@{$game->{cats}}){
		return $id if $cat eq $_[0];
		$id++;
	};
};

sub id2cat {
	return $game->{cats}[$_[0]-1];
};

sub ply2id {
	my $id=0;
	for my $ply (@{$game->{names}}){
		return $id if $ply eq $_[0];
		$id++;
	};
};

sub id2ply {
	return $game->{names}[$_[0]-1];
};

1;

