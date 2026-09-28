import Foundation
import CoreText
import CryptoKit
import FrameCore

/// Fonts the user adds to Ara, and the fonts a title can use.
///
/// Added fonts are copied into Ara's own folder and registered for this process only, so they
/// keep working after the downloaded file is moved or deleted, and nothing is installed for the
/// rest of the system. A title stores the PostScript name of its face; a document opened where
/// that font is missing draws the title in the default font and says so, keeping the name.
public enum FontLibrary {
    public static let fileExtensions: Set<String> = ["ttf","otf","ttc","otc"]
    /// Font files and the ZIP archives fonts are usually downloaded in.
    public static func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return fileExtensions.contains(ext) || ext == "zip"
    }
    /// ~/Library/Application Support/com.framestudio.editor/Fonts.
    public static var folder: URL {
        let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return base.appendingPathComponent("com.framestudio.editor/Fonts",isDirectory:true)
    }

    public struct Face: Hashable, Sendable, Identifiable {
        public let postScriptName: String
        /// The family as CoreText names it ("Gmarket Sans"), and as the user's language shows it
        /// ("G마켓 산스").
        public let family: String
        public let familyDisplayName: String
        /// In the user's language ("볼드체"): for showing only, never for deciding anything.
        public let style: String
        public let weight: Double
        /// From the font's traits, not its (localized) style name.
        public let width: Double
        public let isItalic: Bool
        public var id: String { postScriptName }
        /// Faces such as ".SF NS" are private to the system and cannot be asked for by name.
        public var isHidden: Bool { postScriptName.hasPrefix(".") }
    }
    public struct Family: Hashable, Sendable, Identifiable {
        public let name: String
        public let displayName: String
        public var id: String { name }
        public init(name: String, displayName: String) { self.name = name; self.displayName = displayName }
    }
    public struct ImportResult: Sendable {
        public let added: [Face]
        /// Files (or faces) left out, with why: already available, not a font, …
        public let skipped: [String]
    }

    // MARK: registration

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [String:[Face]] = [:]      // file path → its faces

    /// Registers every font file in `folder` for this process; files already registered are left
    /// alone. Returns the faces of every added font.
    @discardableResult
    public static func registerAddedFonts(in folder: URL = folder) -> [Face] {
        let files = ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [])
            .filter { fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [Face] = []
        for file in files { all += register(file) }
        return all
    }
    /// The faces of the fonts in `folder` (registered by now), for the "Added" part of a font menu.
    public static func addedFaces(in folder: URL = folder) -> [Face] {
        let prefix = folder.standardizedFileURL.path+"/"
        return lock.withLock { registered.filter { $0.key.hasPrefix(prefix) }.values.flatMap { $0 } }
            .sorted { ($0.familyDisplayName,$0.weight,$0.style) < ($1.familyDisplayName,$1.weight,$1.style) }
    }
    /// `fresh` registers a file just copied in even if a file of that name was seen before (the
    /// old one may have been deleted outside Ara). Only successes are remembered.
    private static func register(_ file: URL, fresh: Bool = false) -> [Face] {
        let path = file.standardizedFileURL.path
        if !fresh, let known = lock.withLock({ registered[path] }) { return known }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(file as CFURL,.process,&error)
        let faces = descriptors(of:file).compactMap(face).filter { !$0.isHidden }
        // Already registered (by this process earlier) counts: its faces resolve.
        guard !faces.isEmpty, ok || faces.allSatisfy({ isAvailable($0.postScriptName) }) else { return [] }
        lock.withLock { registered[path] = faces }
        return faces
    }

    // MARK: adding fonts

    /// Copies the fonts in `urls` (font files, or ZIP archives of them) into `folder` and
    /// registers them. Skipped, with the reason: the same file added before, fonts already on this
    /// Mac, and collections that would replace an installed face for the rest of the session.
    /// Throws when nothing was added.
    public static func importFonts(_ urls: [URL], into folder: URL = folder) throws -> ImportResult {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ara-fonts-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:scratch) }
        var candidates: [URL] = [], skipped: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            // A symbolic link is followed: Ara keeps the font itself, not a link to the download.
            if fileExtensions.contains(ext) { candidates.append(url.resolvingSymlinksInPath()) }
            else if ext == "zip" {
                let target = scratch.appendingPathComponent(UUID().uuidString,isDirectory:true)
                do {
                    try unzip(url.resolvingSymlinksInPath(),to:target)
                    let found = fontFiles(in:target)
                    if found.isEmpty { skipped.append("\(url.lastPathComponent): no fonts in the archive") }
                    candidates += found
                } catch { skipped.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            } else { skipped.append("\(url.lastPathComponent): .\(ext) fonts are not supported (use TTF, OTF, TTC or a ZIP of them)") }
        }
        var added: [Face] = []
        var seen = Set(((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).compactMap(digest))
        for file in candidates {
            let name = file.lastPathComponent
            let faces = descriptors(of:file).compactMap(face).filter { !$0.isHidden }
            guard !faces.isEmpty else { skipped.append("\(name): not a font CoreText can read"); continue }
            guard let hash = digest(file), !seen.contains(hash) else { skipped.append("\(name): already added"); continue }
            let taken = faces.filter { isAvailable($0.postScriptName) }
            guard taken.count < faces.count else {
                skipped.append("\(name): \(faces.map(\.postScriptName).joined(separator:", ")) is already available"); continue
            }
            // Registering the whole file would make its copies of installed faces win over the
            // installed ones (every title in them, the default font included) until Ara quits.
            guard taken.isEmpty else {
                skipped.append("\(name): has faces already on this Mac (\(taken.map(\.postScriptName).joined(separator:", "))), so it was not added"); continue
            }
            let destination = uniqueURL(for:name,in:folder)
            do { try FileManager.default.copyItem(at:file,to:destination) }
            catch { skipped.append("\(name): \(error.localizedDescription)"); continue }
            let registeredFaces = register(destination,fresh:true)
            guard !registeredFaces.isEmpty else {
                try? FileManager.default.removeItem(at:destination)
                skipped.append("\(name): macOS did not accept this font"); continue
            }
            seen.insert(hash); added += registeredFaces
        }
        guard !added.isEmpty else {
            throw EditError(skipped.isEmpty ? "No fonts were found." : "No new fonts were added.\n" + skipped.joined(separator:"\n"))
        }
        return ImportResult(added:added.sorted { ($0.familyDisplayName,$0.weight) < ($1.familyDisplayName,$1.weight) },skipped:skipped)
    }
    private static func unzip(_ archive: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath:"/usr/bin/ditto")
        ditto.arguments = ["-x","-k",archive.path,target.path]
        ditto.standardInput = FileHandle.nullDevice; ditto.standardOutput = FileHandle.nullDevice; ditto.standardError = FileHandle.nullDevice
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw EditError("The archive could not be opened.") }
    }
    /// Font files anywhere in an unpacked archive: real files only (no links), without macOS
    /// resource-fork litter.
    private static func fontFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:keys) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "__MACOSX" { walker.skipDescendants(); continue }
            guard !url.lastPathComponent.hasPrefix("."), fileExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys:Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url)
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func digest(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf:file,options:.mappedIfSafe) else { return nil }
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name), n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        // A dangling link still occupies its name.
        func taken(_ url: URL) -> Bool { FileManager.default.fileExists(atPath:url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) != nil }
        while taken(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        return candidate
    }

    // MARK: looking fonts up

    /// The face with exactly this PostScript name. CTFontCreateWithName is not enough: with a
    /// family installed both as static files and as a variable font it can return the variable
    /// font's instance ("X-Bold" → "X-Regular_Bold"), and otherwise substitutes silently.
    private static func descriptor(named postScriptName: String) -> CTFontDescriptor? {
        guard !postScriptName.isEmpty, !postScriptName.hasPrefix(".") else { return nil }
        let wanted = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute:postScriptName] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(wanted,NSSet(object:kCTFontNameAttribute) as CFSet) as? [CTFontDescriptor] ?? []
        return matches.first { CTFontDescriptorCopyAttribute($0,kCTFontNameAttribute) as? String == postScriptName }
    }
    /// True when a font with exactly this PostScript name is on this Mac (or added).
    public static func isAvailable(_ postScriptName: String) -> Bool { descriptor(named:postScriptName) != nil }
    /// The title font: the named face, or the default one when it is not available here.
    public static func font(_ postScriptName: String, size: CGFloat) -> CTFont {
        if let found = descriptor(named:postScriptName) { return CTFontCreateWithFontDescriptor(found,size,nil) }
        return CTFontCreateWithName(ClipStyle.defaultFontName as CFString,size,nil)
    }
    public static func face(_ postScriptName: String) -> Face? { descriptor(named:postScriptName).flatMap(face) }
    /// Every family on this Mac (added fonts included), by display name. Hidden system families
    /// (a leading dot) are left out.
    public static func families() -> [Family] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { !$0.hasPrefix(".") }
        return names.map { name in
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute:name] as CFDictionary)
            let display = CTFontDescriptorCopyLocalizedAttribute(descriptor,kCTFontFamilyNameAttribute,nil) as? String ?? name
            return Family(name:name,displayName:display)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    /// The face a font menu shows a family's name in: its regular face. Nil when the name would
    /// not read in it: symbol and emoji fonts (Webdings, Zapf Dingbats) and fonts without the
    /// name's own letters (most Arabic, Hebrew and Indic fonts have Latin names); those show in
    /// the system font.
    public static func previewFace(of family: Family) -> String? {
        guard let face = closestFace(inFamily:family.name,toWeight:0) else { return nil }
        let font = CTFontCreateWithName(face.postScriptName as CFString,13,nil)
        let style = CTFontGetSymbolicTraits(font).rawValue & CTFontSymbolicTraits.traitClassMask.rawValue
        guard style != CTFontStylisticClass.symbolicClass.rawValue,
              !((CTFontCopySupportedLanguages(font) as? [String]) ?? []).isEmpty else { return nil }
        let text = Array(family.displayName.utf16)
        var glyphs = [CGGlyph](repeating:0,count:text.count)
        return CTFontGetGlyphsForCharacters(font,text,&glyphs,text.count) ? face.postScriptName : nil
    }
    /// The faces of one family: upright before italic, lightest first, normal width first.
    public static func faces(ofFamily family: String) -> [Face] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute:family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor,NSSet(object:kCTFontFamilyNameAttribute) as CFSet) as? [CTFontDescriptor] ?? []
        var seen = Set<String>()
        return matches.compactMap(face).filter { $0.family == family && !$0.isHidden && seen.insert($0.postScriptName).inserted }
            .sorted { ($0.isItalic ? 1 : 0,$0.weight,abs($0.width),$0.postScriptName) < ($1.isItalic ? 1 : 0,$1.weight,abs($1.width),$1.postScriptName) }
    }
    /// The face of `family` for a title moving to it: closest in weight (a Bold title stays bold),
    /// upright unless `italic`, normal width when the family also has condensed or wide faces.
    public static func closestFace(inFamily family: String, toWeight weight: Double, italic: Bool = false) -> Face? {
        let faces = faces(ofFamily:family)
        let slanted = faces.filter { $0.isItalic == italic }
        return (slanted.isEmpty ? faces : slanted).min { (abs($0.weight-weight),abs($0.width)) < (abs($1.weight-weight),abs($1.width)) }
    }

    private static func descriptors(of file: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []
    }
    private static func face(_ descriptor: CTFontDescriptor) -> Face? {
        guard let name = CTFontDescriptorCopyAttribute(descriptor,kCTFontNameAttribute) as? String,
              let family = CTFontDescriptorCopyAttribute(descriptor,kCTFontFamilyNameAttribute) as? String else { return nil }
        let display = CTFontDescriptorCopyLocalizedAttribute(descriptor,kCTFontFamilyNameAttribute,nil) as? String ?? family
        let style = CTFontDescriptorCopyLocalizedAttribute(descriptor,kCTFontStyleNameAttribute,nil) as? String
            ?? CTFontDescriptorCopyAttribute(descriptor,kCTFontStyleNameAttribute) as? String ?? "Regular"
        let traits = CTFontDescriptorCopyAttribute(descriptor,kCTFontTraitsAttribute) as? [String:Any]
        let weight = (traits?[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        let width = (traits?[kCTFontWidthTrait as String] as? NSNumber)?.doubleValue ?? 0
        let symbolic = (traits?[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0
        return Face(postScriptName:name,family:family,familyDisplayName:display,style:style,weight:weight,
                    width:width,isItalic:symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0)
    }
}
