import Foundation
#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
#endif

enum KeyboardLayoutService {
    #if canImport(AppKit)
    static func preferEnglishLayoutIfNeeded() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        if languages(for: current).contains(where: { $0.hasPrefix("en") }) {
            return
        }

        let filter: CFDictionary = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout
        ] as CFDictionary

        guard let cfArray = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return }
        var englishSource: TISInputSource?
        let preferredIDs: Set<String> = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.British"
        ]
        let count = CFArrayGetCount(cfArray)
        for index in 0..<count {
            let raw = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, index), to: TISInputSource.self)
            let languages = languages(for: raw)
            guard languages.contains(where: { $0.hasPrefix("en") }) else { continue }
            if englishSource == nil { englishSource = raw }
            if let identifier = inputSourceID(for: raw), preferredIDs.contains(identifier) {
                englishSource = raw
                break
            }
        }
        if let englishSource, englishSource != current {
            TISSelectInputSource(englishSource)
        }
    }

    private static func languages(for source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray
        return array.compactMap { $0 as? String }
    }

    private static func inputSourceID(for source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    #else
    static func preferEnglishLayoutIfNeeded() {}
    #endif
}
