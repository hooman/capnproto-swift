# Newer twin of enums.capnp, used only to encode oracle messages: Color gains violet @3 and
# Palette.Mood gains ecstatic @2, so the older readers see ordinals they do not know.
@0xe0e5000000000003;

using Imp = import "enums-import.capnp";

enum Color @0xe0e5000000000011 {
  # A color.
  red @0;  # The first color.
  green @1;
  blue @2;
  violet @3;
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
    ecstatic @2;
  }
}
