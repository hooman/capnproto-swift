@0x9eb32e19f86f3a01;
struct Example {
  voidField @0 :Void;
  boolField @1 :Bool = true;
  i8 @2 :Int8 = -12;
  i16 @3 :Int16 = -1234;
  i32 @4 :Int32 = -123456;
  i64 @5 :Int64 = -1234567890123;
  u8 @6 :UInt8 = 250;
  u16 @7 :UInt16 = 65000;
  u32 @8 :UInt32 = 4000000000;
  u64 @9 :UInt64 = 18000000000000000000;
  f32 @10 :Float32 = 1.5;
  f64 @11 :Float64 = -2.25;
  text @12 :Text;
  data @13 :Data;
  child @14 :Child;
  children @15 :List(Child);
  bits @16 :List(Bool);
  numbers @17 :List(UInt32);
  texts @18 :List(Text);
  blobs @19 :List(Data);
  matrix @20 :List(List(UInt16));
  voids @21 :List(Void);
  union {
    idle @22 :Void;
    value @23 :UInt32 = 77;
    detail :group {
      label @24 :Text;
      amount @25 :UInt64;
    }
  }
  struct Child {
    id @0 :UInt64 = 9;
    name @1 :Text;
  }
}
struct Old { value @0 :UInt16; values @1 :List(UInt16); }
struct New {
  value @0 :UInt16;
  values @1 :List(Item);
  added @2 :UInt64 = 123;
  text @3 :Text;
  struct Item { value @0 :UInt16; extra @1 :UInt64 = 456; }
}
