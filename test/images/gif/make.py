"""Makes the synthetic test GIFs (Pillow, numpy). See README.txt for the others."""
from PIL import Image, ImageDraw
import numpy as np, io
out=''
W,H=320,240
def frames_moving(n, bg=(0,0,0,0)):
    fr=[]
    for i in range(n):
        im=Image.new('RGBA',(W,H),bg)
        d=ImageDraw.Draw(im)
        x=10+i*(W-60)//n
        d.rectangle([x,80,x+40,120],fill=(255,50+i*10%200,30,255))
        d.text((5,5),f'frame {i+1}/{n}',fill=(255,255,255,255))
        fr.append(im)
    return fr
# 1 disposal 2 with transparency
f=frames_moving(20)
f[0].save(out+'disposal2_transparent.gif',save_all=True,append_images=f[1:],duration=80,loop=0,disposal=2)
# 2 disposal 3: background frame + overlays restored
base=Image.new('RGB',(W,H),(20,40,90)); d=ImageDraw.Draw(base)
for k in range(0,W,20): d.line([k,0,k,H],fill=(60,90,150))
fr=[base]
for i in range(12):
    im=base.copy(); d=ImageDraw.Draw(im); d.ellipse([20+i*22,100,60+i*22,140],fill=(250,220,0)); fr.append(im)
fr[0].save(out+'disposal3.gif',save_all=True,append_images=fr[1:],duration=100,loop=0,disposal=[1]+[3]*12,optimize=False)
# 3 interlaced, colour gradient frames
fr=[]
for i in range(8):
    a=np.zeros((H,W,3),np.uint8); a[...,0]=np.linspace(0,255,W)[None,:]; a[...,1]=np.linspace(0,255,H)[:,None]; a[...,2]=i*30
    fr.append(Image.fromarray(a).convert('P',palette=Image.ADAPTIVE,colors=256))
fr[0].save(out+'interlaced.gif',save_all=True,append_images=fr[1:],duration=150,loop=0,interlace=True)
# 4 local palettes: each frame a different adaptive palette
fr=[]
for i in range(6):
    a=np.zeros((H,W,3),np.uint8); a[...,(i%3)]=np.linspace(0,255,W)[None,:]; a[...,((i+1)%3)]=np.linspace(255,0,H)[:,None]
    fr.append(Image.fromarray(a).convert('P',palette=Image.ADAPTIVE,colors=64))
fr[0].save(out+'local_palettes.gif',save_all=True,append_images=fr[1:],duration=300,loop=0)
# 5 still
Image.fromarray(np.random.default_rng(1).integers(0,255,(H,W,3),dtype=np.uint8)).convert('P',palette=Image.ADAPTIVE).save(out+'still.gif')
# 6 zero delay
f=frames_moving(10,(0,0,0,255))
f[0].save(out+'zero_delay.gif',save_all=True,append_images=f[1:],duration=0,loop=0)
# 7 truncated: cut a multi-frame gif in its 6th frame
b=open(out+'disposal3.gif','rb').read()
open(out+'truncated.gif','wb').write(b[:len(b)*55//100])
# 8 frame outside the canvas: patch the logical screen smaller than frames
b=bytearray(open(out+'zero_delay.gif','rb').read())
b[6:8]=(200).to_bytes(2,'little'); b[8:10]=(150).to_bytes(2,'little')
open(out+'frame_outside_canvas.gif','wb').write(bytes(b))
