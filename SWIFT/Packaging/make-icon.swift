import AppKit
let size: CGFloat = 1024
let src = NSImage(contentsOfFile: "\(CommandLine.arguments[1])")!
let srcRep = NSBitmapImageRep(data: src.tiffRepresentation!)!
// sample blue inside circle top-center
let c = srcRep.colorAt(x: srcRep.pixelsWide/2, y: srcRep.pixelsHigh/8) ?? .systemBlue
let blue = NSColor(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)

let img = NSImage(size: NSSize(width: size, height: size)); img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size-2*inset, height: size-2*inset)
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
  let p = CGMutablePath(); let cx=r.midX, cy=r.midY, a=r.width/2, b=r.height/2; let steps=720
  for i in 0...steps { let t=CGFloat(i)/CGFloat(steps)*2 * .pi
    let x=cx+a*CGFloat(copysign(pow(abs(Double(cos(t))),2.0/Double(n)),Double(cos(t))))
    let y=cy+b*CGFloat(copysign(pow(abs(Double(sin(t))),2.0/Double(n)),Double(sin(t))))
    i==0 ? p.move(to:CGPoint(x:x,y:y)) : p.addLine(to:CGPoint(x:x,y:y)) }
  p.closeSubpath(); return p }
ctx.saveGState(); ctx.addPath(squircle(rect)); ctx.clip()
blue.setFill(); rect.fill(); ctx.restoreGState()
// draw logo (circle+glyph) filling the squircle body so blues merge
src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
img.unlockFocus()
let out="\(CommandLine.arguments[2])"
let rep=NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using:.png, properties:[:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) blue=\(blue)")
