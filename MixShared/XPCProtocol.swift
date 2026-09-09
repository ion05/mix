import Foundation

@objc protocol MixAudioServing {
    func fetchSnapshot(withReply reply: @escaping (Data) -> Void)
    func applyCommand(_ data: Data, withReply reply: @escaping (Data) -> Void)
    func requestQuit(_ reply: @escaping () -> Void)
    func ping(_ reply: @escaping () -> Void)
}
