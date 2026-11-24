# Enums (D-17 item 2): top-level, nested, imported and out-of-order declarations; fields with
# and without defaults, in unions and groups; lists and lists of lists. enums-newer.capnp is
# a newer twin used to encode ordinals this schema does not know.
@0xe0e5000000000001;

using Imp = import "enums-import.capnp";

enum Color @0xe0e5000000000011 {
  # A color.
  red @0;  # The first color.
  green @1;
  blue @2;
}

# Declared out of ordinal order: the generated cases follow the ordinals.
enum Shuffled @0xe0e5000000000012 {
  blue @2;
  red @0;
  green @1;
}

struct Palette @0xe0e5000000000021 {
  primary @0 :Color;  # No default: red.
  accent @1 :Color = blue;
  colors @2 :List(Color);
  grid @3 :List(List(Color));
  level @4 :Imp.Level;
  mood @5 :Mood;
  choice :union {
    none @6 :Void;
    shade @7 :Color = green;
  }
  extra :group {
    tone @8 :Mood = happy;
  }
  shuffled @9 :Shuffled;

  enum Mood @0xe0e5000000000022 {
    sad @0;
    happy @1;
  }
}
