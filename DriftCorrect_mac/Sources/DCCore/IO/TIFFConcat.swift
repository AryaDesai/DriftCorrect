import Foundation

public enum TIFFConcat {
    /// Port of `concatenate_tifs(tif_paths, output_path)` along T.
    ///
    /// Differences from the Python version, by design:
    /// - Samples keep their stored type (uint16 stays uint16). The Python code
    ///   converted everything to float32, which doubled the file size without
    ///   changing any value. Mixed input types still produce float32.
    /// - Metadata comparison looks at channel names and calibration. The raw
    ///   OME-XML strings always differ because each file has its own UUID.
    public static func concatenate(_ inputs: [URL], to output: URL, context: RunContext) throws {
        let sorted = inputs.sorted { a, b in
            Array(a.lastPathComponent.unicodeScalars.map { $0.value })
                .lexicographicallyPrecedes(Array(b.lastPathComponent.unicodeScalars.map { $0.value }))
        }
        guard let firstURL = sorted.first else { throw DCError("No input files to concatenate") }
        let stacks = try sorted.map { try TIFFStack(url: $0) }
        let ref = stacks[0]

        for (i, s) in stacks.enumerated().dropFirst() {
            let dims = [(1, s.c, ref.c), (2, s.z, ref.z), (3, s.y, ref.y), (4, s.x, ref.x)]
            for (axis, got, want) in dims where got != want {
                throw DCError("Dimension mismatch on axis \(axis): \(firstURL.lastPathComponent) has \(want) "
                              + "but \(sorted[i].lastPathComponent) has \(got).")
            }
        }

        if ref.omeXML != nil {
            for (i, s) in stacks.enumerated().dropFirst() {
                if s.omeXML == nil {
                    context.log("Warning: \(sorted[i].lastPathComponent) has no OME metadata")
                } else if s.metadata != ref.metadata {
                    context.log("Warning: OME metadata in \(sorted[i].lastPathComponent) differs from \(firstURL.lastPathComponent)")
                }
            }
        }

        let total = stacks.reduce(0) { $0 + $1.t }
        context.log("Concatenating \(sorted.count) files -> \(total) total along axis 0")

        // Metadata from the first file's OME-XML only (as the Python code does).
        var meta = ImageMetadata(channelNames: [])
        meta.physicalSizeXUnit = nil; meta.physicalSizeYUnit = nil
        meta.physicalSizeZUnit = nil; meta.timeIncrementUnit = nil
        if let xml = ref.omeXML, let px = OMEXML.parse(xml) {
            let a = px.attributes
            meta.physicalSizeX = a["PhysicalSizeX"].flatMap(Double.init)
            meta.physicalSizeY = a["PhysicalSizeY"].flatMap(Double.init)
            meta.physicalSizeZ = a["PhysicalSizeZ"].flatMap(Double.init)
            meta.timeIncrement = a["TimeIncrement"].flatMap(Double.init)
            meta.physicalSizeXUnit = a["PhysicalSizeXUnit"]
            meta.physicalSizeYUnit = a["PhysicalSizeYUnit"]
            meta.physicalSizeZUnit = a["PhysicalSizeZUnit"]
            meta.timeIncrementUnit = a["TimeIncrementUnit"]
            let names = px.channelNames.compactMap { $0 }.filter { !$0.isEmpty }
            if !names.isEmpty { meta.channelNames = names }
        }

        let sameType = stacks.allSatisfy { $0.sampleType == ref.sampleType }
        let outType: SampleType = sameType ? ref.sampleType : .float32
        let writer = try OMETIFFWriter(url: output, t: total, c: ref.c, z: ref.z, y: ref.y, x: ref.x,
                                       type: outType, metadata: meta, bigTIFF: true)
        for (k, s) in stacks.enumerated() {
            try context.checkCancelled()
            let buffer = Volume(c: s.c, z: s.z, y: s.y, x: s.x, type: s.sampleType)
            let converted = sameType ? buffer : Volume(c: s.c, z: s.z, y: s.y, x: s.x, type: .float32)
            for ti in 0..<s.t {
                try context.checkCancelled()
                try s.readFrame(ti, into: buffer)
                if !sameType { convertToFloat(buffer, into: converted) }
                try writer.writeVolume(converted)
            }
            context.progress("Concatenating", k + 1, stacks.count)
        }
        try writer.finish()
        context.log("Done. Output: \(output.path)")
    }

    static func convertToFloat(_ v: Volume, into out: Volume) {
        let dst = out.storage.raw.assumingMemoryBound(to: Float.self)
        for plane in 0..<v.planeCount {
            let base = plane * v.planeElements
            for i in 0..<v.planeElements { dst[base + i] = v.sample(plane: plane, index: i) }
        }
    }
}
