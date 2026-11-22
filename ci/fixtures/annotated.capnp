# Annotation uses on every node and member kind the generator renders, plus nested and
# top-level annotation declarations. Generated output must equal the unannotated twin.
@0xa11071a7ed000002;
using Ann = import "annotated-import.capnp";
$Ann.namespace("fixture");
annotation tag @0xa11071a7ed000021 (*) :UInt32;
struct Box @0xa11071a7ed000022 $tag(1) $Ann.name("box") {
  value @0 :UInt32 = 5 $tag(2);
  thing @1 :Ann.Thing $tag(3);
  choice :union $tag(4) {
    idle @2 :Void $tag(5);
    count @3 :UInt16 $tag(6);
  }
  extra :group $tag(7) {
    flag @4 :Bool $tag(8);
  }
  annotation inner @0xa11071a7ed000024 (field) :Void;
  struct Nested @0xa11071a7ed000023 $tag(9) {
    x @0 :Int8 $Ann.name("x") $inner;
  }
}
