"""Created By: NeroMorte - verify distributed server payloads and their architecture."""
import hashlib
import re
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

# Created By: NeroMorte - Verify the published Windows updater payload.
updater=json.loads((root/'MQ2WebUpdate/release.json').read_text())
# Edited By: NeroMorte - publication metadata must match the actual engine source version.
source=(root/'MQ2WebUpdate/MQ2WebUpdate.cpp').read_text()
version=re.search(r'kWebUpdateVersion\s*=\s*"([^"]+)"',source)
assert version and updater['version']==version.group(1)
data=(root/'MQ2WebUpdate'/updater['file']).read_bytes()
assert len(data)==updater['bytes']
assert hashlib.sha256(data).hexdigest()==updater['sha256']
assert data[:2]==b'MZ'
offset=struct.unpack_from('<I',data,0x3c)[0]
assert data[offset:offset+4]==b'PE\0\0'
assert struct.unpack_from('<H',data,offset+4)[0]==0x14c
print('Verified published MQ2WebUpdate '+updater['version']+' payload')

# Created By: NeroMorte - pending DLLs are explicitly disabled; published bytes must match.
client=json.loads((root/'MQ2EQBC/release.json').read_text())
if client['enabled']:
    data=(root/'MQ2EQBC/MQ2EQBC.dll').read_bytes()
    assert len(data)==client['bytes']
    assert hashlib.sha256(data).hexdigest()==client['sha256']
    offset=struct.unpack_from('<I',data,0x3c)[0]
    assert data[:2]==b'MZ' and data[offset:offset+4]==b'PE\0\0'
    assert struct.unpack_from('<H',data,offset+4)[0]==0x14c
