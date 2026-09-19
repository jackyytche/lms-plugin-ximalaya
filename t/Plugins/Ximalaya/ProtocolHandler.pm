# Plugins::Ximalaya::ProtocolHandler
#
# Plays xmly://<trackId> pseudo-URLs: resolves the real (time-limited) audio
# URL through the Ximalaya API at play time and hands it to the HTTPS streamer.
# Pattern follows Slim::Plugin::Podcast::ProtocolHandler.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Music::Info;
use Slim::Schema;        # 0.1.44: queue fallback reads the track row
use Slim::Utils::Cache;  # 0.1.44: queue fallback reads remote_image_
use Scalar::Util qw(blessed);

use Plugins::Ximalaya::API;

my $log = logger('plugin.ximalaya');

Slim::Player::ProtocolHandlers->registerHandler('xmly', __PACKAGE__);

# 0.1.26: declare TRANSCODER-LEVEL seek support. Song::canDoSeek (Song.pm
# L843) returns canSeek=2 only when the protocol handler answers
# canTranscodeSeek. canSeek=2 makes Song::open (L402/L432) run the reopen
# with wantOptions('T') and set $transcoder->{'start'} = timeOffset, so
# tokenizeConvertCommand2 fills the $START$ placeholder of the transcode
# command. This matters on Daphile: the player chain is the daphile
# "Decode" program (mp4-wav-daphile-*, streamMode=R) whose command template
# is "-f wav $START$ $END$ $RESAMPLE$ $PATH$" - the decoder fetches the
# remote URL itself, so WITHOUT $START$ every seek reopened the stream at
# byte 0 (progress bar kept the old position, audio restarted). Device log
# 13:54:54 proved the chain: seek=true time=20.64 canSeek=1 -> tokenized
# command with EMPTY start. With canSeek=2 the decoder receives the start
# offset and honors it.
sub canTranscodeSeek { 1 }

# 0.1.34: the NATIVE whole-album enqueue. When LMS runs playlist play/add on
# a URL whose protocol handler can explodePlaylist, it asks the handler for
# the full track list and executes 'playlist playtracks/addtracks listRef'
# with it (Slim::Control::Commands.pm L1383-1400 - the exact mechanism the
# source cites as "eg. Spotify Album -> track list"). xmly://album/<id>
# explodes into the ordered xmly:// track URL list (API::albumTracksAll:
# chained list tiers, 1h in-memory cache); each track then resolves lazily
# at its turn through the normal chain. Plain track URLs explode to
# themselves so single-track play/add behave exactly as before. (The 0.1.33
# m3u route was the wrong tool: the plain HTTP handler has no
# explodePlaylist, so the .m3u URL was played as ONE audio stream - silence.)
sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	my ($albumId) = $url =~ m|^xmly://album/(\d+)$|;
	unless ($albumId) {
		$cb->([$url]);
		return;
	}

	Plugins::Ximalaya::API->albumTracksAll($albumId,
		sub {
			my ($tracks) = @_;

			# 0.1.44: publish display metadata for the whole list BEFORE the
			# URLs enter the playlist. The status query asks getMetadataFor
			# for EVERY queued row (Slim::Control::Queries L5726-5733), and
			# without an enqueue-time publication the not-yet-played rows
			# rendered completely blank (no title, no artwork, duration 0)
			# until their turn came. The list data is already in hand - zero
			# extra API calls.
			$class->_publish_queue_metadata($tracks);

			$cb->([ map { 'xmly://' . $_->{id} } @$tracks ]);
		},
		sub {
			$cb->([]);
		},
	);

	return;
}

sub scanUrl {
	my ($class, $url, $args) = @_;

	my $song = $args->{song};
	my $cb   = $args->{cb};

	my ($trackId) = $url =~ m|^xmly://(?:track/)?(\d+)|;
	unless ($trackId) {
		$log->error("Ximalaya: cannot parse $url");
		$cb->(undef);
		return;
	}

	# 0.1.25 seek fast-path: answer SYNCHRONOUSLY when a fresh resolve is in
	# the cache. A seek makes LMS rebuild the song and re-run scanUrl; with
	# the async resolve (~1.5-3.5s gap) the controller treated the player as
	# stopped and rebuilt the song WITHOUT seekdata - the track restarted
	# from 0 and every progress-bar drag was broken. Device A/B 2026-09-11:
	# the same CDN URL seeks fine when played raw, so a zero-gap sync re-open
	# (seekdata kept, Range honored) restores seek exactly like a plain
	# remote URL. The cb runs in-place - safe here, Song's cb only advances
	# the open flow.
	if (my $info = Plugins::Ximalaya::API->peek_resolve($trackId)) {
		main::INFOLOG && $log->info("Ximalaya: track $trackId sync re-open from resolve cache (seek path)");
		$class->_apply_resolve($song, $url, $info);
		$cb->($song->currentTrack);
		return;
	}

	main::INFOLOG && $log->info("Ximalaya: resolving track $trackId");

	Plugins::Ximalaya::API->resolveTrack(
		$trackId,
		sub {
			my ($info) = @_;

			unless ($info && $info->{url}) {
				$log->error("Ximalaya: no playable URL for track $trackId");
				$cb->(undef);
				return;
			}

			main::INFOLOG && $log->info("Ximalaya: track $trackId => $info->{quality} stream");

			# 0.1.25: metadata publication + stream URL swap moved into
			# _apply_resolve (shared verbatim with the sync seek path).
			$class->_apply_resolve($song, $url, $info);

			$args->{cb} = sub {
				my ($track) = @_;
				if ($track) {
					$track->title($info->{title});
					# keep the playlist url stable (xmly://), not the expiring one
					$track->url($url);
				}
				$cb->($track, @_);
			};

			$class->SUPER::scanUrl($info->{url}, $args);
		},
		sub {
			my ($errcode) = @_;
			my %msg = (
				1001   => 'login required (ret=1001)',
				927    => 'no permission (ret=927)',
				3005   => 'no permission (ret=3005)',
				risk   => 'soft risk control',
				nourl  => 'no playable url in reply',
				noperm => 'not authorized for this track',
			);
			my $text = $msg{$errcode} // "resolve failed ($errcode)";
			$log->error("Ximalaya: track $trackId: $text");
			$cb->(undef);
		},
	);

	return;
}

# Use the resolved url for the actual streaming connection, avoid redirect loop
sub new {
	my ($class, $args) = @_;

	$args->{url} = $args->{song}->streamUrl unless $args->{redir};

	return $class->SUPER::new($args);
}

# resolve results keyed by the STABLE playlist url (xmly://...), consumed by
# getMetadataFor. Tiny in-process cache: one entry per track played this
# session, reset when it grows beyond a full album.
my %METADATA;

sub cache_metadata {
	my ($class, $url, $info) = @_;

	%METADATA = () if keys %METADATA > 200;

	my $kbps   = $info->{bitrate} ? int($info->{bitrate} / 1000) : 0;
	# same CBR membership table as Slim::Music::Info (32..320)
	my $suffix = ($kbps >= 32 && $kbps <= 320 && $kbps % 8 == 0) ? ' CBR' : '';
	# 0.1.30: quality now carries the real codec hint (API _suffix_quality) -
	# the ORIGIN tier streams .flac uploads at 1000+ kbps that were shown
	# as AAC before.
	my $q      = $info->{quality} || '';
	my $codec  = $q eq 'mp3' ? 'MP3' : $q eq 'flac' ? 'FLAC' : 'AAC';

	$METADATA{$url} = {
		title    => $info->{title},
		cover    => $info->{cover},
		duration => $info->{duration},
		bitrate  => $kbps ? "${kbps}kbps$suffix" : '',
		type     => $kbps ? "$codec ${kbps}kbps" : $codec,
	};

	return 1;
}

# Slim::Player::Protocols::HTTP::getMetadataFor delegates here when the
# handler implements it (see HTTP.pm): the returned hash becomes the track's
# remoteMeta verbatim - type carries the rate for Daphile's format display.
# 0.1.44: the status query calls this for EVERY queued xmly:// row (Slim::
# Control::Queries L5726-5733), and the result OVERRIDES the track row -
# including duration, which L5741 force-sets to remoteMeta->{d} = 0 when we
# returned the old empty hash. That {} is exactly why not-yet-played rows
# in the queue rendered blank. On a %METADATA miss (never resolved, or
# evicted / post-restart) rebuild what the enqueue-time and play-time
# publications left behind: TITLE/SECS committed to the track row and the
# cover in the remote_image_ cache (30 days - both survive restarts).
sub getMetadataFor {
	my ($class, $client, $url) = @_;

	if (my $m = $METADATA{$url}) {
		return {
			title    => $m->{title},
			type     => $m->{type},
			bitrate  => $m->{bitrate},
			duration => $m->{duration},
			cover    => $m->{cover},
		};
	}

	my $meta = {};

	if (my $track = Slim::Schema->objectForUrl({ url => $url })) {
		if (blessed($track)) {
			$meta->{title}    = $track->title     if $track->title;
			$meta->{duration} = $track->secs + 0  if $track->secs;
		}
	}

	my $cover = Slim::Utils::Cache->new->get("remote_image_$url");
	$meta->{cover} = $cover if defined $cover && $cover ne '';

	return scalar keys %$meta ? $meta : {};
}

# 0.1.44: enqueue-time metadata publication, called from explodePlaylist.
# albumTracksAll already carries title/duration/cover for every track, so
# publishing the whole list costs zero API calls. Slim::Music::Info::
# setRemoteMetadata commits TITLE/SECS into the track row (survives
# restarts) and stores the cover in the remote_image_ cache (30 days,
# Info.pm L484-489) - getMetadataFor's queue fallback reads both back for
# tracks that have not been resolved yet. No ct/bitrate here: the codec is
# only known at resolve time, and the play-time publication overwrites
# this entry with the full data anyway.
#
# 0.1.47: now ALSO called per rendered row (Plugin::trackItem) - see the
# long note there. The list data is already in hand in both callers, so
# the extra coverage still costs zero API calls; the return value is the
# number of URLs actually published (callers/tests can assert on it).
sub _publish_queue_metadata {
	my ($class, $tracks) = @_;

	my @published;

	for my $t (@$tracks) {
		next unless $t && $t->{id};

		my %meta;
		$meta{title} = $t->{title}
			if defined $t->{title} && $t->{title} ne '' && $t->{title} ne '?';
		$meta{secs}  = $t->{duration} if $t->{duration} && $t->{duration} > 0;
		$meta{cover} = $t->{cover}    if defined $t->{cover} && $t->{cover} ne '';

		next unless scalar keys %meta;

		Slim::Music::Info::setRemoteMetadata('xmly://' . $t->{id}, \%meta);
		push @published, 'xmly://' . $t->{id};
	}

	if (@published) {
		# One line per call (a rendered row = one call, an exploded album =
		# one call with the whole list): the ids are the diagnostic handle
		# for "which URLs can now render in the queue".
		$log->debug('Ximalaya: queue metadata published for ' . scalar(@published)
			. ' track(s): '
			. join(', ', @published[0 .. ($#published > 7 ? 7 : $#published)])
			. ($#published > 7 ? ', ...' : ''));
	}

	return scalar @published;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	$successCb->();
}

sub shouldCacheImage { 1 }

# shared post-resolve publication (0.1.25, split out of the async callback
# so the sync seek fast-path can reuse it verbatim): remote metadata for the
# now-playing pipeline + the stream URL swap.
sub _apply_resolve {
	my ($class, $song, $url, $info) = @_;

	# 0.1.20: feed the now-playing display. Radio streams show
	# bitrate because their servers send icy-br headers; Ximalaya
	# CDNs send none. setRemoteMetadata is LMS's official hook:
	# publishes title/duration/bitrate onto the track (bitrate in
	# kbps - the CBR table spans 32..320) and puts the cover into
	# the remote_image cache (30d) so every UI resolves artwork.
	# Supersedes 0.1.19's separate setBitrate/setDuration calls.
	if ($info->{cover} || $info->{bitrate} || $info->{duration}) {
		Slim::Music::Info::setRemoteMetadata($url, {
			title   => $info->{title},
			secs    => $info->{duration},
			bitrate => $info->{bitrate} ? int($info->{bitrate} / 1000) : undef,
			cover   => $info->{cover},
			ct      => ($info->{quality} || '') eq 'mp3' ? 'audio/mpeg'
				 : ($info->{quality} || '') eq 'flac' ? 'audio/flac' : 'audio/mp4',
		});
	}

	# 0.1.20/0.1.21: cache the resolve result for getMetadataFor -
	# that hook fully replaces the base class remoteMeta, and Daphile
	# renders the codec string from remoteMeta.type (NOT the bitrate
	# field), so the only way to get a rate on screen is to embed it
	# in the type text ("AAC 96kbps CBR").
	$class->cache_metadata($url, $info);

	# the resolved url is what actually gets streamed
	$song->streamUrl($info->{url});

	return;
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::ProtocolHandler - xmly:// scheme handler

=cut
