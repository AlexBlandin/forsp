
Forsp in Zig

1:1 version, "extensible" version, and then an extended version, "forspel", with a few features from prolog brought in (and maybe a little erlang if I sit down to work out some nice concurrency under this, since it should be quite practical)

thought: one with a little prolog in it, maybe a little erlang (forspel?), and look at building a system to plug in extra types and mechanisms that can't be done quite as nicely on top (though most can), like it just includes a new header for them etc with the -l load params? zig does make easier so I'll want to just do a zig rewrite anyway

could be nice to envisage how it could work (esp. with forspel concurrency) on different hardware, like how forth and lisp machines do, with potential things brought from kilocore designs like Epiphany or Esperanto (Epiphany's maker Adapteva has renamed to Zero ASIC and is back in the game, but exploring new approaches via chiplets)

16-12nm, at a stretch? I'd be happy sticking with the 28-20nm class, esp. if we can optimise the energy efficiency through design.

- Epiphany IV: 102.4 GFLOPS @ 800 MHz @ 1.9W / 64-cores / 0.2B trans. / 225mm² @ 28nm
  - 70 GFLOPS / W
- Epiphany V: 1024-cores / 4.56B trans. / 117.44mm² @ N16FF+
  - 4096 FLOPS @ 1 Hz, 2:1 INT:FP32 (8 TOPS64), 2:1 FP32:FP64, 100 GFLOPS/W @ 0.5 GHz, so:
    - E-V: 2 TFLOPS32 | 1 TFLOPS64 @ 0.5 GHz @ 10W / 1024-cores (0.5 GHz @ 10W, 100 GFLOPS/W from million_cores.pdf)
      - 4 TFLOPS32 | 2 TFLOPS64 @ 1 GHz @ 30-35W / 1024-cores, assuming 1.5-1.67x clock:power scaling on TSMC 16FF+
    - KNL: 3.6 TFLOPS64 @ 1.5 GHz @ 245W / 72-cores / 7.1B trans. / 683mm² @ I14
    - Broadwell: 1.3 TFLOPS64 @ 2.2 GHz @ 165W / 24-cores / 7.2B trans. / 456mm² @ I14
    - P100: 9.5 TFLOPS32 | 4.7 TFLOPS64 @ 1.2 GHz @ 250W / 56 SMs / 15.3B trans. / 610mm² @ N16FF+
    - Fiji: 8.6 TFLOPS32 | 0.5 TFLOPS64 @ 1.0 GHz @ 275W / 64 CUs / 8.9B trans. / 596mm² @ N28
    - RX580: 6.1 TFLOPS32 | 0.39 TFLOPS64 @ 1.2 GHz @ 185W / 36 CUs / 5.7B trans. / 232mm² @ GF14
  - Pipeline Parallelism model is v. similar to WSE routing
- ET-SoC-1: 139.264 TOPS8 | 17.4 TFLOPS32 | 8.7 TFLOPS64 @ 1 GHz @ 20W-25W / 1088-cores / 24B trans. / 570mm² @ N7
  - 128 GOPS8 / core @ 1 GHZ, operating ranges from 300 MHz (8.5W?) to 2 GHz (60W? 275W?) but expect 0.5-1.5
    - 1.8x FLOPS / W @ 8.5W vs 20W (0.31V vs 0.4V)
  - w/ 32GB LPDDR4x
  - The big silly stuff
    - WSE-1: 3.5 PFLOPS16 @ 23kW / 400k "AI cores" / 1.2T trans. / 46'225mm² @ N16
    - WSE-2: 7.5 PFLOPS16 @ 23kW / 850k "AI cores" / 2.6T trans. / 46'225mm² @ N7
      - 64 WSE2s: 4 EFLOPS16AI / 64 = 62.5 PFLOPS16AI (what, is this BF16?)
    - WSE-3: 15 PFLOPS16 | 125 PFLOPS16AI @ 23kW / 900k "AI cores" / 4.xT trans. / 46'225mm² @ N5
    - H100: 62.0 TFLOPS32 | 31.0 TFLOPS64 | 248.3 TFLOPS16 @ 1.7 GHz @ 700 W / 132 SMs / 80B trans. / 814mm² @ N5 (as SXM module, 8:2:1:1:16:32 FP16:FP32:FP64:INT32:INT8:INT4)
      - DGX H100 = 8x H100: 16 PFLOPSAI = 2 PFLOPSAI / H100, FLOPSAI = 8x FLOPS16, so FLOPAI = 2x TOPS4 at A100 rate? accounting for sparsity? I'm so confused...
    - A100: 19.5 TFLOPS32 | 9.7 TFLOPS64 | 77.9 TFLOPS16 | 19.5 TFLOPS64T | 115.9 TFLOPSTF32 | 311.8 TFLOPSBF16 @ 1.3 GHz @ 400 W / 108 SMs / 54B trans. / 826mm² @ N7 (as SXM module, 8:2:1:2:16:32 FP16:FP32:FP64:INT32:INT8:INT4)
- Gotland (Zero ASIC RV64GC CPU): 1.5 GHz / 4-cores / 4mm² @ GF12LP
  - ML Accelerator: 3 TOPS (INT8) @ 1.5 GHz / 1-core / 4mm² @ GF12LP

(Nodes are "N" for TSMC, "GF" for Global Foundries, "S" for Samsung, "I" for Intel, just "nm" for unknown)

figuring out how we can push the home-grown / garage-made class would be interesting... solarpunk chips!
