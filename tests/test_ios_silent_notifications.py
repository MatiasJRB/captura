"""Check the real notice factory without running the app or asking for permissions."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ios/Captura/App/PauseNotices.swift'


class SilentNoticeTests(unittest.TestCase):
    def test_adapter_never_requests_sound_or_sets_a_default_sound(self):
        source = SOURCE.read_text()
        self.assertNotIn('content.sound = .default', source)
        self.assertIn('requestAuthorization(options: [.alert])', source)
        self.assertIn('center.add(Self.request(notice))', source)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Native UserNotifications factory check needs macOS and Swift')
    def test_real_factory_retains_every_visible_notice_without_sound(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Support.swift').write_text('''
import Foundation
enum RecorderPauseReason: CaseIterable { case interrupted, waitingForTheApp, inputLost, microphoneLost, lowStorage, writeFailed }
enum LogPrivacy { static func publicSummary(of error: Error) -> String { "fixture-error" } }
''')
            (root / 'main.swift').write_text('''
import Foundation
import UserNotifications
MainActor.assumeIsolated {
    for reason in RecorderPauseReason.allCases {
        let notice = PauseNotice(reason)
        let request = SystemPauseNotifier.request(notice)
        precondition(request.content.sound == nil)
        precondition(request.content.title == notice.title && !request.content.body.isEmpty)
        precondition(request.identifier == SystemPauseNotifier.identifier)
        precondition(request.trigger == nil)
    }
}
''')
            binary = root / 'check'
            compiled = subprocess.run(['swiftc', str(root / 'Support.swift'), str(SOURCE), str(root / 'main.swift'), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(executed.returncode, 0, executed.stderr)


if __name__ == '__main__':
    unittest.main()
