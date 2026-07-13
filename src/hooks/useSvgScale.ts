import { useMemo } from "react";

export interface ChartPadding {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

function scale(
  value: number,
  d0: number,
  d1: number,
  r0: number,
  r1: number,
): number {
  if (d1 === d0) return r0;
  return r0 + ((value - d0) / (d1 - d0)) * (r1 - r0);
}

/// Linear x/y pixel scales for an SVG chart of size `width`x`height` with
/// the given padding. Y inverts automatically — larger data values map to
/// smaller (higher-up) pixel y, as SVG charts expect.
export function useSvgScale(
  width: number,
  height: number,
  padding: ChartPadding,
  xMin: number,
  xMax: number,
  yMin: number,
  yMax: number,
) {
  const { top, right, bottom, left } = padding;
  return useMemo(() => {
    const xRange: [number, number] = [left, width - right];
    const yRange: [number, number] = [height - bottom, top];
    return {
      x: (v: number) => scale(v, xMin, xMax, xRange[0], xRange[1]),
      y: (v: number) => scale(v, yMin, yMax, yRange[0], yRange[1]),
    };
  }, [width, height, top, right, bottom, left, xMin, xMax, yMin, yMax]);
}
