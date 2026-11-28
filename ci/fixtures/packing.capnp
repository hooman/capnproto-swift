# Edge cases for Packed.pack, encoded live by `capnp encode --packed` in check-readers.py: a zero
# run past 256 words, an all-nonzero run past 255 words, a literal run ended by a word with two
# zero bytes, and (encoded with --segment-size) runs that meet segment boundaries.
@0xd0a1c2b3e4f50617;

struct Packing {
  zeros @0 :List(UInt64);
  literal @1 :Data;
  mixed @2 :List(UInt64);
  tail @3 :UInt64;
}
