import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.jirathip.sendlog",
  appName: "Sendmeter",
  webDir: "dist",
  ios: {
    backgroundColor: "#0a0c10",
    // The app already manages its own internal scroll (.content-area);
    // without this the outer WKWebView's native UIScrollView still
    // bounces/drags the whole page (header, bottom nav included) despite
    // `overflow: hidden` on html/body — that CSS only stops content
    // overflow, not the native scroll view's own pan/rubber-band gesture.
    scrollEnabled: false,
  },
};

export default config;
