"""Writes expected.txt for TestGif: python expected.py (in this folder;
needs numpy). gifproto.py is the reference decoder."""
import os, glob, numpy as np
from gifproto import parse, Cursor
def fnv(buf):
    h=0x811C9DC5
    for x in buf: h=((h^x)*0x01000193)&0xFFFFFFFF
    return h
def fnv_np(a):
    # vectorised FNV is sequential; do it in python on bytes (fine for small files)
    return fnv(a.tobytes())
lines=["# MView GIF test: expected results from the reference decoder (Python, checked against Pillow).",
       "# file;width;height;frames;total delay ms;FNV-1a of each frame (BGRA, top row first)"]
files=[f for f in sorted(glob.glob('*.gif')) if not os.path.basename(f).startswith(('huge_','not_a_gif','animated_','static_'))]+['../Test.gif']
for path in files:
    real = path
    b=open(real,'rb').read()
    g=parse(b)
    if g is None: continue
    c=Cursor(g); hs=[]
    for i in range(len(g['frames'])):
        fr=c.frame(i)[..., [2,1,0,3]]
        hs.append('%08X'%fnv(fr.tobytes()))
    name=os.path.basename(path) if path!='../Test.gif' else '..\\Test.gif'
    lines.append(f"{name};{g['width']};{g['height']};{len(g['frames'])};{sum(f.delay for f in g['frames'])};{','.join(hs)}")
    print(name, len(hs))
open('expected.txt','w').write('\r\n'.join(lines)+'\r\n')
