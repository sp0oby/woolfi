"use client";

import {useEffect, useState} from "react";

// Slow macro loop of fleece being spun into yarn, sitting dim behind the splash wordmark.
// The still poster renders first (and is all you get under reduced motion or Save-Data);
// the video only attaches after hydration so it never blocks first paint.
export function HeroFiber() {
  const [video, setVideo] = useState(false);

  useEffect(() => {
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const saveData = (navigator as Navigator & {connection?: {saveData?: boolean}}).connection?.saveData;
    if (!reduce && !saveData) setVideo(true);
  }, []);

  return (
    <div aria-hidden className="wool-hero-media -z-10">
      {video ? (
        <video autoPlay muted loop playsInline preload="auto" poster="/media/hero-fiber.jpg">
          <source src="/media/hero-fiber.mp4" type="video/mp4" />
        </video>
      ) : (
        <picture>
          <source srcSet="/media/hero-fiber.webp" type="image/webp" />
          <img src="/media/hero-fiber.jpg" alt="" />
        </picture>
      )}
    </div>
  );
}
