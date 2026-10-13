// A stitched seam used as a section divider on the reading pages.
export function Seam({className = ""}: {className?: string}) {
  return <div aria-hidden className={`seam ${className}`} />;
}
