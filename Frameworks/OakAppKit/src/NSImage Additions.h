@interface NSImage (ImageFromBundle)
+ (NSImage*)imageNamed:(NSString*)aName inSameBundleAsClass:(id)anObject;
@end

@interface NSImage (FileIcons)
+ (NSImage*)tmIconForFilenameExtension:(NSString*)anExtension; // Generic document icon if the extension is unknown
+ (NSImage*)tmMissingFileIcon;                                  // Icon used by Finder for missing/unknown items
@end
