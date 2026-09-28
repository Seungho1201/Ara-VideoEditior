import AppKit
import CoreImage
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

/// Outlines, shadows and titles drawn at the output's resolution.
final class TitleEffectsRenderTests: XCTestCase {
    /// An image as top-down RGBA bytes (row 0 is the top of the picture).
    private struct Bitmap {
        let width: Int, height: Int, bytes: [UInt8]
        init(_ image: CIImage, scale: CGFloat = 1) {
            let scaled = scale == 1 ? image : image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let extent = scaled.extent.integral
            width = Int(extent.width); height = Int(extent.height)
            let cg = CIContext().createCGImage(scaled,from:extent)!
            var data = [UInt8](repeating:0,count:width*height*4)
            let context = CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
            bytes = data
        }
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y*width+x)*4; return (Int(bytes[i]),Int(bytes[i+1]),Int(bytes[i+2]),Int(bytes[i+3]))
        }
        /// Centre of the pixels matching `test`, in pixels from the top left.
        func centroid(_ test: ((r: Int, g: Int, b: Int, a: Int)) -> Bool) -> CGPoint? {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in 0..<height { for x in 0..<width where test(pixel(x,y)) { sx += Double(x); sy += Double(y); n += 1 } }
            return n > 0 ? CGPoint(x:sx/n,y:sy/n) : nil
        }
        var edgeAlpha: Int {
            var sum = 0
            for x in 0..<width { sum += pixel(x,0).a+pixel(x,height-1).a }
            for y in 0..<height { sum += pixel(0,y).a+pixel(width-1,y).a }
            return sum
        }
        /// Bounds of the pixels more than half opaque.
        var inkBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
            var box: (Int,Int,Int,Int)?
            for y in 0..<height { for x in 0..<width where pixel(x,y).a > 128 {
                box = box.map { (min($0.0,x),min($0.1,y),max($0.2,x),max($0.3,y)) } ?? (x,y,x,y)
            } }
            return box.map { (minX:$0.0,minY:$0.1,maxX:$0.2,maxY:$0.3) }
        }
        /// Separate pieces of more-than-half-opaque pixels.
        var pieces: Int {
            var seen = [Bool](repeating:false,count:width*height), count = 0
            for start in 0..<width*height where !seen[start] && bytes[start*4+3] > 128 {
                count += 1; seen[start] = true
                var stack = [start]
                while let i = stack.popLast() {
                    let x = i%width, y = i/width
                    for (nx,ny) in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                        let j = ny*width+nx
                        if !seen[j] && bytes[j*4+3] > 128 { seen[j] = true; stack.append(j) }
                    }
                }
            }
            return count
        }
        /// Pixels part-way between clear and opaque: the soft rim around the letters.
        var softPixels: Int { (0..<width*height).filter { bytes[$0*4+3] > 20 && bytes[$0*4+3] < 235 }.count }
    }
    private func title(_ text: String = "Ara gjpq 한글", size: Double = 100, _ change: (inout ClipStyle) -> Void = { _ in }) -> ClipStyle {
        var style = ClipStyle(); style.text = text; style.fontSize = size; change(&style); return style
    }

    func testTitlesWithoutEffectsKeepTheirRaster() throws {
        let plain = title()
        let reference = Bitmap(try FrameRenderer.textImage(plain))
        // Settings of an effect that is switched off change nothing.
        let off = title { $0.outlineRed = 1; $0.shadowDistance = 30; $0.shadowBlur = 0; $0.shadowAngle = -90; $0.shadowGreen = 1 }
        let unchanged = Bitmap(try FrameRenderer.textImage(off,scale:1))
        XCTAssertEqual(unchanged.bytes,reference.bytes); XCTAssertEqual(unchanged.width,reference.width)
    }

    func testOutlineSurroundsTheLettersWithoutCoveringThem() throws {
        let plainImage = try FrameRenderer.textImage(title())
        let outlinedImage = try FrameRenderer.textImage(title { $0.outlineWidth = 6; $0.outlineRed = 1 })
        let plain = Bitmap(plainImage), outlined = Bitmap(outlinedImage)
        // The image grows by the same margin on every side, so the letters stay where they were.
        let dx = (outlined.width-plain.width)/2, dy = (outlined.height-plain.height)/2
        XCTAssertGreaterThanOrEqual(dx,6); XCTAssertEqual(outlined.width-plain.width,2*dx); XCTAssertEqual(outlined.height-plain.height,2*dy)
        var red = 0, redOutside = 0, covered = 0
        for y in 0..<outlined.height { for x in 0..<outlined.width {
            let p = outlined.pixel(x,y)
            let inside = x >= dx && y >= dy && x-dx < plain.width && y-dy < plain.height ? plain.pixel(x-dx,y-dy).a : 0
            if p.a > 200 && p.r > 200 && p.g < 60 { red += 1; if inside < 128 { redOutside += 1 } }
            if inside == 255 && !(p.r > 245 && p.g > 245 && p.b > 245) { covered += 1 }
        } }
        XCTAssertGreaterThan(red,2000,"a red outline is drawn")
        XCTAssertGreaterThan(Double(redOutside)/Double(red),0.97,"the outline is outside the letters")
        XCTAssertEqual(covered,0,"the letters are drawn over their outline, in their own colour")
        XCTAssertEqual(outlined.edgeAlpha,0)
    }

    func testShadowFallsAtItsAngle() throws {
        func offset(_ angle: Double) throws -> CGPoint {
            let image = Bitmap(try FrameRenderer.textImage(title("Shadow") {
                $0.shadowOpacity = 1; $0.shadowDistance = 20; $0.shadowBlur = 0; $0.shadowAngle = angle; $0.shadowRed = 1
            }))
            XCTAssertEqual(image.edgeAlpha,0,"shadow at \(angle)° is not cut off")
            let letters = try XCTUnwrap(image.centroid { $0.a > 250 && $0.g > 250 })
            let shadow = try XCTUnwrap(image.centroid { $0.a > 250 && $0.r > 250 && $0.g < 10 })
            return CGPoint(x:shadow.x-letters.x,y:shadow.y-letters.y)
        }
        // Screen directions: 45° is down and to the right, 90° straight down, 180° to the left.
        let downRight = try offset(45), down = try offset(90), left = try offset(180), up = try offset(-90)
        XCTAssertGreaterThan(downRight.x,4); XCTAssertGreaterThan(downRight.y,4)
        XCTAssertGreaterThan(down.y,8); XCTAssertLessThan(abs(down.x),2)
        XCTAssertLessThan(left.x,-8); XCTAssertLessThan(abs(left.y),2)
        XCTAssertLessThan(up.y,-8); XCTAssertLessThan(abs(up.x),2)
        // Opacity carries into the shadow: where only the shadow is, a 40 % shadow is 40 % opaque.
        func shadowAlpha(_ opacity: Double) throws -> Int {
            func style(_ o: Double) -> ClipStyle { title("Shadow") { $0.shadowOpacity = o; $0.shadowDistance = 30; $0.shadowBlur = 0; $0.shadowAngle = 90 } }
            let lit = Bitmap(try FrameRenderer.textImage(style(opacity)))
            let letters = Bitmap(try FrameRenderer.textImage(style(0),scale:1))      // same letters, no shadow: a smaller image
            let dx = (lit.width-letters.width)/2, dy = (lit.height-letters.height)/2
            var strongest = 0
            for y in 0..<lit.height { for x in 0..<lit.width {
                let inside = x >= dx && y >= dy && x-dx < letters.width && y-dy < letters.height && letters.pixel(x-dx,y-dy).a > 0
                if !inside { strongest = max(strongest,lit.pixel(x,y).a) }
            } }
            return strongest
        }
        XCTAssertEqual(try shadowAlpha(0.4),102,accuracy:3)
        XCTAssertEqual(try shadowAlpha(1),255,accuracy:1)
        // Only the shadow is translucent: the letters over it stay fully opaque and white.
        let faint = Bitmap(try FrameRenderer.textImage(title("Shadow") { $0.shadowOpacity = 0.4; $0.shadowDistance = 30; $0.shadowBlur = 4; $0.shadowAngle = 90 }))
        let letters = Bitmap(try FrameRenderer.textImage(title("Shadow")))
        let dx = (faint.width-letters.width)/2, dy = (faint.height-letters.height)/2
        var solid = 0, faded = 0
        for y in 0..<letters.height { for x in 0..<letters.width where letters.pixel(x,y).a == 255 {
            solid += 1
            let p = faint.pixel(x+dx,y+dy)
            if p.a < 254 || p.r < 250 || p.g < 250 || p.b < 250 { faded += 1 }
        } }
        XCTAssertGreaterThan(solid,1000); XCTAssertEqual(faded,0,"letters stay opaque over a 40 % shadow")
    }

    func testFourKShadowsAreTheFullHDShadowAtTwiceThePixels() throws {
        // Distance and blur are in the 1080 basis: at 4K they cover twice the pixels.
        func offset(_ scale: CGFloat, blur: Double) throws -> (CGPoint,Int) {
            let style = title("Shadow") { $0.shadowOpacity = 1; $0.shadowDistance = 20; $0.shadowBlur = blur; $0.shadowAngle = 45; $0.shadowRed = 1 }
            let image = Bitmap(try FrameRenderer.textImage(style,scale:scale),scale:scale)
            let letters = try XCTUnwrap(image.centroid { $0.a > 250 && $0.g > 250 })
            let shadow = try XCTUnwrap(image.centroid { $0.a > 250 && $0.r > 250 && $0.g < 10 })
            return (CGPoint(x:shadow.x-letters.x,y:shadow.y-letters.y),image.softPixels)
        }
        let (hd,_) = try offset(1,blur:0), (uhd,_) = try offset(2,blur:0)
        XCTAssertEqual(uhd.x,hd.x*2,accuracy:1.5); XCTAssertEqual(uhd.y,hd.y*2,accuracy:1.5)
        XCTAssertGreaterThan(hd.x,8)
        // A blurred shadow's soft band is twice as wide at 4K: about four times the soft pixels
        // (twice the length, twice the width), where letters alone only double.
        let (_,softHD) = try offset(1,blur:8), (_,softUHD) = try offset(2,blur:8)
        XCTAssertGreaterThan(Double(softUHD)/Double(softHD),3.2)
    }

    func testTheShadowKeepsItsScreenDirectionWhenTheTitleIsRotated() throws {
        for rotation in [0.0,90,-135,180] {
            let style = title("Turn") { $0.rotation = rotation; $0.shadowOpacity = 1; $0.shadowDistance = 20; $0.shadowBlur = 0; $0.shadowRed = 1 }
            let image = try FrameRenderer.textImage(style)
            let canvas = CGRect(x:0,y:0,width:1920,height:1080)
            let geometry = VisualGeometry(sourceSize:image.extent.size,canvasSize:canvas.size,style:style,isText:true)
            let placed = Bitmap(image.transformed(by:geometry.renderTransform).composited(over:CIImage(color:.clear).cropped(to:canvas)).cropped(to:canvas))
            let letters = try XCTUnwrap(placed.centroid { $0.a > 250 && $0.g > 250 })
            let shadow = try XCTUnwrap(placed.centroid { $0.a > 250 && $0.r > 250 && $0.g < 10 })
            XCTAssertGreaterThan(shadow.x-letters.x,4,"down and to the right on screen at \(rotation)°")
            XCTAssertGreaterThan(shadow.y-letters.y,4,"down and to the right on screen at \(rotation)°")
        }
    }

    func testOutlinesCloseAroundRoundDotsAndEmoji() throws {
        // A stroke wider than a round dot is thick leaves a see-through ring around it. Any clear
        // pixel the border cannot reach through clear pixels is enclosed; enclosed pixels are only
        // right where every letter is farther away than the outline's width (a pocket between
        // letters), never close to one.
        let cases: [(String,Double,Double)] = [("Avenir-Heavy",72,14),("Avenir-Heavy",72,20),("Georgia",40,10),("Didot",150,20)]
        for (font,size,width) in cases where FontLibrary.isAvailable(font) {
            for scale in [1.0,2] {
                let style = title("i.!:;ij ï",size:size) { $0.fontName = font; $0.outlineWidth = width }
                let image = Bitmap(try FrameRenderer.textImage(style,scale:scale),scale:scale)
                var plainStyle = style; plainStyle.outlineWidth = 0
                let plain = Bitmap(try FrameRenderer.textImage(plainStyle,scale:scale),scale:scale)
                let dx = (image.width-plain.width)/2, dy = (image.height-plain.height)/2
                var reached = [Bool](repeating:false,count:image.width*image.height), queue: [Int] = []
                func visit(_ x: Int, _ y: Int) {
                    guard x >= 0, y >= 0, x < image.width, y < image.height, !reached[y*image.width+x], image.pixel(x,y).a < 40 else { return }
                    reached[y*image.width+x] = true; queue.append(y*image.width+x)
                }
                for x in 0..<image.width { visit(x,0); visit(x,image.height-1) }
                for y in 0..<image.height { visit(0,y); visit(image.width-1,y) }
                while let i = queue.popLast() { let x = i%image.width, y = i/image.width; visit(x+1,y); visit(x-1,y); visit(x,y+1); visit(x,y-1) }
                let near = Int(width*scale-1.5)
                var holes = 0
                for i in 0..<image.width*image.height where !reached[i] && image.bytes[i*4+3] < 40 {
                    let x = i%image.width-dx, y = i/image.width-dy
                    search: for oy in -near...near { for ox in -near...near where ox*ox+oy*oy <= near*near {
                        let px = x+ox, py = y+oy
                        if px >= 0, py >= 0, px < plain.width, py < plain.height, plain.pixel(px,py).a > 128 { holes += 1; break search }
                    } }
                }
                XCTAssertEqual(holes,0,"\(font) \(size) pt, outline \(width), \(scale)×")
            }
        }
        // Colour emoji are pictures, not outlines: they get an outline too, one ring of even width.
        // (Their nearly clear specks and soft drop shadow are not letters: counted as ink they
        // grew blobs off the corners and a thicker rim below.)
        for (size,width) in [(120.0,10.0),(40,4)] {
            let emoji = Bitmap(try FrameRenderer.textImage(title("😀",size:size) { $0.outlineWidth = width; $0.outlineRed = 1 }))
            let bare = Bitmap(try FrameRenderer.textImage(title("😀",size:size)))
            let red = (0..<emoji.width*emoji.height).filter { let i = $0*4; return emoji.bytes[i+3] > 250 && emoji.bytes[i] > 250 && emoji.bytes[i+1] < 10 && emoji.bytes[i+2] < 10 }.count
            XCTAssertGreaterThan(red,Int(width*size),"an outline around the emoji")
            XCTAssertEqual(emoji.pieces,1,"one piece at \(size) pt")
            let a = try XCTUnwrap(bare.inkBox), b = try XCTUnwrap(emoji.inkBox), offset = (emoji.width-bare.width)/2
            for grown in [a.minX+offset-b.minX,a.minY+offset-b.minY,b.maxX-(a.maxX+offset),b.maxY-(a.maxY+offset)] {
                XCTAssertEqual(Double(grown),width,accuracy:1,"even outline at \(size) pt")
            }
        }
    }

    func testOutlineIsTheTrueOffsetOfTheDrawnLetters() throws {
        // Reference: the drawn letters enlarged 4× (bilinear), cut at half coverage, grown by 4×
        // the width, averaged back. A pixel far below it is a notch (a faint edge pixel taken
        // for the edge) or a seam (two letters' outlines meeting, each counted alone).
        for (font,text) in [("HelveticaNeue-Bold","Hello, it's ij!"),("Georgia","illumination Ill")] where FontLibrary.isAvailable(font) {
            for width in [2.0,5] {
                let plain = title(text,size:60) { $0.fontName = font }
                var outlined = plain; outlined.outlineWidth = width
                let ours = Bitmap(try FrameRenderer.textImage(outlined)), big = Bitmap(try FrameRenderer.textImage(plain),scale:4)
                let W = big.width, H = big.height, r = width*4, reach = Int(ceil(r))
                var nearestInRow = [Double](repeating:.infinity,count:W*H)
                for y in 0..<H {
                    var last = -1_000_000
                    for x in 0..<W { if big.pixel(x,y).a >= 128 { last = x }; nearestInRow[y*W+x] = Double(x-last) }
                    last = 1_000_000
                    for x in stride(from:W-1,through:0,by:-1) { if big.pixel(x,y).a >= 128 { last = x }; nearestInRow[y*W+x] = min(nearestInRow[y*W+x],Double(last-x)) }
                }
                let w = W/4, h = H/4, dx = (ours.width-w)/2, dy = (ours.height-h)/2
                var thin = 0, thick = 0
                for y in 0..<h { for x in 0..<w {
                    var hits = 0
                    for sy in y*4..<y*4+4 { for sx in x*4..<x*4+4 {
                        for oy in -reach...reach where sy+oy >= 0 && sy+oy < H {
                            let d = nearestInRow[(sy+oy)*W+sx]
                            if d*d+Double(oy*oy) <= r*r { hits += 1; break }
                        }
                    } }
                    let truth = Double(hits)/16, got = Double(ours.pixel(x+dx,y+dy).a)/255
                    if got < truth-0.35 { thin += 1 }
                    if got > truth+0.35 { thick += 1 }
                } }
                XCTAssertEqual(thin,0,"\(font) outline \(width): pixels well below the true outline")
                XCTAssertLessThanOrEqual(thick,25,"\(font) outline \(width): pixels well above the true outline")
            }
        }
    }

    func testTheLargestEffectsAreNotCutOff() throws {
        for angle in [45.0,135,-90,180] {
            for scale in [1.0,2] {
                let style = title("Wide gjpq\n한글 Title") { $0.outlineWidth = 20; $0.shadowOpacity = 1; $0.shadowDistance = 40; $0.shadowBlur = 40; $0.shadowAngle = angle }
                XCTAssertEqual(Bitmap(try FrameRenderer.textImage(style,scale:scale),scale:scale).edgeAlpha,0,"\(angle)° at \(scale)×")
            }
        }
    }

    func testFourKTitlesAreDrawnAtFourKInThePlaceOfTheFullHDOne() throws {
        for (style,sharp) in [(title(),true),(title { $0.outlineWidth = 5; $0.outlineBlue = 1 },true),(title { $0.outlineWidth = 5; $0.shadowOpacity = 0.8 },false)] {
            let hd = try FrameRenderer.textImage(style), uhd = try FrameRenderer.textImage(style,scale:2)
            // Exactly the same size in the 1080 basis that placement works in.
            XCTAssertEqual(uhd.extent,hd.extent)
            // At 4K pixels: the old way enlarged the 1080 raster; now the edges are drawn at 4K.
            // (A blurred shadow is soft either way.)
            let enlarged = Bitmap(hd,scale:2), native = Bitmap(uhd,scale:2)
            if sharp { XCTAssertLessThan(Double(native.softPixels),Double(enlarged.softPixels)*0.6,"crisper edges at 4K") }
            // And the letters sit in the same place relative to the image centre.
            let a = try XCTUnwrap(enlarged.centroid { $0.a > 128 }), b = try XCTUnwrap(native.centroid { $0.a > 128 })
            XCTAssertEqual(a.x-Double(enlarged.width)/2,b.x-Double(native.width)/2,accuracy:2)
            XCTAssertEqual(a.y-Double(enlarged.height)/2,b.y-Double(native.height)/2,accuracy:2)
        }
    }

    func testFourKTitlesAreLaidOutExactlyAsInFullHD() throws {
        // Laid out at 2× the point size, CoreText rounds each line's height anew (lines drift a
        // few pixels apart) and Apple Color Emoji tracks differently at small sizes (a line of
        // them can stop wrapping). A 4K title is the Full HD layout, rasterised at 4K.
        let titles = [title("One\nTwo\nThree\nFour\nFive\nSix",size:100),
                      title("Party time 🎉🎂🎈🥳 tonight",size:16),
                      title(String(repeating:"🎉",count:90),size:16),
                      title(String(repeating:"Didot gjpq ",count:30),size:61) { $0.fontName = "Didot" }]
        for style in titles {
            let hd = try FrameRenderer.textImage(style), uhd = try FrameRenderer.textImage(style,scale:2)
            XCTAssertEqual(uhd.extent,hd.extent,style.text)
            // The lines sit on the same rows: in 4K pixels, the top and bottom halves of the
            // enlarged Full HD title and of the 4K one line up best with no shift (a new layout at
            // twice the size drifted lines by 2 to 11 pixels, more towards the bottom).
            let a = Bitmap(hd,scale:2), b = Bitmap(uhd,scale:2)
            func rows(_ m: Bitmap) -> [Double] { (0..<m.height).map { y in Double((0..<m.width).reduce(0) { $0+m.pixel($1,y).a }) } }
            let ra = rows(a), rb = rows(b), half = ra.count/2
            for range in [0..<half,half..<ra.count] {
                let best = (-8...8).min { s, t in
                    func cost(_ shift: Int) -> Double { range.reduce(0.0) { $0+abs(ra[$1]-(rb.indices.contains($1+shift) ? rb[$1+shift] : 0)) } }
                    return cost(s) < cost(t)
                }!
                XCTAssertLessThanOrEqual(abs(best),1,"\(style.text.prefix(12).replacingOccurrences(of:"\n",with:"/")) rows \(range) moved by \(best) px")
            }
        }
    }

    @MainActor func testEffectSlidersRedrawThePreviewAsOneUndoStepAndKeepTheBoxOnTheLetters() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var clip = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        clip.style.text = "Outline 한글"
        store.edit("Fixture") { $0.clips = [clip] }
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        let before = try XCTUnwrap(store.previewLayerImage(for:clip)), box = try XCTUnwrap(store.previewSourceSize(for:clip))
        let original = store.project
        XCTAssertEqual(store.previewSourceMargin(for:clip),0)
        // A drag: many values, then release.
        for width in stride(from:1.0,through:8,by:1) { store.updateStyleLive(clip.id,name:"Outline",closesWhenIdle:false) { $0.outlineWidth = width } }
        store.endLiveEdit()
        XCTAssertFalse(store.isBuilding,"redrawn in place, not rebuilt")
        let outlined = store.project
        // A different control mid-run is a step of its own.
        store.updateStyleLive(clip.id,name:"Outline",closesWhenIdle:false) { $0.outlineRed = 1 }
        store.updateStyleLive(clip.id,name:"Shadow",closesWhenIdle:false) { $0.shadowOpacity = 0.6; $0.shadowDistance = 30 }
        store.endLiveEdit()
        let after = try XCTUnwrap(store.previewLayerImage(for:clip))
        XCTAssertGreaterThan(after.extent.width,before.extent.width+60)
        // The transform box still fits the letters; the picture reaches past it by the margin.
        XCTAssertEqual(try XCTUnwrap(store.previewSourceSize(for:clip)),box)
        let margin = store.previewSourceMargin(for:clip)
        XCTAssertEqual(after.extent.width,box.width+2*margin); XCTAssertEqual(after.extent.height,box.height+2*margin)
        store.undo(); XCTAssertEqual(store.project.clips[0].style.shadowOpacity,0); XCTAssertEqual(store.project.clips[0].style.outlineRed,1)
        store.undo(); XCTAssertEqual(store.project,outlined)
        store.undo(); XCTAssertEqual(store.project,original,"the drag was one undo step")
    }
}
