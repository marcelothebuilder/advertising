############################################################
# advertising plugin by Revok
#
# Copyright (c) 2012 Revok
############################################################
package advertising;

use strict;
use Plugins;
use lib $Plugins::current_plugin_folder;
use Log qw(message error warning);
use Globals;
use Settings;
use Utils;
use Misc;
use RevokUtils::OldParsers;
use I18N qw(bytesToString stringToBytes);
use Scalar::Util qw(blessed);
use Settings;
use Task;
use Task::Timeout;
Plugins::register("advertising", "advertising plugin", \&unload);

my $hooks = Plugins::addHooks(
	['in_game',	\&in_game],
	['packet_privMsg',	\&received_pm],
	['AI_pre',			\&ai_manager],
	['start3',       \&onstart3, undef],
	['player_added_to_cache',				\&player_added_to_cache]
);

my $commands_hooks = Commands::register(
	['spams', 'change material', \&cmdSpamStatistics],
	['spam', 'change material', \&cmdSpamStatistics],
);

my %statistics;
my %configx;
my @optout;
my $default_cycle = 1;
my $pluginfolder = $Plugins::current_plugin_folder;
my $db_loaded;
my $cfID;
my $arID;
# in_game();

sub onstart3 {
	#&checkConfig;
	$cfID = Settings::addControlFile('spam.txt', loader => [\&parseSectionedFile,\%configx], mustExist => 1);
	$arID = Settings::addControlFile('spam_optout.txt', loader => [\&parseStringList_toArray,\@optout], mustExist => 1);
	Settings::loadByHandle($cfID);
	Settings::loadByHandle($arID);
}

sub in_game {
	return if $db_loaded;
	# print "Parsing ".$pluginfolder.'/spam_'.lc($servers[$config{'server'}]{'name'}).'.txt'."\n";
	# parseSectionedFile($pluginfolder.'/spam_'.lc($servers[$config{'server'}]{'name'}).'.txt', \%configx) or die $_;
	# parseStringList_toArray($pluginfolder.'/spam_'.lc($servers[$config{'server'}]{'name'}).'_optout.txt', \@optout);
	$db_loaded = 1;
}

sub cmdSpamStatistics {
	message "=========================\n";
	message "These are this session stats:\n";
	message sprintf("Total of spammed players: %s\n", $statistics{spammed});
	message sprintf("Total of optouts: %s\n", @optout);
	message "Interest data: \n";
	foreach my $data (keys %{$statistics{pmmatches}}) {
		message sprintf(" [%s] - %s \n", $data, $statistics{pmmatches}{$data});
	}
	
	message "=========================\n";
}

sub unload {
	Plugins::delHook($hooks);
	undef %configx;
}

sub received_pm {
	my (undef, $args) = @_;
	message ("Received from $args->{privMsgUser}: $args->{privMsg} \n");
	my $player = $args->{privMsgUser};
	my $msg = $args->{privMsg};
	$msg =~ s/\"//g;
	$msg =~ s/^\s+//g;
	$msg =~ s/\s+$//g;
	$msg =~ s/ç/c/g;
	$msg = lc($msg);
	if ($msg =~ /autom.tica/) {
		return;
	} elsif ($configx{$msg}) {
		$statistics{pmmatches}{$msg}++;
		reply($msg, $player);
	} else {
		reply('invalid', $player);
	}
}

sub ai_manager {
	if ((AI::action eq "advSpammer") && (time > AI::args->{time})) {
		return 0 unless (defined AI::args->{nick});
		sendMessage($messageSender, "pm", AI::args->{message}, AI::args->{nick});
		AI::dequeue;
	}
}

sub spam_player {
	my ($player) = @_;
	#my $player = $playersList->getByID($args->{ID});
	
	if ($player =~ /^\[.*\]|^teste|GM/) { # skip GMs
		error("Found a GM ($player) ! We won't spam him ! \n");
		$statistics{found_gms}{name} = $player;
		return 0;
	}
	
	if ($player) {
		my $playerx = $player;
		$statistics{spammed}++;
		if (isIn_StringList(\@optout, $playerx)) {
			message("[spam] player [".$playerx."] optedout ! \n", "info");
			return;
		}
		$default_cycle = 1 if (!$configx{'default'.$default_cycle});
		reply('default'.$default_cycle, $playerx);
		$default_cycle++;
	}
}
#getControlFilename( 
sub reply {
	my ($group, $player) = @_;
	#return if (AI::args->{nick} == $player);
	#chomp($player);
	if (!$configx{$group}) {
		message("Player asked for \"$group\" = undefined group \n", "info");
		return 0;
	}
	message("[spam] [".$player."] with ".@{$configx{$group}}." ($group) messages \n", "info");
	my $i = 0;
	$i = $i + 10 if ($group =~ /^default/);
	foreach my $msgx (@{$configx{$group}}) {
		my $msg = $msgx;
		next if !length($msg);
		chomp($msg);
		#$msg = lc($msg);
		if ($msg =~ /%optout/) {
			push (@optout, $player);
			error("[spam] Adding [".$player."] to optout list :(\n");
			reWrite_StringList(Settings::getControlFilename('spam_optout.txt'), \@optout);
			next;
		}
		$msg =~ s/%target_nick/$player/;
		queueMessage($player, $msg, $i);
		$i = $i + 0.3;
	}
}



sub queueMessage {
	my ($nick, $message, $additional_time) = @_;
	return 0 unless (defined $nick);
		
	$taskManager->add(new Task::Timeout(
		function => sub {
			sendMessage($messageSender, "pm", $message, $nick);
		},
		seconds => $additional_time,
	));
	
	
	# my %spamArgs;
	# $spamArgs{nick} = $nick;
	# $spamArgs{message} = $message;
	# $spamArgs{time} = time + 6;
	# AI::queue("advSpammer", \%spamArgs);
	return 1;
}

*Network::Send::sendPrivateMsg =
sub {
	my ($self, $user, $message) = @_;
	$self->sendToServer($self->reconstruct({
		switch => 'private_message',
		privMsg => $message,
		privMsgUser => $user,
	}));
};

##
# updatePlayerNameCache(player)
# player: a player actor object.
*Network::Receive::updatePlayerNameCache =
*Misc::updatePlayerNameCache = sub {
	my ($player) = @_;
	
	# return if (!$config{cachePlayerNames});

	# First, cleanup the cache. Remove entries that are too old.
	# Default life time: 15 minutes
	my $changed = 1;
	for (my $i = 0; $i < @playerNameCacheIDs; $i++) {
		my $ID = $playerNameCacheIDs[$i];
		if (timeOut($playerNameCache{$ID}{time}, $config{cachePlayerNames_duration})) {
			delete $playerNameCacheIDs[$i];
			delete $playerNameCache{$ID};
			$changed = 1;
		}
	}
	compactArray(\@playerNameCacheIDs) if ($changed);

	# Resize the cache if it's still too large.
	# Default cache size: 100
	while (@playerNameCacheIDs > $config{cachePlayerNames_maxSize}) {
		my $ID = shift @playerNameCacheIDs;
		delete $playerNameCache{$ID};
	}

	# Add this player name to the cache.
	my $ID = $player->{ID};
	if (!$playerNameCache{$ID}) {
	# We'll only get here if this players is new
	
		push @playerNameCacheIDs, $ID;
		my %entry = (
			ID => $player->{ID},
			name => $player->{name},
			guild => $player->{guild},
			time => time,
			lv => $player->{lv},
			jobID => $player->{jobID},
			object_type => Scalar::Util::blessed($player)
		);
		$playerNameCache{$ID} = \%entry;
		Plugins::callHook("player_added_to_cache", \%entry);
	}
};

sub player_added_to_cache {
	my ($caller, $args) = @_;
	if ($args->{object_type} ne "Actor::Player") { error "[spam] Skipping ".$args->{name}.", object type: ".$args->{object_type}."\n"; return;}
	spam_player($args->{name});
}

1; 