@0xb0b1d0e2c3a4f501;
# Generated builders (D-18 item 2): every scalar type, non-zero defaults (true, -0.0, NaN, a
# non-zero enum), a nested recursive struct, a non-union group, an unnamed union with void,
# scalar, struct and group members, and a named union. No text, data or list fields: their
# builders arrive with item 3.

enum Level { low @0; mid @1; high @2; }

struct Root {
  flag @0 :Bool = true;
  i8 @1 :Int8 = -3;
  i16 @2 :Int16;
  i32 @3 :Int32 = 70000;
  i64 @4 :Int64;
  u8 @5 :UInt8;
  u16 @6 :UInt16 = 7;
  u32 @7 :UInt32;
  u64 @8 :UInt64 = 18000000000000000000;
  f32 @9 :Float32 = -0.0;
  f64 @10 :Float64 = nan;
  level @11 :Level = mid;
  child @12 :Child;
  info :group {
    age @13 :UInt16 = 18;
    known @14 :Bool;
  }
  union {
    none @15 :Void;
    count @16 :UInt32 = 5;
    pick @17 :Child;
    pair :group {
      left @18 :Int16;
      right @19 :Int16 = -1;
    }
  }
  extra :union {
    a @20 :UInt8;
    b @21 :UInt64;
  }
  struct Child {
    id @0 :UInt64 = 9;
    level @1 :Level;
    inner @2 :Child;
  }
}

# Field names that are Swift keywords become backquoted methods.
struct Keywords {
  init @0 :UInt8;
  self @1 :UInt8;
  default @2 :UInt8;
  type @3 :UInt8;
}

# Struct names whose builders are named like runtime types: generated code qualifies
# `CapnpRuntime.`, so these shadow nothing.
struct Message { x @0 :UInt8; }
struct Struct { y @0 :UInt8; }
