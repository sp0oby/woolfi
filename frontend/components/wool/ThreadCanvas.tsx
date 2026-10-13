"use client";

import {useEffect, useRef} from "react";

// Two plied strands of cream yarn drifting across a band of the splash. The gap between them is the
// spread: it widens and narrows on its own, and the pointer pulls the strands back together the
// way a corrective trade pulls a pool back to fair. Purely decorative; renders nothing without
// WebGL2 and holds a single still frame under prefers-reduced-motion.

const VERT = `#version 300 es
in vec2 a; void main(){ gl_Position = vec4(a,0.,1.); }`;

const FRAG = `#version 300 es
precision highp float;
out vec4 o;
uniform vec2 uRes; uniform float uT; uniform vec2 uM; uniform float uPull;

float h21(vec2 p){ p=fract(p*vec2(123.34,456.21)); p+=dot(p,p+45.32); return fract(p.x*p.y); }
float vn(vec2 p){
  vec2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
  return mix(mix(h21(i),h21(i+vec2(1,0)),f.x), mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x), f.y);
}

float center(float x){ return .1*sin(x*.55+uT*.11) + .05*sin(x*1.3-uT*.07); }
float gap(float x){
  float g = .13 + .42*(.5+.5*sin(x*.42-uT*.22)) * (.6+.4*sin(x*1.1+uT*.13));
  // the pointer closes the spread near itself
  float near = exp(-pow((x-uM.x)*1.6,2.)) * uPull;
  return g*(1.-.85*near);
}

// one plied strand: returns premultiplied cream with alpha
vec4 strand(vec2 p, float cy, float slope, float r, float seed){
  float d = (p.y-cy)/sqrt(1.+slope*slope);
  float v = d/r;
  vec3 cream = vec3(.918,.859,.753), shade = vec3(.36,.32,.26);
  float a = 0.; vec3 c = vec3(0.);
  if(abs(v) < 1.){
    float lit = sqrt(1.-v*v);
    // diagonal ply twist, slowly travelling along the strand as if being spun
    float tw = sin((p.x*22. + v*2.2 + seed*7.) - uT*.9);
    float ply = smoothstep(-.4,1.,tw);
    // fine fibres running with the twist
    float fib = vn(vec2((p.x*22.+v*2.2)*14., v*4.+seed*11.));
    vec3 col = mix(shade, cream, lit*(.78+.22*ply)) * (.8+.3*fib);
    // top-lit sheen
    col += cream*.18*smoothstep(.2,.9,-v)*lit;
    float edge = smoothstep(1.,.7,abs(v));
    a = edge; c = col*edge;
  }
  // stray halo fibres
  float out1 = abs(v)-1.;
  if(out1 > -.3 && out1 < 1.4){
    // soft felted aura, lumpy along the strand
    float fuzz = exp(-max(out1,0.)*3.2) * (.35+.65*vn(vec2(p.x*9.+seed*5., uT*.05))) * .22;
    // a few long stray fibres poking out
    float stray = smoothstep(.86,.99, vn(vec2(p.x*60.+seed*31., out1*1.2+seed)))
                * (1.-smoothstep(0.,1.4,out1)) * .45;
    float hair = (fuzz + stray) * smoothstep(-.3,0.,out1);
    c += cream*hair*(1.-a); a += hair*(1.-a);
  }
  return vec4(c,a);
}

void main(){
  vec2 uv = gl_FragCoord.xy/uRes;
  float asp = uRes.x/uRes.y;
  vec2 p = (uv*2.-1.)*vec2(asp,1.);
  float e = .01;
  float cy = center(p.x), g = gap(p.x);
  float sl = (center(p.x+e)-center(p.x-e))/(2.*e);
  float r = .12;
  vec4 top = strand(p, cy+g, sl, r, 0.);
  vec4 bot = strand(p, cy-g, sl, r, 1.);
  // where the strands touch the upper one rides over
  vec4 col = top + bot*(1.-top.a);
  // fade at the screen edges so the strands come out of the dark
  float fade = smoothstep(0.,.18,uv.x)*smoothstep(1.,.82,uv.x);
  o = col*fade*.85;
}`;

export function ThreadCanvas({className = ""}: {className?: string}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const gl = cv.getContext("webgl2", {premultipliedAlpha: true, alpha: true, antialias: false});
    if (!gl) return;

    const sh = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      return s;
    };
    const prog = gl.createProgram()!;
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "a");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);

    const U = (n: string) => gl.getUniformLocation(prog, n);
    const uRes = U("uRes"), uT = U("uT"), uM = U("uM"), uPull = U("uPull");

    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    // Fibre detail needs real pixels; cap the cost on dense screens.
    const scale = Math.min(window.devicePixelRatio || 1, 1.5) * 0.8;
    const resize = () => {
      const r = cv.getBoundingClientRect();
      cv.width = Math.max(1, Math.round(r.width * scale));
      cv.height = Math.max(1, Math.round(r.height * scale));
      gl.viewport(0, 0, cv.width, cv.height);
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(cv);

    const m = {x: 0, tx: 0, pull: 0, tpull: 0, last: 0};
    const onMove = (e: PointerEvent) => {
      const r = cv.getBoundingClientRect();
      m.tx = ((e.clientX - r.left) / r.width * 2 - 1) * (r.width / r.height);
      m.tpull = 1;
      m.last = performance.now();
    };
    addEventListener("pointermove", onMove, {passive: true});

    let onScreen = true;
    const io = new IntersectionObserver(([en]) => (onScreen = en.isIntersecting));
    io.observe(cv);

    const draw = (t: number) => {
      gl.uniform2f(uRes, cv.width, cv.height);
      gl.uniform1f(uT, t);
      gl.uniform2f(uM, m.x, 0);
      gl.uniform1f(uPull, m.pull);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    if (reduce) {
      draw(12);
      return () => {
        ro.disconnect();
        io.disconnect();
        removeEventListener("pointermove", onMove);
      };
    }

    let raf = 0;
    const t0 = performance.now();
    const frame = (now: number) => {
      raf = requestAnimationFrame(frame);
      if (!onScreen || document.hidden) return;
      if (now - m.last > 1800) m.tpull = 0;
      m.x += (m.tx - m.x) * 0.08;
      m.pull += (m.tpull - m.pull) * 0.04;
      draw((now - t0) / 1000);
    };
    raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      io.disconnect();
      removeEventListener("pointermove", onMove);
    };
  }, []);

  return <canvas ref={ref} aria-hidden className={`pointer-events-none ${className}`} />;
}
