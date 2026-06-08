import Foundation

@objc protocol ContainerXPCProtocol {
    func executeCommand(_ data: Data, completion: @escaping (Data) -> Void)
}

@objc protocol ExtensionXPCProtocol {
    func settingsDidChange()
    func shutdownImminent()
}
