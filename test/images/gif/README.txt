Test GIFs for TestGif (test\TestGif.lpr, Day 19)

animated_*.gif, static_*.gif and frames\  a GIF test suite (added by the
               user): TestGif compares every frame with the reference
               picture in frames\ (transparent pixels by transparency
               only). Loop counts: *_noloop plays once, *_loop forever.

expected.txt   size, frame count, total delay and a checksum of every
               frame as built by the cursor; written by expected.py
               from gifproto.py, the Python copy of uGifDecoder, which
               matches Pillow frame by frame on all of these (except
               the cut files, where Pillow invents the missing pixels).

disposal2_transparent.gif  moving square, disposal 2, transparency
disposal3.gif              background + overlays with disposal 3
frame_outside_canvas.gif   logical screen 200 x 150, frames 320 x 240:
                           clipped to the logical screen
interlaced.gif             interlaced frames with local palettes
interlaced_odd_size.gif    interlaced, 257 x 131 (rows not a multiple of 8)
local_palettes.gif         a different palette in every frame
still.gif                  one frame (Pillow writes it interlaced)
zero_delay.gif             delay 0: plays at 100 ms per frame
ffmpeg_testsrc.gif         ffmpeg output: small changed rectangles with
                           transparency, 15 fps
truncated.gif              disposal3.gif cut off: 4 frames remain
still_cut.gif, interlaced_cut.gif, ffmpeg_cut.gif
                           cut inside the first frame: the part decoded
                           is drawn, the rest stays transparent (black)
huge_frame.gif             2nd frame claims 65535 x 65535: file ends there
huge_first_frame.gif       1st frame claims 65535 x 65535: refused (memory guard)
not_a_gif.gif              a PNG named .gif: goes to BGRABitmap
..\Test.gif                the user's 126-frame test animation

Made with make.py (Pillow), ImageMagick (interlaced*.gif: convert
-interlace GIF), ffmpeg (testsrc + palettegen/paletteuse) and by cutting
or patching the files above.
