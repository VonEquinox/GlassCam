"""Portable v0.2 migration spec and scoped Swift dataflow gates, not Apple runtime."""
import copy,json,math,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import verify_ffcs_v020 as v

def migrate(recipe):
    """Independent persisted-contract specification; Swift source separately gated."""
    out=copy.deepcopy(recipe)
    ffcs=out.setdefault('ffcs',{})
    for key,value in {'renderRevision':2,'cameraFamily':'XH2S','applyReferenceAdjustments':False,'sharpenRadius':1.0}.items():ffcs.setdefault(key,value)
    effects=out.setdefault('effects',{})
    for key in ('applyGrain','applySharpness','applyExtraCrop'):effects.setdefault(key,True)
    return out
class FFCSV020Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline=(ROOT/'ios/GlassCam/ImagePipeline.swift').read_text()
        cls.engine=(ROOT/'ios/GlassCam/FFCSEngine.swift').read_text()
        cls.content=(ROOT/'ios/GlassCam/ContentView.swift').read_text()
    def test_missing_settings_adopt_neutral_default_retain_all_three_flags(self):
        for grain in (False,True):
            for sharp in (False,True):
                for crop in (False,True):
                    original={'mode':'ffcs','effects':{'applyGrain':grain,'applySharpness':sharp,'applyExtraCrop':crop}}
                    updated=migrate(original)
                    self.assertEqual(updated['effects'],original['effects'])
                    self.assertEqual(updated['ffcs'],{'renderRevision':2,'cameraFamily':'XH2S','applyReferenceAdjustments':False,'sharpenRadius':1.0})
                    self.assertEqual(migrate(json.loads(json.dumps(updated))),updated)
        for text in ('ffcs = try values.decodeIfPresent(FFCSSettings.self, forKey: .ffcs) ?? .standard','applyReferenceAdjustments = try values.decodeIfPresent(Bool.self, forKey: .applyReferenceAdjustments) ?? false','sharpenRadius = try values.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? 1.0'):
            self.assertIn(text,self.pipeline)
    def test_explicit_ffcs_settings_snapshot_survives_mutation(self):
        original={'ffcs':{'cameraFamily':'GFX100II','applyReferenceAdjustments':True,'sharpenRadius':1.5},'effects':{'applyGrain':False}}
        captured=migrate(original);original['ffcs']['cameraFamily']='XA3';original['effects']['applyGrain']=True
        self.assertEqual(captured['ffcs']['cameraFamily'],'GFX100II');self.assertFalse(captured['effects']['applyGrain'])
        self.assertIn('let ffcs: FFCSSettings',self.pipeline);self.assertIn('self.effects = effects; self.ffcs = ffcs',self.pipeline)
        self.assertIn('cached.settings == settings',self.engine)
        self.assertIn('settings.applyReferenceAdjustments ? 1 : 0',self.engine)
    def test_native_family_availability_and_provenance_golden_contract(self):
        golden=json.loads((ROOT/'validation/ffcs-v020-stage-goldens.json').read_text())
        records=golden['records'];families={r['camera'] for r in records}
        self.assertEqual(families,set(v.FAMILIES));self.assertEqual(len({r['asset'] for r in records}),50)
        substitutes=[r for r in records if r['substitution']['status']=='unquantified'];self.assertEqual(len(substitutes),36)
        for r in substitutes:self.assertIn(r['camera'],('GFX100S','GFX100II'));self.assertTrue(r['asset'].startswith('gfx100/'))
        self.assertIn('simulations.filter { isSimulationAvailable($0.id, family: family) }',self.engine)
        self.assertIn('ffcs_simulation_available(root, $0, index)',self.engine)
        self.assertIn('ffcs_resolved_asset_family(root, camera, index)',self.engine)
    def test_crop_none_and_dynamic_halo_flow(self):
        self.assertIn('mode == .hncs ? hncs.crop(effects: effects) : .none',self.pipeline)
        self.assertIn('halo = try FFCSEngine.requiredHalo',self.pipeline)
        self.assertIn('Int(ffcs_required_halo(context.pointer))',self.engine)
        self.assertIn('start - halo',self.pipeline);self.assertIn('start + rows + halo',self.pipeline)
        report=json.loads((ROOT/'validation/ffcs-v020-native.json').read_text())
        self.assertGreater(report['strip_bit_exact_calls'],0)
        self.assertEqual(report['workers'],[1,2,3,4])
        self.assertTrue(any('radius=2.25' in case['case'] for case in report['checks']))
    def test_historical_fixtures_not_relabelled_as_current(self):
        old=json.loads((ROOT/'validation/ffcs-effect-defaults-before.json').read_text())
        self.assertIn('snapshot',old)
        current=json.loads((ROOT/'validation/ffcs-v020-native.json').read_text())
        self.assertEqual(current['source']['version'],'0.2.0');self.assertGreater(len(current['supersedes']),1)
        self.assertEqual(current['configured_family_cases'],86)
if __name__=='__main__':unittest.main()
