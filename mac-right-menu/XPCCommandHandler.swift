import Foundation
import os.log

private let logger = Logger(subsystem: Constants.mainAppBundleID, category: "xpc-listener")

final class XPCCommandHandler: NSObject, ContainerXPCProtocol {

    var onCommand: ((CommandRequest) -> Void)?

    func executeCommand(_ data: Data, completion: @escaping (Data) -> Void) {
        guard let command = try? JSONDecoder().decode(CommandRequest.self, from: data) else {
            let result = CommandResult(success: false, errorDescription: "Invalid command data")
            completion((try? JSONEncoder().encode(result)) ?? Data())
            return
        }
        onCommand?(command)
        let result = CommandResult(success: true)
        completion((try? JSONEncoder().encode(result)) ?? Data())
    }
}
