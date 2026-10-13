"use client";

import {useEffect} from "react";
import Lenis from "lenis";
import gsap from "gsap";
import {ScrollTrigger} from "gsap/ScrollTrigger";

// Smooth scroll and slow scroll reveals for the reading pages (splash, docs, governance).
// Never mounted in /app: the terminal keeps native scrolling. Anything marked [data-reveal]
// rises in once; under prefers-reduced-motion nothing moves and everything is visible.
export function Motion() {
  useEffect(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    gsap.registerPlugin(ScrollTrigger);

    const lenis = new Lenis({lerp: 0.1});
    lenis.on("scroll", ScrollTrigger.update);
    const tick = (t: number) => lenis.raf(t * 1000);
    gsap.ticker.add(tick);
    gsap.ticker.lagSmoothing(0);

    // In-page anchors (docs table of contents) go through Lenis so they glide too.
    const onClick = (e: MouseEvent) => {
      const a = (e.target as HTMLElement).closest<HTMLAnchorElement>('a[href^="#"]');
      if (!a) return;
      const el = document.querySelector(a.getAttribute("href")!);
      if (!el) return;
      e.preventDefault();
      lenis.scrollTo(el as HTMLElement, {offset: -72});
      history.replaceState(null, "", a.getAttribute("href"));
    };
    document.addEventListener("click", onClick);

    const ctx = gsap.context(() => {
      gsap.utils.toArray<HTMLElement>("[data-reveal]").forEach((el) => {
        gsap.from(el, {
          y: 28,
          opacity: 0,
          duration: 1.1,
          ease: "expo.out",
          scrollTrigger: {trigger: el, start: "top 90%", once: true},
        });
      });
    });

    const refresh = () => ScrollTrigger.refresh();
    document.fonts?.ready.then(refresh);

    return () => {
      document.removeEventListener("click", onClick);
      ctx.revert();
      gsap.ticker.remove(tick);
      lenis.destroy();
    };
  }, []);

  return null;
}
