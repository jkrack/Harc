import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('selector', Path(__file__).resolve().parents[1] / 'select-ios-configuration-simulator.py')
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)

class SimulatorSelectionTests(unittest.TestCase):
    def test_newest_available_ios_then_stable_device_order(self):
        runtimes = {'runtimes': [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-18-5', 'version': '18.5', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5', 'version': '26.5', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0', 'isAvailable': False}]}
        devices = {'devices': {
            runtimes['runtimes'][0]['identifier']: [{'name': 'iPhone 16', 'udid': 'old', 'isAvailable': True}],
            runtimes['runtimes'][1]['identifier']: [
                {'name': 'iPhone 17 Pro', 'udid': 'z', 'isAvailable': True},
                {'name': 'iPhone 17 Pro', 'udid': 'a', 'isAvailable': True},
                {'name': 'iPhone 17', 'udid': 'missing', 'isAvailable': False},
                {'name': 'iPad Pro', 'udid': 'ipad', 'isAvailable': True}]}}
        selected = selector.select_simulator(runtimes, devices)
        self.assertEqual(selected['udid'], 'a')
        self.assertEqual(selected['runtime_version'], '26.5')
        devices['devices'][runtimes['runtimes'][1]['identifier']].reverse()
        runtimes['runtimes'].reverse()
        self.assertEqual(selector.select_simulator(runtimes, devices), selected)

    def test_no_usable_runtime_fails_closed(self):
        for runtime in [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.watchOS-26', 'version': '26', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-17', 'version': '17', 'isAvailable': True},
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26', 'version': '26', 'isAvailable': False}]:
            with self.subTest(runtime=runtime), self.assertRaises(ValueError):
                selector.select_simulator({'runtimes': [runtime]}, {'devices': {runtime['identifier']: [
                    {'name': 'iPhone 17', 'udid': 'phone', 'isAvailable': True}]}})

    def test_missing_devices_fails_closed(self):
        with self.assertRaises(ValueError):
            selector.select_simulator({'runtimes': []}, {'devices': {}})

    def test_booted_supported_phone_avoids_unnecessary_cold_start(self):
        older = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
        newer = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        runtimes = {'runtimes': [
            {'identifier': older, 'version': '26.5', 'isAvailable': True},
            {'identifier': newer, 'version': '27.0', 'isAvailable': True}]}
        devices = {'devices': {
            older: [{'name': 'iPhone 17 Pro', 'udid': 'warm', 'isAvailable': True, 'state': 'Booted'}],
            newer: [{'name': 'iPhone 17', 'udid': 'cold', 'isAvailable': True, 'state': 'Shutdown'}]}}
        self.assertEqual(selector.select_simulator(runtimes, devices)['udid'], 'warm')
