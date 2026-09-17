#ifndef TEASER_PRIVATE_ACCESSIBILITY_H
#define TEASER_PRIVATE_ACCESSIBILITY_H

#import <ApplicationServices/ApplicationServices.h>

// The only private macOS declaration Teaser links. It returns the window
// server's `CGWindowID` for an Accessibility window element, which is the exact
// identity every window manager on macOS needs and that no public API exposes.
// Teaser reads it; it never reparents, captures, or synthesizes input.
//
// The approach follows AeroSpace (MIT), revision
// 39e519044725694635712c739df9ca40ae78c5d1, `Sources/PrivateApi/include/private.h`.
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

#endif
