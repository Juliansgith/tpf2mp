import copy
import unittest

from tpf2mp.checkpoint import _validate_native_fingerprint
from tpf2mp.protocol import checksum, ProtocolError


class NativeInventoryTests(unittest.TestCase):
    def fixture(self, schema=3, complete=True):
        names = ('edges', 'constructions', 'vehicles', 'autonomous', 'other')
        result = dict(schemaVersion=schema, categories={n: '11111111' for n in names},
                      counts={n: 0 for n in names}, inventoryComplete=complete)
        if complete:
            result['inventory'] = dict(counts={
                'edges': dict(node=2, edge=1, edge_object=3),
                'constructions': dict(construction=0, asset=0, station=2, station_group=2, depot=0),
                'vehicles': dict(line=0, vehicle=0)}, geometry=dict(node='22222222', edge='33333333'))
        return result

    def validate(self, value):
        value = copy.deepcopy(value)
        value['digest'] = checksum(value)
        return _validate_native_fingerprint(value, value['digest'])

    def test_old_and_attached_inventory_schemas(self):
        for schema in (2, 3):
            for complete in (False, True):
                self.assertEqual(self.validate(self.fixture(schema, complete))['schemaVersion'], schema)
        self.assertNotEqual(self.validate(self.fixture(2))['digest'], self.validate(self.fixture(3))['digest'])

    def test_partial_read_cannot_claim_complete(self):
        value = self.fixture(complete=False)
        value['inventoryComplete'] = True
        with self.assertRaisesRegex(ProtocolError, 'inventory state'):
            self.validate(value)

    def test_bad_header_and_missing_edge_objects_rejected(self):
        for version in (True, 3.0, 4, '3', [], {}):
            with self.assertRaises(ProtocolError):
                self.validate(self.fixture(version))
        value = self.fixture()
        del value['inventory']['counts']['edges']['edge_object']
        with self.assertRaisesRegex(ProtocolError, 'kinds are incomplete'):
            self.validate(value)

    def test_attached_count_is_digest_carried(self):
        value = self.validate(self.fixture())
        value['inventory']['counts']['edges']['edge_object'] += 1
        with self.assertRaisesRegex(ProtocolError, 'digest mismatch'):
            _validate_native_fingerprint(value, value['digest'])
