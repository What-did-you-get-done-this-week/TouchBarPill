import CoreGraphics
import Foundation

/// Grayscale Touch Bar frame. Row 0 is the top of the picture the strip shows.
struct LumaBuffer: Equatable {
    var width: Int
    var height: Int
    /// Length is `width * height`. 0 is black, 255 is white.
    var samples: [UInt8]
}

/// Locates the Control Strip brightness and volume buttons in a mirrored Touch Bar frame.
///
/// The strip is a picture, not a list of controls. This scans that picture for
/// the display-brightness sun sitting beside the speaker. Each slot is one
/// button wide and stops at the midpoint between them, so scroll on one does
/// not hit the other.
///
/// A missing sun, a sun that is not next to a speaker, or two equally close
/// pairs returns nil. Callers treat that as a no-op instead of guessing.
enum BrightnessGlyph {
    /// Normalized image rect. Origin is the top-left; x grows right, y grows down.
    /// One button wide, centered on the sun, ending at the midpoint toward the speaker.
    static func brightnessSlot(in buffer: LumaBuffer) -> CGRect? {
        guard let pair = controlPair(in: buffer) else { return nil }
        return buttonSlot(
            centerX: pair.sun.midX,
            pitch: pair.pitch,
            width: buffer.width,
            height: buffer.height,
            excludeX: pair.speaker.midX
        )
    }

    /// One button wide, centered on the speaker beside the sun.
    /// Ends at the midpoint toward the sun so the brightness button is outside it.
    static func volumeSlot(in buffer: LumaBuffer) -> CGRect? {
        guard let pair = controlPair(in: buffer) else { return nil }
        return buttonSlot(
            centerX: pair.speaker.midX,
            pitch: pair.pitch,
            width: buffer.width,
            height: buffer.height,
            excludeX: pair.sun.midX
        )
    }

    private static func controlPair(in buffer: LumaBuffer) -> Pair? {
        let width = buffer.width
        let height = buffer.height
        guard width >= 16, height >= 8, buffer.samples.count == width * height else { return nil }

        var maxV = 0
        for sample in buffer.samples where Int(sample) > maxV {
            maxV = Int(sample)
        }
        guard maxV >= 190 else { return nil }
        let threshold = max(136, maxV - 100)

        var brightCount = 0
        var ink = [Bool](repeating: false, count: width)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where Int(buffer.samples[row + x]) >= threshold {
                ink[x] = true
                brightCount += 1
            }
        }
        let area = width * height
        guard brightCount >= 12, brightCount * 5 < area else { return nil }

        let maxHole = max(2, (height * 30) / 100)
        var runs: [(Int, Int)] = []
        var x = 0
        while x < width {
            while x < width && !ink[x] { x += 1 }
            if x >= width { break }
            let start = x
            var last = x
            while x < width {
                if ink[x] {
                    last = x
                    x += 1
                    continue
                }
                var j = x
                while j < width && !ink[j] { j += 1 }
                if j < width && (j - x) <= maxHole {
                    x = j
                    continue
                }
                break
            }
            runs.append((start, last))
        }

        let icons = runs.compactMap { icon(from: $0.0, through: $0.1, buffer: buffer, threshold: threshold) }
        let suns = icons.filter(isSun)
        let speakers = icons.filter(isSpeaker)
        guard !suns.isEmpty, !speakers.isEmpty else { return nil }

        var pairs: [Pair] = []
        for sun in suns {
            for speaker in speakers {
                let overlapTop = max(sun.minY, speaker.minY)
                let overlapBottom = min(sun.maxY, speaker.maxY)
                guard overlapBottom - overlapTop + 1 > min(sun.bh, speaker.bh) / 3 else { continue }
                let heightRatio = Double(min(sun.bh, speaker.bh)) / Double(max(sun.bh, speaker.bh))
                guard heightRatio >= 0.55 else { continue }
                let pitch = abs(sun.midX - speaker.midX)
                guard pitch >= Double(height) * 0.55, pitch <= Double(height) * 3.2 else { continue }
                let gap: Int
                if sun.midX < speaker.midX {
                    gap = speaker.minX - sun.maxX
                } else {
                    gap = sun.minX - speaker.maxX
                }
                // Glyphs sit inside buttons, so the ink gap can be wider than the
                // bar is tall. Center pitch above already rejects a distant pair.
                guard gap >= 1, gap <= height * 3 else { continue }
                pairs.append(Pair(sun: sun, speaker: speaker, pitch: pitch))
            }
        }
        pairs.sort { $0.pitch < $1.pitch }
        guard let best = pairs.first else { return nil }
        if pairs.count > 1 {
            let other = pairs[1]
            let differentSun = abs(other.sun.midX - best.sun.midX) > 1.5
            if differentSun && other.pitch < best.pitch * 1.25 {
                return nil
            }
        }
        return best
    }

    private struct Pair {
        var sun: Icon
        var speaker: Icon
        var pitch: Double
    }

    /// One pitch wide, centered on `centerX`, excluding the other glyph's center.
    private static func buttonSlot(
        centerX: Double,
        pitch: Double,
        width: Int,
        height: Int,
        excludeX: Double
    ) -> CGRect? {
        let minX = centerX - pitch / 2
        let inset = Double(height) * 0.04
        let rect = CGRect(
            x: minX / Double(width),
            y: inset / Double(height),
            width: pitch / Double(width),
            height: (Double(height) - inset * 2) / Double(height)
        )
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0.012, clamped.height > 0.5 else { return nil }
        let other = excludeX / Double(width)
        guard other < clamped.minX - 0.004 || other > clamped.maxX + 0.004 else { return nil }
        return clamped
    }

    /// Slot to hit-test while the strip is open.
    ///
    /// Hovering the brightness button (and the system control that replaces it)
    /// wipes the sun and speaker out of the frame, so a fresh scan returns nil
    /// exactly when the pointer is on that button. Keep the last slot when the
    /// same patch of the picture is still lit. A dark patch means the strip
    /// moved on; drop it instead of scrolling whatever landed there.
    static func latchedSlot(detected: CGRect?, previous: CGRect?, buffer: LumaBuffer) -> CGRect? {
        if let detected { return detected }
        guard let previous, slotStillMarked(previous, in: buffer) else { return nil }
        return previous
    }

    /// Icon or highlight ink still occupies the latched button.
    static func slotStillMarked(_ slot: CGRect, in buffer: LumaBuffer) -> Bool {
        let width = buffer.width
        let height = buffer.height
        guard width > 1, height > 1, buffer.samples.count == width * height else { return false }
        let clamped = slot.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return false }
        let x0 = max(0, min(width - 1, Int((clamped.minX * CGFloat(width)).rounded(.down))))
        let x1 = max(x0, min(width - 1, Int((clamped.maxX * CGFloat(width)).rounded(.up)) - 1))
        let y0 = max(0, min(height - 1, Int((clamped.minY * CGFloat(height)).rounded(.down))))
        let y1 = max(y0, min(height - 1, Int((clamped.maxY * CGFloat(height)).rounded(.up)) - 1))
        var bright = 0
        var count = 0
        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 {
                count += 1
                if buffer.samples[row + x] >= 140 { bright += 1 }
            }
        }
        return bright >= 24 && bright * 50 >= count
    }

    private struct Icon {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var hSym: Double
        var vSym: Double
        var cxOff: Double
        var litSectors: Int
        var centerDensity: Double
        var annulusDensity: Double
        var midX: Double { Double(minX + maxX) / 2 }
        var bw: Int { maxX - minX + 1 }
        var bh: Int { maxY - minY + 1 }
    }

    private static func icon(from x0: Int, through x1: Int, buffer: LumaBuffer, threshold: Int) -> Icon? {
        let width = buffer.width
        let height = buffer.height
        func bright(_ x: Int, _ y: Int) -> Bool {
            Int(buffer.samples[y * width + x]) >= threshold
        }

        var minX = x1
        var maxX = x0
        var minY = height
        var maxY = -1
        var count = 0
        var sumX = 0.0
        for y in 0..<height {
            for x in x0...x1 where bright(x, y) {
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                sumX += Double(x)
            }
        }
        guard count >= 10, maxY >= minY else { return nil }
        let bw = maxX - minX + 1
        let bh = maxY - minY + 1
        guard bh >= max(6, (height * 22) / 100), bw >= 4, bw * 2 < width else { return nil }

        var hMatch = 0
        var hTotal = 0
        var vMatch = 0
        var vTotal = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let on = bright(x, y)
                let mirrorX = bright(minX + maxX - x, y)
                if on || mirrorX {
                    hTotal += 1
                    if on == mirrorX { hMatch += 1 }
                }
                let mirrorY = bright(x, minY + maxY - y)
                if on || mirrorY {
                    vTotal += 1
                    if on == mirrorY { vMatch += 1 }
                }
            }
        }
        let hSym = hTotal > 0 ? Double(hMatch) / Double(hTotal) : 0
        let vSym = vTotal > 0 ? Double(vMatch) / Double(vTotal) : 0
        let cxOff = (sumX / Double(count) - Double(minX + maxX) / 2) / Double(bw)

        let midX = Double(minX + maxX) / 2
        let midY = Double(minY + maxY) / 2
        let rx = Double(bw) / 2
        let ry = Double(bh) / 2
        var sectorBright = [Int](repeating: 0, count: 8)
        var sectorTotal = [Int](repeating: 0, count: 8)
        var centerBright = 0
        var centerTotal = 0
        var annulusBright = 0
        var annulusTotal = 0
        if rx > 0.5, ry > 0.5 {
            for y in minY...maxY {
                for x in minX...maxX {
                    let nx = (Double(x) - midX) / rx
                    let ny = (Double(y) - midY) / ry
                    let radius = hypot(nx, ny)
                    let on = bright(x, y)
                    if radius < 0.42 {
                        centerTotal += 1
                        if on { centerBright += 1 }
                    } else if radius >= 0.58 && radius <= 1.12 {
                        annulusTotal += 1
                        if on { annulusBright += 1 }
                        var angle = atan2(ny, nx)
                        if angle < 0 { angle += 2 * Double.pi }
                        let sector = min(7, Int(angle / (2 * Double.pi) * 8))
                        sectorTotal[sector] += 1
                        if on { sectorBright[sector] += 1 }
                    }
                }
            }
        }
        var lit = 0
        for sector in 0..<8 where sectorTotal[sector] > 0 {
            if Double(sectorBright[sector]) / Double(sectorTotal[sector]) >= 0.18 {
                lit += 1
            }
        }
        let centerDensity = centerTotal > 0 ? Double(centerBright) / Double(centerTotal) : 0
        let annulusDensity = annulusTotal > 0 ? Double(annulusBright) / Double(annulusTotal) : 0
        return Icon(
            minX: minX, maxX: maxX, minY: minY, maxY: maxY,
            hSym: hSym, vSym: vSym, cxOff: cxOff,
            litSectors: lit, centerDensity: centerDensity, annulusDensity: annulusDensity
        )
    }

    /// Display-brightness sun: nearly mirror-symmetric, a bright core, and rays
    /// rather than a solid disk.
    private static func isSun(_ icon: Icon) -> Bool {
        let aspect = Double(icon.bw) / Double(max(icon.bh, 1))
        return icon.hSym >= 0.72 && icon.vSym >= 0.70 && abs(icon.cxOff) <= 0.14
            && icon.litSectors >= 5 && icon.centerDensity >= 0.28
            && icon.annulusDensity >= 0.06 && icon.annulusDensity <= 0.62
            && aspect >= 0.55 && aspect <= 1.45
    }

    /// Speaker: vertically symmetric, horizontally not, mass on the cone side.
    /// Either cone-left (the usual Control Strip icon) or cone-right.
    private static func isSpeaker(_ icon: Icon) -> Bool {
        let aspect = Double(icon.bw) / Double(max(icon.bh, 1))
        return icon.hSym <= 0.48 && icon.vSym >= 0.68 && abs(icon.cxOff) >= 0.03
            && aspect >= 0.75 && aspect <= 2.5
    }
}
