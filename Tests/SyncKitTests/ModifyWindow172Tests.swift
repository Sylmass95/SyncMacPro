import XCTest
@testable import SyncKit

/// 1.7.2 : un partage réseau (QNAP) garde les dates moins finement que le Mac : rsync réécrivait la date de 15 811
/// fichiers identiques à chaque passage (2 h pour 0 octet, essai réel du 19/10). Une seconde d'écart est tolérée.
final class ModifyWindow172Tests: XCTestCase {
    let run = RunOptions(archiveStamp: "2026-10-19_18-00")

    func task(_ source: Endpoint, _ destination: Endpoint, mode: SyncMode = .copy) -> SyncTask {
        SyncTask(name: "t", source: source, destination: destination, mode: mode)
    }

    let mac = Endpoint.local(path: "/Users/moi/Desktop/PERSO-PROJECT")
    let qnap = Endpoint.network(url: "smb://admin@qnap/Documents", mountPath: "/Volumes/Documents/PERSO-PROJECT")

    func testANetworkDestinationToleratesOneSecond() throws {
        XCTAssertTrue(try RsyncCommandBuilder.command(for: task(mac, qnap), run: run).arguments.contains("--modify-window=1"))
        XCTAssertTrue(try RsyncCommandBuilder.planCommand(for: task(mac, qnap), run: run).arguments.contains("--modify-window=1"))
    }

    func testANetworkSourceToleratesOneSecond() throws {
        let disk = Endpoint.local(path: "/Volumes/Extreme Pro/BACKUP")
        XCTAssertTrue(try RsyncCommandBuilder.command(for: task(qnap, disk), run: run).arguments.contains("--modify-window=1"))
    }

    func testLocalCopiesKeepExactDates() throws {
        let disk = Endpoint.local(path: "/Volumes/HDDExtBRSM/BACKUP")
        XCTAssertFalse(try RsyncCommandBuilder.command(for: task(mac, disk), run: run).arguments.contains("--modify-window=1"))
    }

    func testTheOptionComesBeforeThePaths() throws {
        let arguments = try RsyncCommandBuilder.command(for: task(mac, qnap), run: run).arguments
        let option = try XCTUnwrap(arguments.firstIndex(of: "--modify-window=1"))
        XCTAssertLessThan(option, arguments.count - 2)
    }
}
