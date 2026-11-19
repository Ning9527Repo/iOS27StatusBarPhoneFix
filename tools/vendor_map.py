#!/usr/bin/env python3
"""Pin addresses to the original bytes, never a guessed runtime offset."""
import hashlib,json,struct,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SAMPLE=ROOT/'vendor/iOS27StatusBar.dylib'
EXPECTED='709baf93799bf42d9adb5efcc389e290f538aaf8c6d697a386d58481c8c83a77'
DEFS={0:dict(wifi=0x7afc,cell=0x816c,dual=0x7680,keys=[0x104f8,0x10500,0x10508,0x10510],colorKey=0x104e0),
      2:dict(wifi=0x7cbc,cell=0x833c,dual=0x783c,keys=[0x10280,0x10288,0x10290,0x10298],colorKey=0x10268)}
def mappings():
 b=SAMPLE.read_bytes();assert hashlib.sha256(b).hexdigest()==EXPECTED
 assert b[:4]==bytes.fromhex('cafebabe')
 out=[]
 for i in range(struct.unpack_from('>I',b,4)[0]):
  cpu,sub,off,size,align=struct.unpack_from('>IIIII',b,8+20*i)
  d=b[off:off+size];assert cpu==0x100000c and sub in DEFS
  commands=[];p=32;uid=None;text=None
  for _ in range(struct.unpack_from('<I',d,16)[0]):
   cmd,n=struct.unpack_from('<II',d,p);assert n>=8 and p+n<=len(d)
   if cmd==0x1b:uid=d[p+8:p+24]
   if cmd==0x19:
    seg=d[p+8:p+24].rstrip(b'\0')
    if seg==b'__TEXT':
     assert struct.unpack_from('<Q',d,p+24)[0]==0
     for j in range(struct.unpack_from('<I',d,p+64)[0]):
      q=p+72+80*j
      if d[q:q+16].rstrip(b'\0')==b'__text':
       va,sz,fo=struct.unpack_from('<QQI',d,q+32)
       assert va==fo
       text=dict(textVA=va,textSize=sz,textSHA256=hashlib.sha256(d[fo:fo+sz]).hexdigest())
   p+=n
  assert text and uid
  row=dict(arch='arm64e' if sub==2 else 'arm64',uuid=str(uuid.UUID(bytes=uid)),uuidBytes=uid.hex(),**DEFS[sub],**text)
  row['functionPrefixes']={}
  for key in ['wifi','cell','dual']:
   assert row['textVA']<=row[key]<row['textVA']+row['textSize']
   row['functionPrefixes'][key]=d[row[key]:row[key]+24].hex()
  out.append(row)
 return out
def make_header(rows):
 def cbytes(s):return '{'+','.join('0x'+s[i:i+2] for i in range(0,len(s),2))+'}'
 text='// Generated from SHA256 '+EXPECTED+'\n#pragma once\n#include <stdint.h>\n'
 text+='typedef struct { uint8_t uuid[16],textSHA256[32]; uintptr_t textVA,textSize,wifi,cell,dual,keys[4],colorKey; } PRVendorMap;\n'
 text+='static const PRVendorMap kPRVendorMaps[]={\n'
 for r in rows:
  text+=' {'+cbytes(r['uuidBytes'])+','+cbytes(r['textSHA256'])+','+','.join(hex(r[k]) for k in ['textVA','textSize','wifi','cell','dual'])+','+'{'+','.join(map(hex,r['keys']))+'},'+hex(r['colorKey'])+'},\n'
 return text+'};\n'
if __name__=='__main__':
 rows=mappings();header=make_header(rows)
 (ROOT/'src/VendorMap.h').write_text(header)
 (ROOT/'vendor-map.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(json.dumps(rows,indent=2))
