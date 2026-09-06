import pathlib
import unittest

GUEST = pathlib.Path(__file__).resolve().parents[1]


class BrokerPackaging(unittest.TestCase):
    def test_first_owner_service_is_enabled_without_private_journal_output(self):
        unit = (GUEST / 'native-overlay/usr/lib/systemd/user/omarchy-link.service').read_text()
        self.assertIn('ConditionUser=1000', unit)
        self.assertIn('UMask=0077', unit)
        self.assertIn('RuntimeDirectory=omarchy-link', unit)
        self.assertIn('StandardOutput=null', unit)
        self.assertIn('LimitCORE=0', unit)
        self.assertIn('ExecStart=/usr/local/bin/omarchy-link daemon', unit)
        config = (GUEST / 'scripts/configure-rootfs.sh').read_text()
        self.assertIn('default.target.wants/omarchy-link.service', config)


if __name__ == '__main__':
    unittest.main()
