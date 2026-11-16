import Foundation
import PeekCore

// P0 stub: drain stdin, print nothing, exit 0.
_ = FileHandle.standardInput.readDataToEndOfFile()
exit(0)
