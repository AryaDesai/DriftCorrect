import Foundation

/// Physical calibration and channel names carried through every output file.
public struct ImageMetadata: Equatable, Sendable {
    public var channelNames: [String]
    public var physicalSizeX: Double?
    public var physicalSizeY: Double?
    public var physicalSizeZ: Double?
    public var timeIncrement: Double?
    public var physicalSizeXUnit: String? = "µm"
    public var physicalSizeYUnit: String? = "µm"
    public var physicalSizeZUnit: String? = "µm"
    public var timeIncrementUnit: String? = "s"

    public init(channelNames: [String], physicalSizeX: Double? = nil, physicalSizeY: Double? = nil,
                physicalSizeZ: Double? = nil, timeIncrement: Double? = nil) {
        self.channelNames = channelNames
        self.physicalSizeX = physicalSizeX
        self.physicalSizeY = physicalSizeY
        self.physicalSizeZ = physicalSizeZ
        self.timeIncrement = timeIncrement
    }

    /// Metadata as `save_ome_tiff` writes it: units always µm and s.
    public static func standard(channelNames: [String], voxel: VoxelSize, period: Double?) -> ImageMetadata {
        ImageMetadata(channelNames: channelNames, physicalSizeX: voxel.x, physicalSizeY: voxel.y,
                      physicalSizeZ: voxel.z, timeIncrement: period)
    }

    public var voxel: VoxelSize { VoxelSize(x: physicalSizeX ?? 1, y: physicalSizeY ?? 1, z: physicalSizeZ ?? 1) }
}

public struct VoxelSize: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

/// The parsed `Pixels` element of an OME-XML block.
public struct OMEPixels: Equatable, Sendable {
    public var dimensionOrder = "XYZCT"
    public var type: String?
    public var sizeX = 1, sizeY = 1, sizeZ = 1, sizeC = 1, sizeT = 1
    public var attributes: [String: String] = [:]
    public var channelNames: [String?] = []
    public var firstIFD = 0
}

public enum OMEXML {
    /// Parse the first `Pixels` element of an OME-XML string.
    public static func parse(_ xml: String) -> OMEPixels? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.pixels
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var pixels: OMEPixels?
        var inPixels = false
        var done = false
        var sawTiffData = false

        static func local(_ name: String) -> String {
            if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
            return name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if done { return }
            let name = Delegate.local(elementName)
            if name == "Pixels" && pixels == nil {
                var p = OMEPixels()
                p.attributes = attributes
                p.dimensionOrder = attributes["DimensionOrder"] ?? "XYZCT"
                p.type = attributes["Type"]
                p.sizeX = Int(attributes["SizeX"] ?? "") ?? 1
                p.sizeY = Int(attributes["SizeY"] ?? "") ?? 1
                p.sizeZ = Int(attributes["SizeZ"] ?? "") ?? 1
                p.sizeC = Int(attributes["SizeC"] ?? "") ?? 1
                p.sizeT = Int(attributes["SizeT"] ?? "") ?? 1
                pixels = p
                inPixels = true
            } else if inPixels && name == "Channel" {
                pixels?.channelNames.append(attributes["Name"])
            } else if inPixels && name == "TiffData" && !sawTiffData {
                sawTiffData = true
                pixels?.firstIFD = Int(attributes["IFD"] ?? "0") ?? 0
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if Delegate.local(elementName) == "Pixels" && inPixels {
                inPixels = false
                done = true
            }
        }
    }

    /// `load_tif_metadata` OME-XML branch, with each field parsed independently.
    ///
    /// The Python code drops every value (channel names too) when any one of
    /// PhysicalSizeX/Y/Z is missing. Here a missing size falls back to 1.0 alone.
    public static func metadata(from pixels: OMEPixels, channelCount: Int) -> ImageMetadata {
        var names: [String] = []
        for (i, n) in pixels.channelNames.enumerated() { names.append(n ?? "ch\(i)") }
        if names.isEmpty { names = (0..<channelCount).map { "ch\($0)" } }
        func dbl(_ k: String) -> Double? { pixels.attributes[k].flatMap { Double($0) } }
        var m = ImageMetadata(channelNames: names,
                              physicalSizeX: dbl("PhysicalSizeX") ?? 1.0,
                              physicalSizeY: dbl("PhysicalSizeY") ?? 1.0,
                              physicalSizeZ: dbl("PhysicalSizeZ") ?? 1.0,
                              timeIncrement: dbl("TimeIncrement"))
        m.physicalSizeXUnit = pixels.attributes["PhysicalSizeXUnit"] ?? "µm"
        m.physicalSizeYUnit = pixels.attributes["PhysicalSizeYUnit"] ?? "µm"
        m.physicalSizeZUnit = pixels.attributes["PhysicalSizeZUnit"] ?? "µm"
        m.timeIncrementUnit = pixels.attributes["TimeIncrementUnit"] ?? "s"
        return m
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// OME-XML in the form that tifffile writes for `save_ome_tiff`.
    public static func build(t: Int, c: Int, z: Int, y: Int, x: Int, type: SampleType, metadata m: ImageMetadata) -> String {
        var px = "<Pixels ID=\"Pixels:0\" DimensionOrder=\"XYZCT\" Type=\"\(type.omeType)\""
        px += " SizeX=\"\(x)\" SizeY=\"\(y)\" SizeZ=\"\(z)\" SizeC=\"\(c)\" SizeT=\"\(t)\""
        if let v = m.physicalSizeX { px += " PhysicalSizeX=\"\(PyFormat.repr(v))\"" }
        if let u = m.physicalSizeXUnit, m.physicalSizeX != nil { px += " PhysicalSizeXUnit=\"\(escape(u))\"" }
        if let v = m.physicalSizeY { px += " PhysicalSizeY=\"\(PyFormat.repr(v))\"" }
        if let u = m.physicalSizeYUnit, m.physicalSizeY != nil { px += " PhysicalSizeYUnit=\"\(escape(u))\"" }
        if let v = m.physicalSizeZ { px += " PhysicalSizeZ=\"\(PyFormat.repr(v))\"" }
        if let u = m.physicalSizeZUnit, m.physicalSizeZ != nil { px += " PhysicalSizeZUnit=\"\(escape(u))\"" }
        if let v = m.timeIncrement { px += " TimeIncrement=\"\(PyFormat.repr(v))\"" }
        if let u = m.timeIncrementUnit { px += " TimeIncrementUnit=\"\(escape(u))\"" }
        px += ">"
        for ci in 0..<c {
            let name = ci < m.channelNames.count ? " Name=\"\(escape(m.channelNames[ci]))\"" : ""
            px += "<Channel ID=\"Channel:0:\(ci)\" SamplesPerPixel=\"1\"\(name)><LightPath/></Channel>"
        }
        px += "<TiffData IFD=\"0\" PlaneCount=\"\(t * c * z)\"/></Pixels>"
        let uuid = UUID().uuidString.lowercased()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<OME xmlns=\"http://www.openmicroscopy.org/Schemas/OME/2016-06\""
            + " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
            + " xsi:schemaLocation=\"http://www.openmicroscopy.org/Schemas/OME/2016-06 http://www.openmicroscopy.org/Schemas/OME/2016-06/ome.xsd\""
            + " UUID=\"urn:uuid:\(uuid)\" Creator=\"DriftCorrect\">"
            + "<Image ID=\"Image:0\" Name=\"Image0\">" + px + "</Image></OME>"
    }
}
