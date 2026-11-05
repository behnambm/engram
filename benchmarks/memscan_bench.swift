// Reproduce the in-memory scan numbers in docs/clipboard-manager-research.md (section 4.3).
//
// Compare the two ways a clipboard manager searches a history held in RAM:
//   - naive: Swift String API (grapheme-cluster aware) over every clip
//   - fast:  UTF-8 bytes + memmem, with early exit
//
// Build: swiftc -O benchmarks/memscan_bench.swift -o /tmp/memscan && /tmp/memscan

import Foundation

let words = (
    "invoice client payment meeting timesheet github branch deploy review schedule lunch "
    + "feedback reminder approve marketing campaign release hotfix spec design sprint retro "
    + "budget contract payroll signature address password api key token"
).split(separator: " ")

struct Clip {
    let id: Int
    let text: String   // what the UI renders
    let lower: String  // what naive search uses
    let bytes: [UInt8] // what fast search uses
}

func makeClips(_ n: Int) -> [Clip] {
    var out: [Clip] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let r = Int.random(in: 0..<100)
        let target = r < 70 ? Int.random(in: 10...120)
            : (r < 95 ? Int.random(in: 200...1500) : Int.random(in: 2000...8000))
        var s = ""
        s.reserveCapacity(target)
        while s.utf8.count < target { s += words.randomElement()! + " " }
        out.append(Clip(id: i, text: s, lower: s.lowercased(), bytes: Array(s.lowercased().utf8)))
    }
    return out
}

@inline(__always)
func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if needle.count > haystack.count { return false }
    return haystack.withUnsafeBufferPointer { h in
        needle.withUnsafeBufferPointer { n in
            memmem(h.baseAddress!, h.count, n.baseAddress!, n.count) != nil
        }
    }
}

func bench(_ label: String, _ body: () -> Int) {
    var samples: [Double] = []
    var rows = 0
    for _ in 0..<60 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        rows = body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
    samples.sort()
    let pad = label.padding(toLength: 52, withPad: " ", startingAt: 0)
    print(pad + String(format: " p50=%8.3fms p95=%8.3fms rows=%d",
                       samples[30], samples[57], rows))
}

let all = makeClips(100_000)
let hot = Array(all.suffix(5_000))
let allBytes = all.reduce(0) { $0 + $1.text.utf8.count + $1.lower.utf8.count }
print("corpus: 100k clips, \(all.reduce(0) { $0 + $1.text.utf8.count } / 1_048_576) MB text, "
      + "\(allBytes / 1_048_576) MB held in RAM\n")

let needleString = "invoice"
let needleBytes = Array(needleString.utf8)

bench("naive: localizedCaseInsensitiveContains, 100k") {
    var n = 0
    for c in all where c.text.localizedCaseInsensitiveContains(needleString) { n += 1 }
    return n
}
bench("naive: prelowered String.contains, 100k") {
    var n = 0
    for c in all where c.lower.contains(needleString) { n += 1 }
    return n
}
bench("fast: memmem, 100k (full scan)") {
    var n = 0
    for c in all where find(c.bytes, needleBytes) { n += 1 }
    return n
}
bench("fast: memmem, 5k (full scan)") {
    var n = 0
    for c in hot where find(c.bytes, needleBytes) { n += 1 }
    return n
}
bench("fast: memmem, 5k (early exit at 50)") {
    var n = 0
    for c in hot where find(c.bytes, needleBytes) {
        n += 1
        if n == 50 { break }
    }
    return n
}
