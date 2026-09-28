import Foundation

/// A title's outline: everything within `radius` pixels of its drawn letters, with a smooth edge.
/// Worked out from the letters' pixels (a Euclidean distance transform), so round dots, periods
/// and emoji get a full outline; a stroke twice as wide as the outline leaves holes wherever it is
/// wider than a part is round.
enum TitleOutline {
    /// Fainter pixels are not letters: antialiasing specks and an emoji's soft drop shadow would
    /// each grow a disc of their own.
    static let ink: UInt8 = 32

    /// Coverage (0–255) of the outline for each pixel of an RGBA image whose alpha is at byte 3.
    static func coverage(of pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, radius: Double) -> [UInt8] {
        let count = width*height
        var result = [UInt8](repeating:0,count:count)
        guard count > 0, radius > 0 else { return result }
        // Only distances up to just past the outline matter; anything farther is "no letter near".
        let reach = Int(ceil(radius))+3, far = Double(reach*reach)+1
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[y*bytesPerRow+x*4+3] }
        // 1. Each column: squared distance to the nearest letter pixel above or below, and its row.
        var columnDistance = [Double](repeating:far,count:count), nearestRow = [Int32](repeating:-1,count:count)
        for x in 0..<width {
            var last = -1
            for y in 0..<height {
                if alpha(x,y) >= ink { last = y }
                if last >= 0, y-last <= reach { let d = Double(y-last); columnDistance[y*width+x] = d*d; nearestRow[y*width+x] = Int32(last) }
            }
            last = -1
            for y in stride(from:height-1,through:0,by:-1) {
                if alpha(x,y) >= ink { last = y }
                if last >= 0, last-y <= reach {
                    let d = Double(last-y), i = y*width+x
                    if d*d < columnDistance[i] { columnDistance[i] = d*d; nearestRow[i] = Int32(last) }
                }
            }
        }
        // 2. Each row: the lower envelope of the columns' parabolas (Felzenszwalb & Huttenlocher),
        // giving the nearest letter pixel in the whole image.
        var nearest = [Int32](repeating:-1,count:count), distance = [Double](repeating:far,count:count)
        var sites = [Int](repeating:0,count:width), bounds = [Double](repeating:0,count:width+1)
        for y in 0..<height {
            let row = y*width
            var k = -1
            for q in 0..<width where columnDistance[row+q] < far {
                let fq = columnDistance[row+q]+Double(q*q)
                var s = -Double.infinity
                while k >= 0 {
                    let p = sites[k]
                    s = (fq-(columnDistance[row+p]+Double(p*p)))/Double(2*(q-p))
                    if s > bounds[k] { break }
                    k -= 1
                }
                k += 1; sites[k] = q; bounds[k] = k == 0 ? -Double.infinity : s; bounds[k+1] = .infinity
            }
            guard k >= 0 else { continue }
            var j = 0
            for x in 0..<width {
                while bounds[j+1] < Double(x) { j += 1 }
                let p = sites[j], dx = Double(x-p), squared = dx*dx+columnDistance[row+p]
                if squared < far { distance[row+x] = squared; nearest[row+x] = Int32(Int(nearestRow[row+p])*width+p) }
            }
        }
        // 3. Coverage. Well inside the outline it is full. Near its rim, a letter's edge lies inside
        // an edge pixel by how much of that pixel is covered, and the nearest pixel centre is not
        // always the nearest edge (a faint pixel can tie with a solid one), so the pixels around
        // the nearest one, and around each neighbour's nearest, are all weighed. Where two
        // letters' outlines meet from opposite sides, each covers its own part of the pixel.
        let full = max(0,radius-1)
        var candidates: [(Double,Double,Double)] = []                         // edge distance, direction
        candidates.reserveCapacity(64)
        for y in 0..<height {
            for x in 0..<width {
                let i = y*width+x
                guard nearest[i] >= 0 else { continue }
                if distance[i].squareRoot() <= full { result[i] = 255; continue }
                var bestEdge = Double.infinity, bestX = 0.0, bestY = 0.0
                candidates.removeAll(keepingCapacity:true)
                func weigh(around site: Int32, within window: Int) {
                    let sx = Int(site)%width, sy = Int(site)/width
                    for qy in max(0,sy-window)...min(height-1,sy+window) {
                        for qx in max(0,sx-window)...min(width-1,sx+window) {
                            let a = alpha(qx,qy)
                            guard a >= ink else { continue }
                            let dx = Double(qx-x), dy = Double(qy-y)
                            let edge = (dx*dx+dy*dy).squareRoot()-(Double(a)/255-0.5)
                            candidates.append((edge,dx,dy))
                            if edge < bestEdge { bestEdge = edge; bestX = dx; bestY = dy }
                        }
                    }
                }
                weigh(around:nearest[i],within:2)
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let n = nearest[ny*width+nx]
                    if n >= 0, n != nearest[i] { weigh(around:n,within:1) }
                }
                func covered(_ edge: Double) -> Double { max(0,min(1,radius+0.5-edge)) }
                var opposite = 0.0
                let bestLength = (bestX*bestX+bestY*bestY).squareRoot()
                for (edge,dx,dy) in candidates where dx*bestX+dy*bestY < -0.5*bestLength*(dx*dx+dy*dy).squareRoot() {
                    opposite = max(opposite,covered(edge))
                }
                result[i] = UInt8(min(1,covered(bestEdge)+opposite)*255+0.5)
            }
        }
        return result
    }
}
