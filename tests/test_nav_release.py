# Created By: NeroMorte - Disabled metadata cannot ship a placeholder; enabled payload must match its hash.
import importlib.util,tempfile,json,hashlib
from pathlib import Path
from zipfile import ZipFile
spec=importlib.util.spec_from_file_location('package_release',Path('tools/package_release.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp);module.ROOT=root;module.ASSET=root/'install.zip';module.DLL=root/'MQ2WebUpdate.dll'
    (root/'MQ2Nav').mkdir();manifest=root/'MQ2Nav/release.json'
    module.DLL.write_bytes(b'updater fixture')
    manifest.write_text(json.dumps({'enabled':False}))
    assert module.nav_payload() is None
    metadata={'enabled':True,'client':'RoF2','architecture':'Win32','sha256':'0'*64}
    manifest.write_text(json.dumps(metadata))
    try:module.nav_payload();raise AssertionError('missing DLL accepted')
    except RuntimeError:pass
    dll=root/'MQ2Nav/MQ2Nav.dll';dll.write_bytes(b'nav fixture')
    try:module.nav_payload();raise AssertionError('wrong hash accepted')
    except RuntimeError:pass
    metadata['sha256']=hashlib.sha256(dll.read_bytes()).hexdigest();manifest.write_text(json.dumps(metadata))
    assert module.nav_payload()==(dll,'plugins/MQ2Nav.dll')
    with ZipFile(module.ASSET,'w') as archive:archive.writestr('lua/triune.lua',b'fixture')
    module.build()
    with ZipFile(module.ASSET) as archive:assert archive.read('plugins/MQ2Nav.dll')==dll.read_bytes()
print('PASS: disabled/missing/mismatched Nav metadata and exact archive distribution')
