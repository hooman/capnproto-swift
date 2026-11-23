# Header comment above the file ID: capnp drops it, so it never reaches the output.
@0xd0c5000000000001;
# File doc: the generated namespace enum carries this.

struct Point @0xd0c5000000000011 {
  # A point in the plane.
  #
  # Second paragraph, after a blank comment line.

  x @0 :Int32;  # Horizontal position.
  y @1 :Int32;
  # Vertical position, documented on the line below.
  label @2 :Text;
  shape :union {  # Which shape the point marks.
    dot @3 :Void;  # A bare dot.
    circle @4 :Float32;  # A circle of this radius.
  }
  style :group {  # Drawing style.
    bold @5 :Bool;  # Draw heavier.
  }
  struct Nested @0xd0c5000000000012 {  # A nested declaration.
    n @0 :UInt8;
  }
}

struct Plain @0xd0c5000000000013 {
  value @0 :UInt16;
}
