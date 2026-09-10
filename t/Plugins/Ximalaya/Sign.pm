# Plugins::Ximalaya::Sign
#
# xm-sign generation for the Ximalaya web backend.
#
# Algorithm (M0-verified, ported from Ximalaya-Downloader-Next py_sign.py /
# liuziheng20091106 easy-sign):
#   device_info (device_info.json template, Zf5 refreshed to current ms)
#   -> JSON (compact, UTF-8 bytes)
#   -> zlib stream (stored deflate blocks, pure-Perl - see _zlib_store)
#   -> AES-128-ECB encrypt, PKCS#7 (key: du_web_sdk _getDeviceKey(0))
#   -> POST https://hdaa.shuzilm.cn/report?v=1.2.0&e=1&c=1&r=<uuid>
#   -> response: base64 -> AES-ECB decrypt -> JSON { cadd, sid }
#   -> xm-sign = "cadd&&sid"
#
# NOTE: xm-sign is a short-lived / single-use token (reuse triggers "webtk
# expired"). Generate a FRESH sign for every API request.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::Sign;

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use File::Basename qw(dirname);
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use Plugins::Ximalaya::XimaCrypt;

my $log = logger('plugin.ximalaya');

use constant SIGN_KEY => 'm9ZtRrz:qujT8@da';    # du_web_sdk _getDeviceKey(0)
use constant HDAA_URL => 'https://hdaa.shuzilm.cn/report?v=1.2.0&e=1&c=1&r=';
use constant UA       => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

# Device fingerprint template shipped with the plugin (device_info.json).
# Must contain the literal placeholder "Zf5":0 which is replaced per request.
my $DEVICE_JSON = do {
	my $file = dirname(__FILE__) . '/device_info.json';
	local $/;
	open my $fh, '<:raw', $file or die __PACKAGE__ . ": cannot read $file: $!\n";
	<$fh>;
};
chomp $DEVICE_JSON;
die __PACKAGE__ . ": device_info.json missing Zf5 placeholder\n"
	unless $DEVICE_JSON =~ /"Zf5":0/;

# ------------------------------------------------------------------ helpers

# Pure-Perl adler-32 (RFC 1950). Compress::Zlib is NOT used on purpose:
# Daphile's system perl ships a broken IO::Compress mix (2.015/2.212) which
# makes `use Compress::Zlib` a compile-time abort, so the payload is wrapped
# as a valid zlib stream using stored (uncompressed) deflate blocks instead.
# The server-side inflate does not care that the data is uncompressed.
sub _adler32 {
	my ($data) = @_;
	my $a = 1;
	my $b = 0;
	for my $i (0 .. length($data) - 1) {
		$a = ($a + ord(substr($data, $i, 1))) % 65521;
		$b = ($b + $a) % 65521;
	}
	return (($b << 16) | $a) & 0xFFFFFFFF;
}

# Pure-Perl zlib stream with stored deflate blocks (RFC 1950 + 1951).
sub _zlib_store {
	my ($data) = @_;

	# zlib header: CM=8 (deflate), CINFO=7 (32K), FLEVEL=0, FDICT=0.
	# 0x78 0x01: (0x78 << 8 | 0x01) % 31 == 0 -> FCHECK valid.
	my $out = "\x78\x01";

	my $off = 0;
	my $len = length($data);
	while ($off < $len || $len == 0) {
		my $chunk = substr($data, $off, 65535);
		my $clen  = length($chunk);
		my $final = ($off + $clen >= $len) ? 1 : 0;

		# stored block header byte: BFINAL bit, BTYPE=00, padded to byte edge
		$out .= chr($final);
		$out .= pack('vv', $clen, $clen ^ 0xFFFF);
		$out .= $chunk;

		$off += $clen;
		last if $final;
	}

	$out .= pack('N', _adler32($data));
	return $out;
}

sub _uuid {
	my @hex = map { int(rand(16)) } (1 .. 31);
	return sprintf(
		'%s%s%s%s%s%s%s%s-%s%s%s%s-4%s%s%s-%s%s%s%s-%s%s%s%s%s%s%s%s%s%s%s%s',
		map { sprintf('%x', $hex[$_-1]) } 1 .. 31
	);
}

# ------------------------------------------------------------------ public

# $class->gen( cb, ecb )
#   cb->($xm_sign)               on success
#   ecb->($error)                on failure
sub gen {
	my ($class, $cb, $ecb) = @_;

	unless (Plugins::Ximalaya::XimaCrypt->selftest_ok) {
		$ecb->('XimaCrypt AES self-test failed at load - plugin build is broken');
		return;
	}

	my $ts = int(time() * 1000);
	(my $json = $DEVICE_JSON) =~ s/"Zf5":0/"Zf5":$ts/;

	my $payload = _zlib_store(encode_utf8($json));
	my $body    = Plugins::Ximalaya::XimaCrypt->aes_ecb_encrypt(SIGN_KEY, $payload);
	my $url     = HDAA_URL . _uuid();

	main::INFOLOG && $log->info('requesting xm-sign from hdaa');

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($http) = @_;
			my $resp = eval {
				my $raw = decode_base64($http->content);
				from_json(Plugins::Ximalaya::XimaCrypt->aes_ecb_decrypt(SIGN_KEY, $raw, 1));
			};
			if ($@ || !$resp) {
				my $err = "hdaa response parse failed: " . ($@ || 'empty');
				$log->error($err);
				$ecb->($err);
				return;
			}
			my ($cadd, $sid) = ($resp->{cadd} // '', $resp->{sid} // '');
			unless ($cadd && $sid) {
				my $err = "hdaa response missing cadd/sid";
				$log->error($err);
				$ecb->($err);
				return;
			}
			main::INFOLOG && $log->info('got xm-sign');
			$cb->("$cadd&&$sid");
		},
		sub {
			my ($http, $error) = @_;
			$log->error("hdaa report failed: $error");
			$ecb->("hdaa report failed: $error");
		},
		{ timeout => 15 },
	);

	$http->post(
		$url,
		'Content-Type' => 'application/octet-stream',
		'User-Agent'   => UA,
		'Referer'      => 'https://www.ximalaya.com/',
		$body
	);

	return;
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::Sign - async xm-sign generator (hdaa device report)

=head1 SYNOPSIS

  Plugins::Ximalaya::Sign->gen(
      sub { my ($sign) = @_; ... },      # "cadd&&sid"
      sub { my ($error) = @_; ... },
  );

=cut
