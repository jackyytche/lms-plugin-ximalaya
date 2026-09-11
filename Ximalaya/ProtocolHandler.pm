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

use Plugins::Ximalaya::API;

my $log = logger('plugin.ximalaya');

Slim::Player::ProtocolHandlers->registerHandler('xmly', __PACKAGE__);

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
	my $codec  = ($info->{quality} || '') eq 'mp3' ? 'MP3' : 'AAC';

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
sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my $m = $METADATA{$url} or return {};

	return {
		title    => $m->{title},
		type     => $m->{type},
		bitrate  => $m->{bitrate},
		duration => $m->{duration},
		cover    => $m->{cover},
	};
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
			ct      => $info->{quality} eq 'mp3' ? 'audio/mpeg' : 'audio/mp4',
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
