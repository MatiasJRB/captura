import AVFoundation
import UIKit
import CapturaCore
import XCTest
@testable import Captura

final class AudioSessionNotificationParserTests: XCTestCase {
    private func parse(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil, inputAvailable: Bool = true) -> AudioSessionEvent? {
        AudioSessionNotificationParser.event(
            from: Notification(name: name, object: nil, userInfo: userInfo),
            inputAvailable: inputAvailable
        )
    }

    func testInterruptionBegan() {
        XCTAssertEqual(parse(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ]), .interruptionBegan)
    }

    func testInterruptionEndedWithShouldResume() {
        XCTAssertEqual(parse(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]), .interruptionEnded(shouldResume: true))
    }

    func testInterruptionEndedWithoutOptionsDoesNotResume() {
        XCTAssertEqual(parse(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ]), .interruptionEnded(shouldResume: false))
    }

    func testMalformedInterruptionIsIgnored() {
        XCTAssertNil(parse(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: "began"]))
        XCTAssertNil(parse(AVAudioSession.interruptionNotification, nil))
    }

    func testOldDeviceUnavailableIsInputLoss() {
        XCTAssertEqual(parse(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        ], inputAvailable: false), .routeChanged(.inputDeviceLost, inputAvailable: false))
    }

    func testNoSuitableRouteIsReported() {
        XCTAssertEqual(parse(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue,
        ]), .routeChanged(.noSuitableRoute, inputAvailable: true))
    }

    func testNewDeviceIsABenignRouteChange() {
        XCTAssertEqual(parse(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
        ]), .routeChanged(.other, inputAvailable: true))
    }

    func testMediaServicesReset() {
        XCTAssertEqual(parse(AVAudioSession.mediaServicesWereResetNotification), .mediaServicesReset)
    }

    func testAppBecameActive() {
        XCTAssertEqual(parse(UIApplication.didBecomeActiveNotification), .becameActive)
    }

    func testUnrelatedNotificationIsIgnored() {
        XCTAssertNil(parse(Notification.Name("org.example.unrelated")))
    }

    func testControllerObservesEveryParsedNotification() {
        XCTAssertEqual(Set(AudioSessionNotificationParser.observedNames), [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didBecomeActiveNotification,
        ])
    }
}
