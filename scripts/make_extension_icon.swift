import AppKit

func makeIcon(size: CGFloat, output: String) {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    // Dark green background — readable against both light and dark Safari toolbars
    NSColor(calibratedRed: 0.10, green: 0.50, blue: 0.30, alpha: 1.0).setFill()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.15, yRadius: size * 0.15)
    path.fill()
    // Centered "V" in white
    let fontSize = size * 0.65
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: "V", attributes: attrs)
    let textSize = str.size()
    let textRect = NSRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    str.draw(in: textRect)
    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("ERROR: png encoding failed for \(output)")
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output) (\(png.count) bytes)")
}

let args = CommandLine.arguments
guard args.count == 3, let sz = Double(args[1]) else {
    print("usage: make-icon <size> <output>")
    exit(1)
}
makeIcon(size: CGFloat(sz), output: args[2])
