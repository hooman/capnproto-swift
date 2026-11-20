// FLAGS: -enable-experimental-feature LifetimeDependence
// EXPECT-ERROR: Unsupported use of @lifetime

import CapnpRuntime

@lifetime(copy reader)
private func identity(_ reader: StructReader) -> StructReader {
    reader.borrowed()
}
