"""Source regression for the ITMS-90626 App Intent description rejection."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
ACTIVITY_SOURCE = ROOT / "HarcMobileActivityShared/HarcRecordingActivity.swift"


class MobileAppIntentMetadataTests(unittest.TestCase):
    def test_stop_recording_description_is_device_neutral(self):
        source = ACTIVITY_SOURCE.read_text()
        self.assertIn('IntentDescription("Stop and save this recording.")', source)

    def test_mobile_app_intent_descriptions_do_not_name_iphone(self):
        descriptions = []
        for directory in ("HarcMobileActivityShared", "HarcMobileApp", "HarcMobileWidgets"):
            for path in (ROOT / directory).rglob("*.swift"):
                for description in re.findall(r'IntentDescription\(\s*"([^"\n]*)"', path.read_text()):
                    descriptions.append(description)
                    with self.subTest(path=str(path.relative_to(ROOT)), description=description):
                        self.assertNotIn("iphone", description.casefold())
        self.assertTrue(descriptions, "Expected at least one extracted App Intent description")


if __name__ == "__main__":
    unittest.main()
