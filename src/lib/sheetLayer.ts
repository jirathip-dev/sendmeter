import { createContext } from "react";

export type SheetLayer = "default" | "fullscreen";

/**
 * React context survives a createPortal boundary, so fullscreen surfaces can
 * scope every nested sheet without coupling the child to a DOM ancestor.
 */
export const SheetLayerContext = createContext<SheetLayer | undefined>(undefined);
