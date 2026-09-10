# Plugins::Ximalaya::XimaCrypt
#
# Pure-perl crypto for the Ximalaya plugin (no XS dependencies):
#  - AES-128-ECB encrypt/decrypt (PKCS#7 padding), FIPS-197 self-test at load
#  - Ximalaya playUrlList decryption (URL-safe base64 -> S-box -> XOR chains)
#
# Ported from the M0-verified implementation (see _research/ximalaya-daphile-plugin/m0/):
#  - AES used for the xm-sign device-fingerprint report (hdaa.shuzilm.cn)
#  - decrypt_url ported from Diaoxiaozhang/Ximalaya-Downloader main.py
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::XimaCrypt;

use strict;
use warnings;
use MIME::Base64 qw(decode_base64);

# ------------------------------------------------------------------ GF(2^8)
my @GF_EXP;
my @GF_LOG;
{
	@GF_EXP = (0) x 256;
	@GF_LOG = (0) x 256;
	my $x = 1;
	for my $i (0 .. 254) {
		$GF_EXP[$i] = $x;
		$GF_LOG[$x] = $i;
		# multiply by generator 3: g = 2 * g ^ g
		$x = ($x ^ (($x << 1) ^ ($x & 0x80 ? 0x11B : 0))) & 0xFF;
	}
}

sub _gf_mul {
	my ($a, $b) = @_;
	return 0 if $a == 0 || $b == 0;
	return $GF_EXP[($GF_LOG[$a] + $GF_LOG[$b]) % 255];
}

sub _gf_inv {
	my ($a) = @_;
	return 0 if $a == 0;
	return $GF_EXP[(255 - $GF_LOG[$a]) % 255];
}

sub _xtime {
	my ($b) = @_;
	return (($b << 1) ^ ($b & 0x80 ? 0x11B : 0)) & 0xFF;
}

sub _rotl8 {
	my ($b, $n) = @_;
	return ((($b << $n) | ($b >> (8 - $n))) & 0xFF);
}

# ------------------------------------------------------- AES S-box (FIPS-197)
my @AES_SBOX;
my @AES_INV;
{
	@AES_SBOX = (0) x 256;
	@AES_INV = (0) x 256;
	for my $i (0 .. 255) {
		my $b = _gf_inv($i);
		my $s = $b ^ _rotl8($b, 1) ^ _rotl8($b, 2) ^ _rotl8($b, 3) ^ _rotl8($b, 4) ^ 0x63;
		$AES_SBOX[$i] = $s;
		$AES_INV[$s] = $i;
	}
}

# ---------------------------------------------------------------- key schedule
sub _expand_key {
	my ($key) = @_;
	die __PACKAGE__ . ": AES-128 key must be 16 bytes\n" unless length($key) == 16;

	my @w = map { [ unpack('C4', substr($key, $_ * 4, 4)) ] } (0 .. 3);
	my $rcon = 1;

	for my $i (4 .. 43) {
		my @t = @{ $w[$i - 1] };
		if ($i % 4 == 0) {
			# RotWord + SubWord + Rcon
			@t = ($AES_SBOX[$t[1]] ^ $rcon, $AES_SBOX[$t[2]], $AES_SBOX[$t[3]], $AES_SBOX[$t[0]]);
			$rcon = _xtime($rcon);
		}
		$w[$i] = [ map { $w[$i - 4][$_] ^ $t[$_] } (0 .. 3) ];
	}

	return \@w;
}

sub _add_round_key {
	my ($s, $w, $round) = @_;
	for my $j (0 .. 3) {
		my $word = $w->[4 * $round + $j];
		$s->[4 * $j]     ^= $word->[0];
		$s->[4 * $j + 1] ^= $word->[1];
		$s->[4 * $j + 2] ^= $word->[2];
		$s->[4 * $j + 3] ^= $word->[3];
	}
}

sub _sub_shift_rows {
	my ($s) = @_;
	for (0 .. 15) {
		$s->[$_] = $AES_SBOX[$s->[$_]];
	}
	for my $r (1 .. 3) {
		my @row = @{$s}[$r, $r + 4, $r + 8, $r + 12];
		for my $c (0 .. 3) {
			$s->[$r + 4 * $c] = $row[($c + $r) % 4];
		}
	}
}

sub _inv_shift_rows_sub {
	my ($s) = @_;
	for my $r (1 .. 3) {
		my @row = @{$s}[$r, $r + 4, $r + 8, $r + 12];
		for my $c (0 .. 3) {
			$s->[$r + 4 * $c] = $row[($c - $r) % 4];
		}
	}
	for (0 .. 15) {
		$s->[$_] = $AES_INV[$s->[$_]];
	}
}

sub _mix_columns {
	my ($s) = @_;
	for my $c (0 .. 3) {
		my $i = 4 * $c;
		my ($a0, $a1, $a2, $a3) = @{$s}[$i .. $i + 3];
		$s->[$i]     = _xtime($a0) ^ (_xtime($a1) ^ $a1) ^ $a2 ^ $a3;
		$s->[$i + 1] = $a0 ^ _xtime($a1) ^ (_xtime($a2) ^ $a2) ^ $a3;
		$s->[$i + 2] = $a0 ^ $a1 ^ _xtime($a2) ^ (_xtime($a3) ^ $a3);
		$s->[$i + 3] = (_xtime($a0) ^ $a0) ^ $a1 ^ $a2 ^ _xtime($a3);
	}
}

sub _inv_mix_columns {
	my ($s) = @_;
	for my $c (0 .. 3) {
		my $i = 4 * $c;
		my ($a0, $a1, $a2, $a3) = @{$s}[$i .. $i + 3];
		$s->[$i]     = _gf_mul($a0, 14) ^ _gf_mul($a1, 11) ^ _gf_mul($a2, 13) ^ _gf_mul($a3, 9);
		$s->[$i + 1] = _gf_mul($a0, 9)  ^ _gf_mul($a1, 14) ^ _gf_mul($a2, 11) ^ _gf_mul($a3, 13);
		$s->[$i + 2] = _gf_mul($a0, 13) ^ _gf_mul($a1, 9)  ^ _gf_mul($a2, 14) ^ _gf_mul($a3, 11);
		$s->[$i + 3] = _gf_mul($a0, 11) ^ _gf_mul($a1, 13) ^ _gf_mul($a2, 9)  ^ _gf_mul($a3, 14);
	}
}

sub _encrypt_block {
	my ($w, $in) = @_;
	my @s = unpack('C16', $in);

	_add_round_key(\@s, $w, 0);
	for my $round (1 .. 9) {
		_sub_shift_rows(\@s);
		_mix_columns(\@s);
		_add_round_key(\@s, $w, $round);
	}
	_sub_shift_rows(\@s);
	_add_round_key(\@s, $w, 10);

	return pack('C16', @s);
}

sub _decrypt_block {
	my ($w, $in) = @_;
	my @s = unpack('C16', $in);

	_add_round_key(\@s, $w, 10);
	for my $round (reverse 1 .. 9) {
		_inv_shift_rows_sub(\@s);
		_add_round_key(\@s, $w, $round);
		_inv_mix_columns(\@s);
	}
	_inv_shift_rows_sub(\@s);
	_add_round_key(\@s, $w, 0);

	return pack('C16', @s);
}

# ------------------------------------------------------------- padding (PKCS#7)
sub _pkcs7_pad {
	my ($data) = @_;
	my $pad = 16 - length($data) % 16;
	return $data . chr($pad) x $pad;
}

sub _pkcs7_unpad {
	my ($data) = @_;
	return $data unless length($data) && length($data) % 16 == 0;
	my $pad = ord(substr($data, -1));
	return $data if $pad < 1 || $pad > 16;
	return substr($data, 0, length($data) - $pad);
}

# ------------------------------------------------------------------ public API
# $class->aes_ecb_encrypt($key, $plaintext)  - PKCS#7 padded
sub aes_ecb_encrypt {
	my ($class, $key, $data) = @_;
	my $w = _expand_key($key);
	$data = _pkcs7_pad($data);
	my $out = '';
	for (my $i = 0; $i < length($data); $i += 16) {
		$out .= _encrypt_block($w, substr($data, $i, 16));
	}
	return $out;
}

# $class->aes_ecb_decrypt($key, $ciphertext, $unpad) - $unpad: strip PKCS#7
sub aes_ecb_decrypt {
	my ($class, $key, $data, $unpad) = @_;
	die __PACKAGE__ . ": ciphertext not a multiple of 16\n" if length($data) % 16;
	my $w = _expand_key($key);
	my $out = '';
	for (my $i = 0; $i < length($data); $i += 16) {
		$out .= _decrypt_block($w, substr($data, $i, 16));
	}
	return $unpad ? _pkcs7_unpad($out) : $out;
}

# ------------------------------------------------- Ximalaya playUrlList decrypt
# Constants ported 1:1 from the M0-verified python implementation
# (Diaoxiaozhang/Ximalaya-Downloader main.py decrypt_url)
my @XMC_SBOX = (
    183, 174, 108, 16, 131, 159, 250, 5, 239, 110, 193, 202,
    153, 137, 251, 176, 119, 150, 47, 204, 97, 237, 1, 71,
    177, 42, 88, 218, 166, 82, 87, 94, 14, 195, 69, 127,
    215, 240, 225, 197, 238, 142, 123, 44, 219, 50, 190, 29,
    181, 186, 169, 98, 139, 185, 152, 13, 141, 76, 6, 157,
    200, 132, 182, 49, 20, 116, 136, 43, 155, 194, 101, 231,
    162, 242, 151, 213, 53, 60, 26, 134, 211, 56, 28, 223,
    107, 161, 199, 15, 229, 61, 96, 41, 66, 158, 254, 21,
    165, 253, 103, 89, 3, 168, 40, 246, 81, 95, 58, 31,
    172, 78, 99, 45, 148, 187, 222, 124, 55, 203, 235, 64,
    68, 149, 180, 35, 113, 207, 118, 111, 91, 38, 247, 214,
    7, 212, 209, 189, 241, 18, 115, 173, 25, 236, 121, 249,
    75, 57, 216, 10, 175, 112, 234, 164, 70, 206, 198, 255,
    140, 230, 12, 32, 83, 46, 245, 0, 62, 227, 72, 191,
    156, 138, 248, 114, 220, 90, 84, 170, 128, 19, 24, 122,
    146, 80, 39, 37, 8, 34, 22, 11, 93, 130, 63, 154,
    244, 160, 144, 79, 23, 133, 92, 54, 102, 210, 65, 67,
    27, 196, 201, 106, 143, 52, 74, 100, 217, 179, 48, 233,
    126, 117, 184, 226, 85, 171, 167, 86, 2, 147, 17, 135,
    228, 252, 105, 30, 192, 129, 178, 120, 36, 145, 51, 163,
    77, 205, 73, 4, 188, 125, 232, 33, 243, 109, 224, 104,
    208, 221, 59, 9,
);
my @XMC_MASK32 = (
    204, 53, 135, 197, 39, 73, 58, 160, 79, 24, 12, 83, 180, 250, 101, 60,
    206, 30, 10, 227, 36, 95, 161, 16, 135, 150, 235, 116, 242, 116, 165, 171,
);

# $class->decrypt_url($encrypted_url) -> $plain_url (or input if not encrypted)
sub decrypt_url {
	my ($class, $encrypted_url) = @_;
	return $encrypted_url unless defined $encrypted_url && length $encrypted_url;

	# URL-safe base64: '_'->'/', '-'->'+', then standard padding
	(my $b64 = $encrypted_url) =~ s/_/\//g;
	$b64 =~ s/-/+/g;
	$b64 .= '=' x ((4 - length($b64) % 4) % 4);

	my $data = decode_base64($b64);
	return $encrypted_url if length($data) < 16;

	my $body = substr($data, 0, length($data) - 16);
	my $iv   = substr($data, -16);

	my @out = map { $XMC_SBOX[$_] } unpack('C*', $body);
	my @ivb = unpack('C*', $iv);

	for (my $i = 0; $i < @out; $i += 16) {
		my $n = @out - $i;
		$n = 16 if $n > 16;
		$out[$i + $_] ^= $ivb[$_] for (0 .. $n - 1);
	}
	for (my $i = 0; $i < @out; $i += 32) {
		my $n = @out - $i;
		$n = 32 if $n > 32;
		$out[$i + $_] ^= $XMC_MASK32[$_] for (0 .. $n - 1);
	}

	# URLs are pure ASCII; returning raw bytes is correct
	return pack('C*', @out);
}

# ------------------------------------------------- PC client (device=win) decrypt
# The desktop client 4.0.14 encrypts baseInfo playUrlList differently from
# the web feed: URL-safe base64 -> AES-128-ECB (PKCS#7), key extracted from
# the client asar (Gt function). Plaintexts are audiopay.cos.tx.xmcdn.com
# download URLs (signed, directly GET-able). Verified against a real
# 2026-08-16 device=win capture (t/fixtures_pc.json winvector).
use constant WIN_PLAY_URL_KEY => pack('H*', 'aaad3e4fd540b0f79dca95606e72bf93');

# $class->decrypt_url_win($encrypted_url) -> $plain_url
#   returns undef on any decrypt failure (caller falls back); plain http(s)
#   input passes through untouched (same convention as the reference tools).
sub decrypt_url_win {
	my ($class, $encrypted_url) = @_;
	return undef unless defined $encrypted_url && length $encrypted_url;
	return $encrypted_url if $encrypted_url =~ m{^https?://}i;

	# URL-safe base64: '_'->'/', '-'->'+', then standard padding
	(my $b64 = $encrypted_url) =~ s/_/\//g;
	$b64 =~ s/-/+/g;
	$b64 .= '=' x ((4 - length($b64) % 4) % 4);

	my $data = decode_base64($b64);
	return undef if !length($data) || length($data) % 16;

	my $plain = eval { $class->aes_ecb_decrypt(WIN_PLAY_URL_KEY, $data, 1) };
	return undef if $@ || !defined $plain;
	return undef unless $plain =~ m{^https?://}i;    # garbage -> no URL
	return $plain;
}

# -------------------------------------------------------------------- self-test
# FIPS-197 Appendix C.1 known-answer test; runs once at load so a broken build
# fails loudly instead of producing garbage signatures on the device.
my $SELFTEST = eval {
	my $key = pack('H*', '000102030405060708090a0b0c0d0e0f');
	my $pt  = pack('H*', '00112233445566778899aabbccddeeff');
	# encrypt_block without padding: PKCS#7 of a full block prepends a second
	# block, so the first 16 bytes of the ciphertext are the raw KAT cipher.
	my $ct = substr(__PACKAGE__->aes_ecb_encrypt($key, $pt), 0, 16);
	die "KAT mismatch\n" unless lc unpack('H*', $ct) eq '69c4e0d86a7b0430d8cdb78070b4c55a';
	my $rt = __PACKAGE__->aes_ecb_decrypt($key, $pt, 0);
	$rt = __PACKAGE__->aes_ecb_decrypt($key, __PACKAGE__->aes_ecb_encrypt($key, $pt), 1);
	die "roundtrip mismatch\n" unless $rt eq $pt;
	1;
};

sub selftest_ok { return $SELFTEST; }

1;

__END__

=head1 NAME

Plugins::Ximalaya::XimaCrypt - pure-perl AES-128-ECB + Ximalaya URL decryption

=head1 SYNOPSIS

  my $ct = Plugins::Ximalaya::XimaCrypt->aes_ecb_encrypt($key, $data);
  my $pt = Plugins::Ximalaya::XimaCrypt->aes_ecb_decrypt($key, $ct, 1);
  my $url = Plugins::Ximalaya::XimaCrypt->decrypt_url($encrypted);

=head1 SEE ALSO

M0 verification: _research/ximalaya-daphile-plugin/m0/m0_verify.py

=cut
