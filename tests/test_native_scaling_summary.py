import importlib.util
from pathlib import Path
import unittest
from datetime import datetime, timezone

spec=importlib.util.spec_from_file_location('scaling',Path(__file__).resolve().parents[1]/'tools/summarize_native_scaling.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ScalingSummaryTests(unittest.TestCase):
    def report(self):
        r={'complete':True,'workload':'scaling','markers':[],'samples':[]}
        for index,(phase,speed) in enumerate([('paused',0),('speed1',1),('speed4',4),('paused-repeat',0),('camera',0),('speed1-repeat',1)]):
            for t in range(index*10,index*10+10):
                r['markers'].append(f'event=phase-sample-{phase} speed={speed} gameTime={t*speed} atEpoch={t}')
                r['samples'].append({'atUtc':datetime.fromtimestamp(t,timezone.utc).isoformat(),
                    'wallSeconds':t,'cpuSeconds':t*2,'privateBytes':2**30,'threads':[]})
        return r
    def test_matched_windows(self):
        result=module.summarize(self.report())
        self.assertTrue(result['complete']);self.assertFalse(result['fpsMeasured'])
        self.assertEqual(result['phases']['speed4']['simulationPerWallSecond'],4)
        self.assertEqual(result['phases']['paused']['oneCoreCpuPercent'],200)
    def test_missing_phase_fails(self):
        r=self.report();r['markers']=[m for m in r['markers'] if 'sample-camera ' not in m]
        self.assertFalse(module.summarize(r)['complete'])
    def test_speed_not_applied_fails(self):
        r=self.report();r['markers']=[m.replace('speed=4','speed=0') for m in r['markers']]
        self.assertFalse(module.summarize(r)['complete'])
    def test_no_os_samples_fails(self):
        r=self.report();r['samples']=[]
        self.assertFalse(module.summarize(r)['complete'])
