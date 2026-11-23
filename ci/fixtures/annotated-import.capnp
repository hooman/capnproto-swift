# Mirrors /capnp/c++.capnp: the file annotates itself with an annotation it declares.
@0xa11071a7ed000001;
$namespace("fixture::annotations");
annotation namespace(file) :Text;
annotation name(field, enumerant, struct, enum, interface, method, param, group, union) :Text;
struct Thing @0xa11071a7ed000011 $name("thing") {
  id @0 :UInt64 $name("ident");
}
