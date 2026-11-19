#!/usr/bin/env python3
"""Compile extracted production helpers against a small GNU ObjC fixture.
This checks algorithms, not Apple UIKit rendering or on-device behavior.
"""
import hashlib,importlib.util,json,os,re,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('vendor_map',ROOT/'tools/vendor_map.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
rows=v.mappings();assert (ROOT/'src/VendorMap.h').read_text()==v.make_header(rows)
assert json.loads((ROOT/'vendor-map.json').read_text())==rows
src=(ROOT/'src/PhoneLifecycleFix.m').read_text()
def extract(name):
 m=re.search(r'^static [^\n;]*\b'+name+r'\([^;]*?\)\s*\{',src,re.M);assert m,name
 start=m.start();pos=src.index('{',m.start());depth=1;pos+=1
 while depth:
  if src[pos]=='{':depth+=1
  elif src[pos]=='}':depth-=1
  pos+=1
 return src[start:pos]+'\n'
functions=['PRNameContains','PRStatusView','PRWifiView','PRCellularView','PRSignalClass','PRRepairOwnedOverlays','PROwner','PRRefresh','PROwnsMethod','PRSkipQualifiers']
checks={
 'pure_original_renderers':all(x in src for x in ['gWifiRender(owner)','gCellRender(owner)','gDualRender(owner)']),
 'not_original_installer_or_dispatcher':'gRender(' not in src and 'gInstall(' not in src,
 'phone_process_only':'@"com.apple.springboard"' in src and 'CarPlayApp' not in src,
 'no_timer_or_restart':not any(x in src for x in ['NSTimer','CADisplayLink','dispatch_after(','kill(','system(','posix_spawn']),
 'lifecycle_entries':all('@selector('+x+')' in src for x in ['layoutSubviews','didMoveToWindow','didMoveToSuperview','setHidden:','setAlpha:','traitCollectionDidChange:']),
 'load_is_main_queue_deferred':'_dyld_register_func_for_add_image(PRImageAdded)' in src and 'dispatch_async(dispatch_get_main_queue()' in src,
 'version_pinned':'CC_SHA256(' in src and 'memcmp(uuid->uuid,map->uuid,16)' in src,
 'one_hook_per_class_selector':'[gInstalled containsObject:key]' in src and '[gInstalled addObject:key]' in src,
 'parent_method_materialized':'class_addMethod(cls,sel,replacement' in src,
 'no_host_unhide':'view.hidden=' not in src and 'owner.hidden=' not in src,
 'no_force_wifi_connection':not any(x in src for x in ['setWiFiEnabled','setWifiEnabled','WiFiManager','numberOfActiveBars=']),
}
assert all(checks.values()),checks
fixture=(ROOT/'tests/fixture.m').read_text()
unit=fixture.replace('/* PRODUCTION_HELPERS */','\n'.join(extract(x) for x in functions))
with tempfile.TemporaryDirectory() as td:
 p=Path(td);(p/'test.m').write_text(unit)
 inc=subprocess.check_output(['gcc','-print-file-name=include'],text=True).strip()
 cmd=['clang','-fobjc-runtime=gcc','-fobjc-exceptions','-fexceptions','-I'+inc,'-Werror','-Wno-objc-root-class',str(p/'test.m'),'-lobjc','-o',str(p/'test')]
 subprocess.run(cmd,check=True,capture_output=True,text=True)
 run=subprocess.run([str(p/'test')],check=True,capture_output=True,text=True)
 report={'source_sha256':hashlib.sha256(src.encode()).hexdigest(),'checks':checks,'fixture':json.loads(run.stdout),'vendor_mappings':rows,'native_uikit_tested':False,'device_tested':False}
 print(json.dumps(report,ensure_ascii=False,indent=2))
