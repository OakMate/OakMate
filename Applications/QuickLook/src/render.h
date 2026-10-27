#ifndef QUICKLOOK_RENDER_H_7Q2M4XKD
#define QUICKLOOK_RENDER_H_7Q2M4XKD

#import <Cocoa/Cocoa.h>

// Syntax highlighted previews using the user’s theme and font (via TextMate’s preferences and bundle index)
NSAttributedString* TMQLCreatePreview (NSURL* url, NSColor** backgroundColor);

// Small syntax highlighted string (using the Mac Classic theme) for thumbnails
NSAttributedString* TMQLCreateThumbnail (NSURL* url, CGFloat fontSize, size_t maxLines);

#endif /* end of include guard: QUICKLOOK_RENDER_H_7Q2M4XKD */
