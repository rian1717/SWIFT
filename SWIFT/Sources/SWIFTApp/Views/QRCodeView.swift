import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// A Quick Share–style QR code: round navy dots, rounded finder "eyes", and a
/// center logo, on a white rounded card. Rendered by reading the module matrix
/// from CoreImage and drawing it as vectors (so it scales crisply).
struct QRCodeView: View {
    let payload: String

    /// The card's shape, defined once: the white fill and the border stroke
    /// have to be the same rounded rect, and as two separate literals they
    /// could drift apart without anything failing.
    private static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    var size: CGFloat = 200

    private static var navy: Color { Theme.qrInk }

    var body: some View {
        ZStack {
            if let matrix = Self.matrix(for: payload) {
                Canvas { ctx, sz in Self.draw(matrix, in: ctx, size: sz) }
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit()
                    .padding(size * 0.12).foregroundStyle(Self.navy)
            }
            centerBadge
        }
        .frame(width: size, height: size)
        .padding(Theme.Space.lg)
        .background(.white, in: Self.shape)
        .overlay(
            Self.shape.strokeBorder(.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    private var centerBadge: some View {
        ZStack {
            Circle().fill(Self.navy).frame(width: size * 0.2, height: size * 0.2)
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: size * 0.1, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: Drawing

    private static func draw(_ matrix: [[Bool]], in ctx: GraphicsContext, size: CGSize) {
        let n = matrix.count
        guard n > 0 else { return }
        let m = size.width / CGFloat(n)
        let shading = GraphicsContext.Shading.color(navy)
        let center = CGFloat(n) / 2
        let clearRadius = CGFloat(n) * 0.17   // clear a circle for the center badge

        for r in 0..<n {
            for c in 0..<n where matrix[r][c] {
                if isFinder(r, c, n) { continue }               // eyes drawn separately
                let dr = CGFloat(r) + 0.5 - center
                let dc = CGFloat(c) + 0.5 - center
                if (dr * dr + dc * dc).squareRoot() < clearRadius { continue }
                // Near-solid rounded squares: reads like a normal QR (better
                // scanner reliability) but keeps a soft, modern look.
                let d = m * 0.96
                let rect = CGRect(x: CGFloat(c) * m + (m - d) / 2,
                                  y: CGFloat(r) * m + (m - d) / 2, width: d, height: d)
                ctx.fill(Path(roundedRect: rect, cornerSize: CGSize(width: m * 0.24, height: m * 0.24)),
                         with: shading)
            }
        }

        for (fr, fc) in [(0, 0), (0, n - 7), (n - 7, 0)] {
            drawEye(row: fr, col: fc, m: m, in: ctx)
        }
    }

    private static func isFinder(_ r: Int, _ c: Int, _ n: Int) -> Bool {
        (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7)
    }

    private static func drawEye(row: Int, col: Int, m: CGFloat, in ctx: GraphicsContext) {
        let navyShade = GraphicsContext.Shading.color(navy)
        let outer = CGRect(x: CGFloat(col) * m, y: CGFloat(row) * m, width: 7 * m, height: 7 * m)
        ctx.fill(Path(roundedRect: outer, cornerRadius: m * 2.3), with: navyShade)
        ctx.fill(Path(roundedRect: outer.insetBy(dx: m, dy: m), cornerRadius: m * 1.7),
                 with: .color(.white))
        ctx.fill(Path(roundedRect: outer.insetBy(dx: 2 * m, dy: 2 * m), cornerRadius: m * 1.1),
                 with: navyShade)
    }

    // MARK: Matrix extraction

    private static let ciContext = CIContext()

    // Cache the last matrix — body/Canvas can re-evaluate, and the payload is
    // static per QR, so there's no reason to re-decode the bitmap each redraw.
    private static var cache: (payload: String, matrix: [[Bool]])?

    private static func matrix(for string: String) -> [[Bool]]? {
        if let cache, cache.payload == string { return cache.matrix }
        guard let m = computeMatrix(for: string) else { return nil }
        cache = (string, m)
        return m
    }

    private static func computeMatrix(for string: String) -> [[Bool]]? {
        let qr = CIFilter.qrCodeGenerator()
        qr.message = Data(string.utf8)
        qr.correctionLevel = "H"
        guard let img = qr.outputImage else { return nil }
        let ext = img.extent
        let w = Int(ext.width), h = Int(ext.height)
        guard w > 0, h > 0, let cg = ciContext.createCGImage(img, from: ext) else { return nil }

        var buf = [UInt8](repeating: 0, count: w * h)
        guard let c = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // CGContext row 0 is the bottom; flip to a top-first grid.
        var grid = (0..<h).map { y -> [Bool] in
            let sy = h - 1 - y
            return (0..<w).map { buf[sy * w + $0] < 128 }
        }
        return trimQuietZone(&grid)
    }

    /// Crop the quiet-zone border down to the exact QR matrix.
    private static func trimQuietZone(_ g: inout [[Bool]]) -> [[Bool]] {
        let h = g.count, w = g.first?.count ?? 0
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where g[y][x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return g }
        return (minY...maxY).map { Array(g[$0][minX...maxX]) }
    }
}
