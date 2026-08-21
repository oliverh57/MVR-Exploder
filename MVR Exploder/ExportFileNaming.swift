import AppKit
import UniformTypeIdentifiers

extension NSSavePanel {
    /// Prepares a save panel for one file type without doubling its
    /// extension.
    ///
    /// `.mvr` and `.gdtf` aren't types macOS declares, so `UTType` hands
    /// back a *dynamic* one (`dyn.ah62d4rv4ge8047xw`, `isDeclared == false`).
    /// The panel doesn't recognise that a suggested name already ends in the
    /// right extension for such a type and appends its own, which is where
    /// `Show_edited.mvr.mvr` came from. Declared types like `.pdf` and
    /// `.obj` never showed it, which is why it looked like an MVR-only bug.
    ///
    /// Passing the name without an extension and letting the panel add it
    /// gives exactly one, whether the type is declared or not.
    func prepareForExport(named name: String, fileExtension: String) {
        let asPath = name as NSString
        // Only strip an extension that's actually the one being added —
        // `deletingPathExtension` would otherwise eat the tail of a name
        // like "Show v1.2".
        nameFieldStringValue = asPath.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
            ? asPath.deletingPathExtension
            : name

        if let type = UTType(filenameExtension: fileExtension) {
            allowedContentTypes = [type]
        }
    }
}

extension URL {
    /// The URL with this extension, added only if it isn't already there.
    /// Guards the other direction: if a panel ever declines to add the
    /// extension, the file still lands with the right one.
    func ensuringPathExtension(_ fileExtension: String) -> URL {
        pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
            ? self
            : appendingPathExtension(fileExtension)
    }
}
