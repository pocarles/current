import XCTest
@testable import TrafficCore

final class SpeedTestTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    // Trimmed from a real `networkQuality -c -M 8` run.
    let sample = Data("""
    {"base_rtt":32.67,"dl_bytes_transferred":804367422,"dl_flows":8,"dl_throughput":994859008,
     "interface_name":"en0","responsiveness":734.58,"ul_bytes_transferred":160956416,"ul_flows":8,
     "ul_throughput":192328416,"il_h2_req_resp":[27.2,25.7],"other":{"ecn_values":{"ecn_disabled":163}}}
    """.utf8)

    func testParsesRealOutputIntoBitsLatencyAndDataUsed() throws {
        let result = try XCTUnwrap(SpeedTestResult.parse(sample, start: start, end: start.addingTimeInterval(8)))
        XCTAssertEqual(result.download, 994_859_008); XCTAssertEqual(result.upload, 192_328_416)
        XCTAssertEqual(result.bytesUsed, 965_323_838); XCTAssertEqual(result.interface, "en0")
        XCTAssertEqual(result.idleLatency ?? 0, 32.67, accuracy: 0.01)
        XCTAssertEqual(result.snappiness, .fine); XCTAssertEqual(result.workingLatency ?? 0, 81.7, accuracy: 0.1)
        XCTAssertEqual(SpeedTestResult.bits(result.download), "995 Mbps")
        XCTAssertEqual(result.verdicts, ["39 × 4K streams", "50 GB game in 7 min", "Video calls: smooth"])
    }
    func testRejectsMissingOrInvalidThroughput() {
        XCTAssertNil(SpeedTestResult.parse(Data("not json".utf8), start: start, end: start))
        XCTAssertNil(SpeedTestResult.parse(Data(#"{"dl_throughput":100}"#.utf8), start: start, end: start))
        XCTAssertNil(SpeedTestResult.parse(Data(#"{"dl_throughput":-1,"ul_throughput":5}"#.utf8), start: start, end: start))
        let minimal = SpeedTestResult.parse(Data(#"{"dl_throughput":0,"ul_throughput":0,"responsiveness":0}"#.utf8), start: start, end: start)
        XCTAssertNil(minimal?.responsiveness); XCTAssertNil(minimal?.snappiness); XCTAssertEqual(minimal?.bytesUsed, 0)
    }
    func testImplausibleValuesAreRejectedInsteadOfTrapping() {
        for json in [#"{"dl_throughput":1e30,"ul_throughput":1}"#, #"{"dl_throughput":1,"ul_throughput":1,"responsiveness":1e30}"#,
                     #"{"dl_throughput":1,"ul_throughput":1,"responsiveness":1e-300}"#, #"{"dl_throughput":1,"ul_throughput":1,"base_rtt":1e300}"#,
                     #"{"dl_throughput":1,"ul_throughput":1,"dl_bytes_transferred":1e300}"#] {
            XCTAssertNil(SpeedTestResult.parse(Data(json.utf8), start: start, end: start), json)
        }
        let tiny = SpeedTestResult(start: start, end: start, download: 1e-100, upload: 0)
        XCTAssertTrue(tiny.isPlausible); XCTAssertEqual(tiny.verdicts[1], "50 GB game in over a year")
        XCTAssertFalse(SpeedTestResult(start: start, end: start, download: -5, upload: 0).isPlausible)
        XCTAssertFalse(SpeedTestResult(start: start, end: start, download: 1, upload: 1, responsiveness: .infinity).isPlausible)
    }
    func testPlainLanguageCoversSlowAndFastLinks() {
        let slow = SpeedTestResult(start: start, end: start, download: 8_000_000, upload: 1_000_000, responsiveness: 120)
        XCTAssertEqual(slow.snappiness, .sluggish)
        XCTAssertEqual(slow.verdicts, ["4K streaming may buffer", "50 GB game in 13 h 53 min", "Video calls may stutter"])
        let fast = SpeedTestResult(start: start, end: start, download: 5e9, upload: 5e9, responsiveness: 2400)
        XCTAssertEqual(fast.snappiness, .snappy); XCTAssertEqual(fast.verdicts.first, "99+ × 4K streams")
        XCTAssertEqual(SpeedTestResult.bits(5e9), "5.0 Gbps"); XCTAssertEqual(SpeedTestResult.bits(2_400_000), "2.4 Mbps")
        XCTAssertEqual(SpeedTestResult.bits(640_000), "640 kbps"); XCTAssertEqual(SpeedTestResult.bits(.nan), "0 Mbps")
        XCTAssertEqual(SpeedTestResult(start: start, end: start, download: 0, upload: 0).verdicts[1], "Downloads stalled")
    }
}
