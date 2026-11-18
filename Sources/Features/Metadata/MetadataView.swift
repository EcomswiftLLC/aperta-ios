import SwiftUI
import UIKit
import PhotosUI
import ImageIO

// MARK: - Model

struct MtdRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct MtdGroup: Identifiable {
    let title: String
    let rows: [MtdRow]
    let emptyText: String
    var id: String { title }
}

struct MtdLocation {
    let latitude: Double
    let longitude: Double
    let rows: [MtdRow]

    /// Apple Maps address for the position. It is opened only when the person taps "Open in Maps"; nothing is loaded before.
    var mapsURL: URL? {
        URL(string: String(format: "https://maps.apple.com/?ll=%.6f,%.6f&q=Photo%%20location", latitude, longitude))
    }
}

struct MtdReport {
    let groups: [MtdGroup]
    let location: MtdLocation?
    /// Place names stored as text in the photo (city, region, country), apart from the GPS position.
    let placeRows: [MtdRow]
    let outputFormat: OutputFormat
    let formatTitle: String

    var hasAnyLocation: Bool { location != nil || !placeRows.isEmpty }
}

// MARK: - Reading

enum MtdReader {
    static func report(for photo: LoadedPhoto) -> MtdReport {
        let source = CGImageSourceCreateWithData(photo.originalData as CFData, nil)
        var properties = photo.properties
        if properties.isEmpty, let source,
           let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            properties = copied
        }
        let typeIdentifier: String = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String } ?? ""
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        let format = outputFormat(for: typeIdentifier)
        let formatTitle = readableFormat(typeIdentifier)

        let groups: [MtdGroup] = [
            MtdGroup(title: "Camera", rows: cameraRows(exif: exif, tiff: tiff), emptyText: "No camera details in this photo."),
            MtdGroup(title: "Capture", rows: captureRows(exif: exif, tiff: tiff), emptyText: "No capture settings in this photo."),
            MtdGroup(
                title: "Image",
                rows: imageRows(photo: photo, properties: properties, formatTitle: formatTitle),
                emptyText: "No image details."
            ),
        ]
        return MtdReport(
            groups: groups,
            location: location(from: gps),
            placeRows: placeRows(properties),
            outputFormat: format,
            formatTitle: formatTitle
        )
    }

    /// True when the file still names a place: a GPS position or an IPTC place name (city, region, country, sub-location).
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        return location(from: properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]) != nil
            || !placeRows(properties).isEmpty
    }

    /// City, region and country written as text (IPTC), shown next to the GPS position.
    static func placeRows(_ properties: [String: Any]) -> [MtdRow] {
        guard let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] else { return [] }
        let fields: [(label: String, key: CFString)] = [
            ("Place", kCGImagePropertyIPTCSubLocation),
            ("City", kCGImagePropertyIPTCCity),
            ("Region", kCGImagePropertyIPTCProvinceState),
            ("Country", kCGImagePropertyIPTCCountryPrimaryLocationName),
            ("Country code", kCGImagePropertyIPTCCountryPrimaryLocationCode),
            ("Content location", kCGImagePropertyIPTCContentLocationName),
        ]
        return fields.compactMap { field in
            text(iptc[field.key as String]).map { MtdRow(label: field.label, value: $0) }
        }
    }

    // MARK: Groups

    private static func cameraRows(exif: [String: Any], tiff: [String: Any]) -> [MtdRow] {
        var rows: [MtdRow] = []
        if let make = text(tiff[kCGImagePropertyTIFFMake as String]) { rows.append(MtdRow(label: "Make", value: make)) }
        if let model = text(tiff[kCGImagePropertyTIFFModel as String]) { rows.append(MtdRow(label: "Model", value: model)) }
        if let lens = text(exif[kCGImagePropertyExifLensModel as String]) { rows.append(MtdRow(label: "Lens", value: lens)) }
        if let software = text(tiff[kCGImagePropertyTIFFSoftware as String]) {
            rows.append(MtdRow(label: "Software", value: software))
        }
        return rows
    }

    private static func captureRows(exif: [String: Any], tiff: [String: Any]) -> [MtdRow] {
        var rows: [MtdRow] = []
        let rawDate = text(exif[kCGImagePropertyExifDateTimeOriginal as String]) ?? text(tiff[kCGImagePropertyTIFFDateTime as String])
        if let rawDate { rows.append(MtdRow(label: "Taken", value: readableDate(rawDate))) }
        if let exposure = number(exif[kCGImagePropertyExifExposureTime as String]), exposure > 0 {
            rows.append(MtdRow(label: "Exposure", value: readableExposure(exposure)))
        }
        if let aperture = number(exif[kCGImagePropertyExifFNumber as String]), aperture > 0 {
            rows.append(MtdRow(label: "Aperture", value: "f/" + trimmed(aperture, decimals: 1)))
        }
        if let iso = isoValue(exif[kCGImagePropertyExifISOSpeedRatings as String]) {
            rows.append(MtdRow(label: "ISO", value: String(iso)))
        }
        if let focal = number(exif[kCGImagePropertyExifFocalLength as String]), focal > 0 {
            var value = trimmed(focal, decimals: 1) + " mm"
            if let equivalent = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]), equivalent > 0 {
                value += ", \(Int(equivalent.rounded())) mm full-frame equivalent"
            }
            rows.append(MtdRow(label: "Focal length", value: value))
        }
        return rows
    }

    private static func imageRows(photo: LoadedPhoto, properties: [String: Any], formatTitle: String) -> [MtdRow] {
        var rows: [MtdRow] = []
        let width = Int(photo.pixelSize.width)
        let height = Int(photo.pixelSize.height)
        let megapixels = Double(width * height) / 1_000_000
        rows.append(MtdRow(label: "Size", value: "\(width) \u{00D7} \(height) pixels, \(trimmed(megapixels, decimals: 1)) MP"))
        rows.append(MtdRow(label: "File size", value: ByteText.string(photo.originalBytes)))
        if let profile = text(properties[kCGImagePropertyProfileName as String]) {
            rows.append(MtdRow(label: "Color profile", value: profile))
        }
        rows.append(MtdRow(label: "Format", value: formatTitle))
        return rows
    }

    private static func location(from gps: [String: Any]?) -> MtdLocation? {
        guard let gps,
              let rawLatitude = number(gps[kCGImagePropertyGPSLatitude as String]),
              let rawLongitude = number(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        let latitudeRef = (text(gps[kCGImagePropertyGPSLatitudeRef as String]) ?? "").uppercased()
        let longitudeRef = (text(gps[kCGImagePropertyGPSLongitudeRef as String]) ?? "").uppercased()
        var latitude = rawLatitude
        var longitude = rawLongitude
        if latitudeRef.hasPrefix("S") { latitude = -abs(rawLatitude) } else if latitudeRef.hasPrefix("N") { latitude = abs(rawLatitude) }
        if longitudeRef.hasPrefix("W") { longitude = -abs(rawLongitude) } else if longitudeRef.hasPrefix("E") { longitude = abs(rawLongitude) }
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }

        var rows: [MtdRow] = [
            MtdRow(label: "Latitude", value: String(format: "%.5f\u{00B0} %@", abs(latitude), latitude < 0 ? "S" : "N")),
            MtdRow(label: "Longitude", value: String(format: "%.5f\u{00B0} %@", abs(longitude), longitude < 0 ? "W" : "E")),
        ]
        if let altitude = number(gps[kCGImagePropertyGPSAltitude as String]) {
            let below = (number(gps[kCGImagePropertyGPSAltitudeRef as String]) ?? 0) == 1
            let metres = Int(altitude.rounded())
            rows.append(MtdRow(label: "Altitude", value: below ? "\(metres) m below sea level" : "\(metres) m above sea level"))
        }
        return MtdLocation(latitude: latitude, longitude: longitude, rows: rows)
    }

    // MARK: Values

    private static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string: String
        if let direct = value as? String {
            string = direct
        } else if let number = value as? NSNumber {
            string = number.stringValue
        } else {
            return nil
        }
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0000}")))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func isoValue(_ value: Any?) -> Int? {
        if let list = value as? [NSNumber], let first = list.first { return first.intValue }
        if let list = value as? [Int], let first = list.first { return first }
        if let single = number(value) { return Int(single.rounded()) }
        return nil
    }

    private static func trimmed(_ value: Double, decimals: Int) -> String {
        let formatted = String(format: "%.\(decimals)f", value)
        if formatted.contains(".") {
            var result = formatted
            while result.hasSuffix("0") { result.removeLast() }
            if result.hasSuffix(".") { result.removeLast() }
            return result
        }
        return formatted
    }

    private static func readableExposure(_ seconds: Double) -> String {
        if seconds >= 1 { return trimmed(seconds, decimals: 1) + " s" }
        let denominator = Int((1 / seconds).rounded())
        return "1/\(max(1, denominator)) s"
    }

    private static func readableDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }

    private static func outputFormat(for typeIdentifier: String) -> OutputFormat {
        let lower = typeIdentifier.lowercased()
        if lower.contains("png") { return .png }
        if lower.contains("heic") || lower.contains("heif") {
            return OutputFormat.available.contains(.heic) ? .heic : .jpeg
        }
        return .jpeg
    }

    private static func readableFormat(_ typeIdentifier: String) -> String {
        let lower = typeIdentifier.lowercased()
        if lower.contains("heic") || lower.contains("heif") { return "HEIC" }
        if lower.contains("png") { return "PNG" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "JPG" }
        if lower.contains("tiff") { return "TIFF" }
        if lower.contains("dng") || lower.contains("raw") { return "RAW" }
        if lower.contains("webp") { return "WebP" }
        if lower.contains("gif") { return "GIF" }
        return typeIdentifier.isEmpty ? "Unknown" : typeIdentifier
    }
}

// MARK: - Cleaning

enum MtdCleaner {
    static func cleaned(_ properties: [String: Any], location: Bool, device: Bool, all: Bool) -> [String: Any] {
        if all { return [:] }
        let gpsKey = kCGImagePropertyGPSDictionary as String
        if device {
            var result = ImageCodec.privacySafe(properties)
            result.removeValue(forKey: kCGImagePropertyExifAuxDictionary as String)
            if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware] {
                    tiff.removeValue(forKey: key as String)
                }
                result[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            if var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                for key in [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification] {
                    exif.removeValue(forKey: key as String)
                }
                result[kCGImagePropertyExifDictionary as String] = exif
            }
            if !location {
                // The person chose to keep the place: put back the GPS position and the IPTC place names.
                if let gps = properties[gpsKey] { result[gpsKey] = gps }
                let iptcKey = kCGImagePropertyIPTCDictionary as String
                if let iptc = properties[iptcKey] as? [String: Any] {
                    let places = iptc.filter { ImageCodec.iptcLocationKeys.contains($0.key) }
                    if !places.isEmpty { result[iptcKey] = places }
                }
            }
            return result
        }
        // Location only: the GPS position and the IPTC place names go, everything else stays.
        var result = ImageCodec.sanitized(properties)
        if location { result = ImageCodec.removingLocation(result) }
        return result
    }
}

private struct MtdResult {
    let item: ExportItem
    let stillHasLocation: Bool
}

// MARK: - Screen

@MainActor
struct MetadataView: View {
    @StateObject private var selection = PhotoSelection()
    @State private var pickerItem: PhotosPickerItem?
    @State private var report: MtdReport?
    @State private var removeLocation: Bool = true
    @State private var removeDevice: Bool = false
    @State private var removeAll: Bool = false
    @State private var result: MtdResult?
    @State private var isWorking: Bool = false
    @State private var failed: Bool = false

    nonisolated init() {}

    var body: some View {
        ToolScreen(
            title: "Photo details",
            subtitle: "See where and how a photo was taken, then save a copy without the details you want to keep private."
        ) {
            if let photo = selection.photos.first, let report {
                photoHeader(photo)
                ForEach(report.groups) { group in
                    groupView(group)
                }
                locationSection(report: report, photoID: photo.id)
                cleanSection(report: report)
            } else {
                emptyState
            }
        }
        #if DEBUG
        .task {
            if DebugSamples.enabled && selection.photos.isEmpty {
                selection.photos = DebugSamples.photos(1, withMetadata: true)
                if let photo = selection.photos.first { report = MtdReader.report(for: photo) }
            }
        }
        #endif
        .onChange(of: pickerItem) {
            Task { await loadPhoto() }
        }
        .onChange(of: cleanKey) {
            result = nil
            failed = false
        }
    }

    private var cleanKey: [Bool] { [removeLocation, removeDevice, removeAll] }

    private var anyOptionOn: Bool { removeAll || removeLocation || removeDevice }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if selection.isLoading {
            HStack(spacing: AP.Space.s) {
                ProgressView().tint(AP.Palette.brass)
                Text("Reading your photo").font(AP.Font.callout).foregroundStyle(AP.Palette.mist)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                PickPhotosPrompt(
                    title: "Choose a photo",
                    detail: "You will see its camera, date and location details before anything is changed.",
                    systemImage: "info.circle"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Choose a photo"))
            if selection.failedCount > 0 {
                Label("That photo could not be opened. Try another one.", systemImage: "exclamationmark.triangle")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.danger)
            }
        }
    }

    // MARK: Header

    private func photoHeader(_ photo: LoadedPhoto) -> some View {
        HStack(spacing: AP.Space.m) {
            Image(uiImage: photo.uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: AP.Radius.chip, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your photo")
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.paper)
                Text(ByteText.string(photo.originalBytes))
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            Spacer(minLength: AP.Space.s)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Change")
            }
            .buttonStyle(.apQuiet)
            .accessibilityLabel(Text("Choose a different photo"))
        }
        .padding(AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    // MARK: Groups

    private func groupView(_ group: MtdGroup) -> some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            APSectionTitle(text: group.title)
            if group.rows.isEmpty {
                Text(group.emptyText)
                    .font(AP.Font.callout)
                    .foregroundStyle(AP.Palette.mist)
                    .frame(minHeight: 44, alignment: .leading)
            } else {
                rowList(group.rows)
            }
        }
    }

    private func rowList(_ rows: [MtdRow]) -> some View {
        VStack(spacing: 0) {
            APHairline()
            ForEach(rows) { row in
                MtdRowView(row: row)
                APHairline()
            }
        }
    }

    // MARK: Location

    private func locationSection(report: MtdReport, photoID: UUID) -> some View {
        VStack(alignment: .leading, spacing: AP.Space.s) {
            APSectionTitle(text: "Location")
            if report.hasAnyLocation {
                locationNotice
                if let location = report.location {
                    rowList(location.rows)
                    openInMapsButton(location)
                        .id(photoID)
                }
                if !report.placeRows.isEmpty {
                    rowList(report.placeRows)
                }
            } else {
                HStack(spacing: AP.Space.s) {
                    Image(systemName: "location.slash")
                        .foregroundStyle(AP.Palette.mist)
                        .accessibilityHidden(true)
                    Text("No location in this photo")
                        .font(AP.Font.callout)
                        .foregroundStyle(AP.Palette.mist)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    private var locationNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: AP.Space.s) {
            Image(systemName: "location.fill")
                .foregroundStyle(AP.Palette.brass)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This photo contains location details")
                    .font(AP.Font.headline)
                    .foregroundStyle(AP.Palette.paper)
                Text("Anyone you send the original file to can see where it was taken.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            Spacer(minLength: 0)
        }
        .padding(AP.Space.m)
        .background(AP.Palette.brass.opacity(0.10), in: RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.control, style: .continuous)
                .strokeBorder(AP.Palette.brass.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// No map is drawn inside the app, so nothing about the position is sent anywhere while this screen is open.
    /// The person can choose to look at the spot in the Maps app.
    @ViewBuilder
    private func openInMapsButton(_ location: MtdLocation) -> some View {
        if let url = location.mapsURL {
            VStack(alignment: .leading, spacing: AP.Space.xs) {
                Link(destination: url) {
                    Label("Open in Maps", systemImage: "map")
                        .font(AP.Font.label)
                        .foregroundStyle(AP.Palette.brass)
                        .frame(minHeight: 44)
                }
                .accessibilityHint(Text("Opens the Maps app at the photo's position"))
                Text("Opens the Maps app, which looks up the position. Aperta itself sends nothing.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Clean copy

    private var locationBinding: Binding<Bool> {
        Binding(get: { removeAll || removeLocation }, set: { removeLocation = $0 })
    }

    private var deviceBinding: Binding<Bool> {
        Binding(get: { removeAll || removeDevice }, set: { removeDevice = $0 })
    }

    private func cleanSection(report: MtdReport) -> some View {
        VStack(alignment: .leading, spacing: AP.Space.m) {
            APSectionTitle(text: "Save a private copy")
            optionsPanel
            Text("The copy keeps the full size of your photo and is saved again as \(report.outputFormat.title) at high quality. Your original is not changed.")
                .font(AP.Font.caption)
                .foregroundStyle(AP.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
            cleanAction
        }
    }

    private var optionsPanel: some View {
        VStack(spacing: 0) {
            MtdToggleRow(title: "Remove location", detail: "GPS position, altitude and place names", isOn: locationBinding)
                .disabled(removeAll)
            APHairline()
            MtdToggleRow(
                title: "Remove camera and device details",
                detail: "Make, model, lens, software, serial numbers, owner and artist names, comments and maker notes",
                isOn: deviceBinding
            )
            .disabled(removeAll)
            APHairline()
            MtdToggleRow(title: "Remove all metadata", detail: "Keeps only the picture itself", isOn: $removeAll)
        }
        .padding(.horizontal, AP.Space.m)
        .background(AP.Palette.carbon, in: RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AP.Radius.panel, style: .continuous)
                .strokeBorder(AP.Palette.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var cleanAction: some View {
        if let result {
            resultSummary(result)
            ExportBar(items: [result.item], savedMessage: "Private copy saved to your library")
        } else {
            Button {
                Task { await makeCleanCopy() }
            } label: {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().tint(AP.Palette.onBrass) }
                    Text(isWorking ? "Making the copy" : "Make a private copy")
                }
            }
            .buttonStyle(.apPrimaryWide)
            .disabled(isWorking || !anyOptionOn)
            if !anyOptionOn {
                Text("Turn on at least one option above.")
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
            if failed {
                Label("The copy could not be made. Try again.", systemImage: "exclamationmark.triangle")
                    .font(AP.Font.label)
                    .foregroundStyle(AP.Palette.danger)
            }
        }
    }

    private func resultSummary(_ result: MtdResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AP.Space.s) {
            Image(systemName: result.stillHasLocation ? "location.fill" : "checkmark.circle")
                .foregroundStyle(result.stillHasLocation ? AP.Palette.brass : AP.Palette.success)
                .accessibilityHidden(true)
            Text(summaryText(result))
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.paper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryText(_ result: MtdResult) -> String {
        let size = ByteText.string(result.item.data.count)
        if result.stillHasLocation {
            return "Copy ready, \(size). It still includes the location, as you chose."
        }
        return "Copy ready, \(size). No GPS position or place names are left in it."
    }

    // MARK: Work

    private func loadPhoto() async {
        guard let item = pickerItem else { return }
        // Clear the picker choice when done, so choosing the same photo again (for example after a failure) still counts.
        defer { pickerItem = nil }
        result = nil
        failed = false
        report = nil
        // A large limit keeps the photo at its full size, so the clean copy has the same pixels.
        await selection.load([item], maxPixel: 20_000, lazy: false)
        if let photo = selection.photos.first {
            report = MtdReader.report(for: photo)
        }
    }

    private func makeCleanCopy() async {
        guard let photo = selection.photos.first, let report else { return }
        isWorking = true
        failed = false
        let properties = MtdCleaner.cleaned(
            photo.properties,
            location: removeAll || removeLocation,
            device: removeAll || removeDevice,
            all: removeAll
        )
        let format = report.outputFormat
        let made: MtdResult? = await Task.detached(priority: .userInitiated) { () -> MtdResult? in
            guard let image = photo.decodedImage,
                  let data = ImageCodec.encode(image, format: format, quality: 0.95, properties: properties) else { return nil }
            let item = ExportItem(data: data, filename: ExportItem.uniqueName("Aperta-clean", format: format), format: format)
            return MtdResult(item: item, stillHasLocation: MtdReader.hasLocation(data))
        }.value
        isWorking = false
        if let made {
            result = made
            APHaptics.success()
        } else {
            failed = true
            APHaptics.warning()
        }
    }
}

// MARK: - Rows

private struct MtdRowView: View {
    let row: MtdRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AP.Space.m) {
            Text(row.label)
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.mist)
            Spacer(minLength: AP.Space.m)
            Text(row.value)
                .font(AP.Font.callout)
                .foregroundStyle(AP.Palette.paper)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct MtdToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AP.Font.body)
                    .foregroundStyle(AP.Palette.paper)
                Text(detail)
                    .font(AP.Font.caption)
                    .foregroundStyle(AP.Palette.mist)
            }
        }
        .tint(AP.Palette.brass)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
    }
}
