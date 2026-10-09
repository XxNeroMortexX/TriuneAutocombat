"""Created By: NeroMorte - verify distributed server payloads and their architecture."""
import hashlib
import json
import struct
from pathlib import Path
root=Path(__file__).resolve().parents[1]
release=json.loads((root/'EQBCServers/release.json').read_text())
assert release['minimumUpdater']=='4.1.7'
for entry in release['payloads']:
    data=(root/entry['remote']).read_bytes()
    assert len(data)==entry['bytes']
    assert hashlib.sha256(data).hexdigest()==entry['sha256']
    assert data[:2]==b'MZ'
    offset=struct.unpack_from('<I',data,0x3c)[0]
    assert data[offset:offset+4]==b'PE\0\0'
    machine=struct.unpack_from('<H',data,offset+4)[0]
    assert machine==({'EQBCS.exe':0x14c,'EQBCS-Go.exe':0x8664}[entry['name']])
print('Verified native and Go server manifests/PE architectures')
