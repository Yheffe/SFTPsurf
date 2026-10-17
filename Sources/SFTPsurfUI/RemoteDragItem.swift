import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The payload dragged from the remote pane.Declared as an exported type so
/// the drag is distinct from a Finder file drag.
struct RemoteDragPayload: Codable, Transferable {
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sftpSurfRemoteItems)
    }
}

extension UTType {
    static let sftpSurfRemoteItems = UTType(exportedAs: "com.sftpsurf.remote-items")
}
