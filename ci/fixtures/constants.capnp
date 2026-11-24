@0xc0c5000000000001;
# Scalar and enum constants (D-17 item 3). IDs are explicit so the golden's ID order is fixed.

using L = import "enums-import.capnp";

const answer @0xc0c5000000000010 :Int32 = 42;  # The answer.
const minInt64 @0xc0c5000000000011 :Int64 = -9223372036854775808;
const maxUInt64 @0xc0c5000000000012 :UInt64 = 18446744073709551615;
const minInt8 @0xc0c5000000000013 :Int8 = -128;
const minInt16 @0xc0c5000000000014 :Int16 = -32768;
const maxUInt8 @0xc0c5000000000015 :UInt8 = 255;
const maxUInt16 @0xc0c5000000000016 :UInt16 = 65535;
const maxUInt32 @0xc0c5000000000017 :UInt32 = 4294967295;
const yes @0xc0c5000000000018 :Bool = true;
const no @0xc0c5000000000019 :Bool = false;
const nothing @0xc0c500000000001a :Void = void;
const notANumber @0xc0c500000000001b :Float32 = nan;
const negativeInfinity @0xc0c500000000001c :Float64 = -inf;
const negativeZero @0xc0c500000000001d :Float64 = -0.0;
const subnormal @0xc0c500000000001e :Float32 = 1.0e-45;
const large @0xc0c500000000001f :Float32 = 4e30;
const third @0xc0c5000000000020 :Float64 = 0.3333333333333333;
const level @0xc0c5000000000021 :L.Level = high;  # An imported enum.
const color @0xc0c5000000000022 :Color = blue;

enum Color @0xc0c5000000000030 {
  red @0;
  green @1;
  blue @2;
}

struct Limits @0xc0c5000000000040 {
  # Constants nested in a struct with fields and a union.
  const floor @0xc0c5000000000041 :Int16 = -7;
  const shade @0xc0c5000000000042 :Color = green;  # Nested enum constant.
  value @0 :Int16;
  union {
    none @1 :Void;
    count @2 :UInt8;
  }
  struct Inner @0xc0c5000000000043 {
    const depth @0xc0c5000000000044 :UInt8 = 3;
  }
}

# The oracle carries every scalar constant as a field, so `capnp eval -b` gives their C++
# encodings for a bit-exact comparison (constants-oracle.capnp sets the values).
struct Oracle @0xc0c5000000000050 {
  answer @0 :Int32;
  minInt64 @1 :Int64;
  maxUInt64 @2 :UInt64;
  minInt8 @3 :Int8;
  minInt16 @4 :Int16;
  maxUInt8 @5 :UInt8;
  maxUInt16 @6 :UInt16;
  maxUInt32 @7 :UInt32;
  yes @8 :Bool;
  no @9 :Bool;
  notANumber @10 :Float32;
  negativeInfinity @11 :Float64;
  negativeZero @12 :Float64;
  subnormal @13 :Float32;
  large @14 :Float32;
  third @15 :Float64;
  floor @16 :Int16;
  depth @17 :UInt8;
}
