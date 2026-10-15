// Prints the current keyboard input source ID, or selects the given one.
// XCUITest synthesizes shortcuts such as ⌘N through the active layout; a Hangul input mode drops them.
import Carbon

func identifier(_ source: TISInputSource) -> String {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

if CommandLine.arguments.count > 1 {
    let wanted = CommandLine.arguments[1]
    let filter = [kTISPropertyInputSourceID as String: wanted] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first, TISSelectInputSource(source) == noErr else {
        FileHandle.standardError.write(Data("Could not select input source: \(wanted)\n".utf8))
        exit(1)
    }
}
print(identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
