/// Content addresses: names made by hashing bytes with sha256, as types.
///
/// Three kinds, one family: an [ObjectId] names stored bytes, an [EntryHash]
/// names one entry of a record, and a [DriverHash] names a record driver's
/// own code. Each is made only here: by `of`, from the bytes it hashes, or
/// where a name is read back, by `parse` from hex or `fromDigest` from its
/// 32 bytes. So code holding one never asks whether it is well formed.
/// Classes, not extension types, since a `String` can be cast to an extension
/// type and skip all three.
///
/// The sha256 is here too, so the hash every name is made with is part of
/// the code the driver's own hash covers. This library imports only
/// `dart:typed_data` and touches no file, so it can be used where `dart:io`
/// cannot.
library;

import 'dart:typed_data';

final _hex = RegExp(r'^[0-9a-f]{64}$');
const _hexDigits = '0123456789abcdef';

Uint8List? _fromHex(String s) => _hex.hasMatch(s)
    ? Uint8List.fromList([
        for (var i = 0; i < 64; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16),
      ])
    : null;

Uint8List? _fromDigest(Uint8List digest) =>
    digest.length == 32 ? Uint8List.fromList(digest) : null;

/// A sha256: 32 bytes, written in text as lower-case hex.
sealed class _Digest {
  _Digest(this._bytes);
  final Uint8List _bytes;

  /// The 32 bytes.
  Uint8List get bytes => _bytes.asUnmodifiableView();

  /// The bytes in lower-case hex: how the name is written in text.
  late final String hex = String.fromCharCodes([
    for (final b in _bytes) ...[
      _hexDigits.codeUnitAt(b >> 4),
      _hexDigits.codeUnitAt(b & 0xf),
    ],
  ]);

  @override
  bool operator ==(Object other) {
    if (other is! _Digest || other.runtimeType != runtimeType) return false;
    for (var i = 0; i < 32; i++) {
      if (other._bytes[i] != _bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_bytes);

  @override
  String toString() => hex;
}

/// An object's name: the sha256 of its bytes.
final class ObjectId extends _Digest {
  ObjectId._(super._bytes);

  /// The id [bytes] are stored under.
  factory ObjectId.of(Uint8List bytes) => ObjectId._(_sha256(bytes));

  /// [s] as an id, read back from text; null unless it is a sha256 in
  /// lower-case hex.
  static ObjectId? parse(String s) => switch (_fromHex(s)) {
    final b? => ObjectId._(b),
    null => null,
  };

  /// [digest] as an id, read back from bytes; null unless it is 32 bytes.
  static ObjectId? fromDigest(Uint8List digest) =>
      switch (_fromDigest(digest)) {
        final b? => ObjectId._(b),
        null => null,
      };
}

/// The sha256 of one record entry.
final class EntryHash extends _Digest {
  EntryHash._(super._bytes);

  /// [entry]'s hash.
  factory EntryHash.of(Uint8List entry) => EntryHash._(_sha256(entry));

  static EntryHash? parse(String s) => switch (_fromHex(s)) {
    final b? => EntryHash._(b),
    null => null,
  };

  static EntryHash? fromDigest(Uint8List digest) =>
      switch (_fromDigest(digest)) {
        final b? => EntryHash._(b),
        null => null,
      };

  /// What the first entry names as the entry before it: the sha256 of the
  /// record format's name, so a record in another format breaks at its first
  /// entry, and anyone can compute it with
  /// `printf 'is_airlock_record_driver/1' | shasum -a 256`.
  static final origin = EntryHash.of(
    Uint8List.fromList('is_airlock_record_driver/1'.codeUnits),
  );
}

/// The sha256 of a record driver's own code: of the listing `shasum -a 256`
/// prints for its `lib/` files.
final class DriverHash extends _Digest {
  DriverHash._(super._bytes);

  /// The hash of [listing].
  factory DriverHash.of(Uint8List listing) => DriverHash._(_sha256(listing));

  static DriverHash? parse(String s) => switch (_fromHex(s)) {
    final b? => DriverHash._(b),
    null => null,
  };

  static DriverHash? fromDigest(Uint8List digest) =>
      switch (_fromDigest(digest)) {
        final b? => DriverHash._(b),
        null => null,
      };
}

/// The sha256 of [message], as FIPS 180-4 defines it. Words live in
/// `Uint32List`s, which keep only the low 32 bits of what is stored; the
/// working variables are masked by hand.
Uint8List _sha256(Uint8List message) {
  final length = message.length;
  // The message, a 1 bit, zeros to 8 bytes short of a whole block, then the
  // message's length in bits as a 64-bit big-endian number.
  final padded = Uint8List((length + 8) ~/ 64 * 64 + 64)
    ..setRange(0, length, message)
    ..[length] = 0x80;
  final bits = length * 8;
  final view = ByteData.sublistView(padded)
    ..setUint32(padded.length - 8, bits ~/ 0x100000000)
    ..setUint32(padded.length - 4, bits % 0x100000000);

  final state = Uint32List.fromList(_initial);
  final w = Uint32List(64);
  for (var block = 0; block < padded.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = view.getUint32(block + 4 * t);
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15], y = w[t - 2];
      w[t] =
          w[t - 16] +
          (_rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3)) +
          w[t - 7] +
          (_rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10));
    }
    var [a, b, c, d, e, f, g, h] = state;
    for (var t = 0; t < 64; t++) {
      final t1 =
          (h +
              (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) +
              ((e & f) ^ ((e ^ _mask) & g)) +
              _k[t] +
              w[t]) &
          _mask;
      final t2 =
          ((_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) +
              ((a & b) ^ (a & c) ^ (b & c))) &
          _mask;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
  }
  final digest = Uint8List(32);
  final out = ByteData.sublistView(digest);
  for (var i = 0; i < 8; i++) {
    out.setUint32(4 * i, state[i]);
  }
  return digest;
}

const _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// The first 32 bits of the fractional parts of the square roots of the
/// first 8 primes.
const _initial = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

/// The first 32 bits of the fractional parts of the cube roots of the first
/// 64 primes.
const _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
